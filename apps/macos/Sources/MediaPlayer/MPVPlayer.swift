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

        observe("pause", MPV_FORMAT_FLAG)
        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("hwdec-current", MPV_FORMAT_STRING)
        observe("media-title", MPV_FORMAT_STRING)

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

    func setTrack(type: String, id: Int) {
        // type: "aid" (audio) or "sid" (subtitles); id 0 disables.
        guard let mpv else { return }
        var v = Int64(id)
        mpv_set_property(mpv, type, MPV_FORMAT_INT64, &v)
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
