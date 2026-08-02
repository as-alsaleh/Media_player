import Foundation
import QuartzCore
import Libmpv
#if os(macOS)
import AppKit
#endif

/// Thin Swift wrapper around a libmpv handle rendering into a CAMetalLayer.
///
/// mpv is configured for zero-copy hardware decoding (`hwdec=videotoolbox`)
/// with the gpu-next/libplacebo renderer over MoltenVK, which gives us HDR
/// tone mapping, libass/PGS subtitles, and AV sync for free.
final class MPVPlayer: ObservableObject {
    @Published var isPaused = true
    @Published var timePos: Double = 0
    @Published var duration: Double = 0
    @Published var hwdecCurrent = ""
    @Published var mediaTitle = ""

    private var mpv: OpaquePointer?
    private var eventThread: Thread?
    /// URL requested before the render surface existed; applied on attach.
    private var pendingLoad: URL?
    private var currentURL: URL?
    private var retriesLeft = 0
    /// Called on the main queue when playback reaches the end of the file.
    var onFileEnded: (() -> Void)?

    func attach(layer: CAMetalLayer) {
        guard mpv == nil else { return }
        guard let handle = mpv_create() else {
            fatalError("mpv_create failed")
        }
        mpv = handle

        // mpv's macOS vulkan (MoltenVK) context expects a CAMetalLayer pointer in `wid`.
        var layerPtr = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &layerPtr)

        // Diagnostic log, overwritten each run.
        setOption("log-file", NSTemporaryDirectory() + "mediaplayer-mpv.log")
        setOption("msg-level", "all=v")

        setOption("vo", "gpu-next")
        setOption("gpu-api", "vulkan")
        setOption("hwdec", "videotoolbox")
        setOption("target-colorspace-hint", "yes")

        // HDR / Dolby Vision quality pipeline (libplacebo):
        // dynamic peak detection + spline tone mapping preserves highlights,
        // perceptual gamut mapping avoids hue shifts, deband hides gradient
        // banding common in HDR web rips. DV P5/P8 RPUs are applied by
        // libplacebo via libdovi automatically under gpu-next.
        setOption("tone-mapping", "spline")
        setOption("hdr-compute-peak", "yes")
        setOption("gamut-mapping-mode", "perceptual")
        setOption("deband", "yes")
        // High-quality scalers; Apple-silicon GPUs handle these fine at 4K.
        setOption("scale", "ewa_lanczossharp")
        setOption("cscale", "ewa_lanczossharp")
        setOption("dscale", "hermite")
        setOption("dither-depth", "auto")
        setOption("keep-open", "yes")
        setOption("input-default-bindings", "no")
        // Generous demuxer cache for high-bitrate network streams later.
        setOption("cache", "yes")
        setOption("demuxer-max-bytes", "256MiB")
        setOption("demuxer-readahead-secs", "60")
        // Ride out transient HTTP hiccups (Plex occasionally 503s under load).
        setOption("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5")

        mpv_initialize(handle)

        // Scaler/shader tier (Quality / Enhanced / Battery saver) is global;
        // per-load Prefs.apply re-asserts it alongside audio/language prefs.
        Prefs.applyVideo(to: self)

        observe("pause", MPV_FORMAT_FLAG)
        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("hwdec-current", MPV_FORMAT_STRING)
        observe("media-title", MPV_FORMAT_STRING)
        observe("eof-reached", MPV_FORMAT_FLAG)

        let thread = Thread { [weak self] in self?.eventLoop() }
        thread.name = "mpv-events"
        thread.start()
        eventThread = thread

        if let pending = pendingLoad {
            pendingLoad = nil
            load(url: pending)
        }

        // Allow `MediaPlayer /path/to/file` for headless/scripted testing.
        if CommandLine.arguments.count > 1 {
            let arg = CommandLine.arguments[1]
            if arg.contains("://"), let url = URL(string: arg) {
                load(url: url)
            } else {
                load(url: URL(fileURLWithPath: arg))
            }
        }
    }

    func load(url: URL) {
        guard mpv != nil else {
            pendingLoad = url
            return
        }
        currentURL = url
        retriesLeft = 3
        command("loadfile", url.isFileURL ? url.path : url.absoluteString)
        setProperty("pause", flag: false)
    }

    func togglePause() { setProperty("pause", flag: !isPaused) }

    func seek(to seconds: Double) {
        command("seek", String(seconds), "absolute")
    }

    func cycleMute() {
        guard let mpv else { return }
        mpv_command_string(mpv, "cycle mute")
    }

    func adjustVolume(by delta: Double) {
        let v = min(max(getDouble("volume") + delta, 0), 130)
        setDouble("volume", v)
    }

    func setTrack(type: String, id: Int) {
        // type: "aid" (audio) or "sid" (subtitles); id 0 disables.
        guard let mpv else { return }
        if id == 0 {
            mpv_set_property_string(mpv, type, "no")
        } else {
            var v = Int64(id)
            mpv_set_property(mpv, type, MPV_FORMAT_INT64, &v)
        }
    }

    struct Track: Identifiable, Hashable {
        let id: Int
        let type: String     // "audio" | "sub" | "video"
        let title: String?
        let lang: String?
        let selected: Bool

        var label: String {
            var parts: [String] = []
            if let lang { parts.append(lang.uppercased()) }
            if let title { parts.append(title) }
            return parts.isEmpty ? "Track \(id)" : parts.joined(separator: " · ")
        }
    }

    /// Current track list, decoded from mpv's JSON representation.
    func tracks() -> [Track] {
        guard let mpv, let cstr = mpv_get_property_string(mpv, "track-list") else { return [] }
        defer { mpv_free(cstr) }
        let data = Data(String(cString: cstr).utf8)

        struct Raw: Decodable {
            let id: Int
            let type: String
            let title: String?
            let lang: String?
            let selected: Bool
        }
        let raw = (try? JSONDecoder().decode([Raw].self, from: data)) ?? []
        return raw.map {
            Track(id: $0.id, type: $0.type, title: $0.title, lang: $0.lang, selected: $0.selected)
        }
    }

    struct Chapter: Identifiable, Hashable {
        let id: Int
        let title: String
        let time: Double
    }

    /// Chapter list from the demuxer (may be empty).
    func chapters() -> [Chapter] {
        guard let mpv, let cstr = mpv_get_property_string(mpv, "chapter-list") else { return [] }
        defer { mpv_free(cstr) }
        struct Raw: Decodable {
            let title: String?
            let time: Double
        }
        let raw = (try? JSONDecoder().decode([Raw].self, from: Data(String(cString: cstr).utf8))) ?? []
        return raw.enumerated().map { i, c in
            Chapter(id: i, title: c.title ?? "Chapter \(i + 1)", time: c.time)
        }
    }

    /// Dynamic-range compression so quiet dialogue is audible at low volume.
    func setAudioBoost(_ on: Bool) {
        guard let mpv else { return }
        mpv_set_property_string(mpv, "af", on ? "dynaudnorm=g=5:f=250:r=0.9:p=0.5" : "")
    }

    /// Force the render pipeline to re-read the layer's drawable size. The
    /// embedded MoltenVK context only picks the size up on reconfig, so a
    /// no-op filter-chain change makes resizes (fullscreen, minimize →
    /// restore) take effect instead of leaving the picture at stale
    /// dimensions.
    func refreshRenderSize() {
        command("vf", "add", "@resize-fix:null")
        command("vf", "remove", "@resize-fix")
    }

    /// Attach an external subtitle to the playing file. `select` picks it
    /// immediately; otherwise it just becomes available in the track list.
    func addSubtitle(url: String, title: String?, lang: String?, select: Bool = false) {
        command("sub-add", url, select ? "select" : "auto",
                title ?? "External", lang ?? "und")
    }

    func setString(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_property_string(mpv, name, value)
    }

    func setDouble(_ name: String, _ value: Double) {
        guard let mpv else { return }
        var v = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
    }

    func getDouble(_ name: String) -> Double {
        guard let mpv else { return 0 }
        var v: Double = 0
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
        return v
    }

    func shutdown() {
        guard let mpv else { return }
        mpv_command_string(mpv, "quit")
    }

    // MARK: - Internals

    private func setOption(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_option_string(mpv, name, value)
    }

    private func setProperty(_ name: String, flag: Bool) {
        guard let mpv else { return }
        var v: Int32 = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &v)
    }

    private func command(_ args: String...) {
        guard let mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        mpv_command(mpv, &cargs)
        for p in cargs where p != nil { free(UnsafeMutableRawPointer(mutating: p)) }
    }

    private func observe(_ name: String, _ format: mpv_format) {
        guard let mpv else { return }
        mpv_observe_property(mpv, 0, name, format)
    }

    private func eventLoop() {
        while let mpv {
            guard let event = mpv_wait_event(mpv, -1)?.pointee else { continue }
            switch event.event_id {
            case MPV_EVENT_SHUTDOWN:
                mpv_destroy(mpv)
                self.mpv = nil
                return
            case MPV_EVENT_PROPERTY_CHANGE:
                let prop = event.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                handlePropertyChange(prop)
            case MPV_EVENT_END_FILE:
                let end = event.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_EOF {
                    DispatchQueue.main.async { [weak self] in self?.onFileEnded?() }
                }
                if end.reason == MPV_END_FILE_REASON_ERROR {
                    // Transient server error (e.g. Plex 503) — retry shortly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self, self.retriesLeft > 0, let url = self.currentURL else { return }
                        self.retriesLeft -= 1
                        self.command("loadfile", url.isFileURL ? url.path : url.absoluteString)
                        self.setProperty("pause", flag: false)
                    }
                }
            default:
                break
            }
        }
    }

    private func handlePropertyChange(_ prop: mpv_event_property) {
        let name = String(cString: prop.name)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch (name, prop.format) {
            case ("pause", MPV_FORMAT_FLAG):
                if let p = prop.data?.assumingMemoryBound(to: Int32.self).pointee {
                    self.isPaused = p != 0
                }
            case ("time-pos", MPV_FORMAT_DOUBLE):
                if let v = prop.data?.assumingMemoryBound(to: Double.self).pointee {
                    self.timePos = v
                }
            case ("duration", MPV_FORMAT_DOUBLE):
                if let v = prop.data?.assumingMemoryBound(to: Double.self).pointee {
                    self.duration = v
                }
            case ("hwdec-current", MPV_FORMAT_STRING):
                if let cstr = prop.data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                    self.hwdecCurrent = String(cString: cstr)
                }
            case ("eof-reached", MPV_FORMAT_FLAG):
                if let v = prop.data?.assumingMemoryBound(to: Int32.self).pointee, v != 0 {
                    self.onFileEnded?()
                }
            case ("media-title", MPV_FORMAT_STRING):
                if let cstr = prop.data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                    self.mediaTitle = String(cString: cstr)
                }
            default:
                break
            }
        }
    }
}
