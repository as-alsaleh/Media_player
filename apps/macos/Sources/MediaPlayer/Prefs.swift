import Foundation

/// App-wide playback/audio/language preferences (UserDefaults-backed),
/// applied to the mpv player whenever playback starts.
enum Prefs {
    private static var d: UserDefaults { .standard }

    // Playback
    static var skipForwardSecs: Int { value("skipForwardSecs", default: 30) }
    static var skipBackSecs: Int { value("skipBackSecs", default: 10) }
    /// "auto" seeks past intro/ad markers, "manual" shows the button, "off" hides it.
    static var introSkipMode: String { d.string(forKey: "introSkipMode") ?? "manual" }
    static var autoPlayNext: Bool { d.object(forKey: "autoPlayNext") as? Bool ?? true }

    // Video
    /// "quality" (high-quality scalers, default) | "enhanced" (adds adaptive
    /// sharpening after upscale) | "eco" (cheap scalers, saves battery)
    static var videoQuality: String { d.string(forKey: "videoQuality") ?? "quality" }

    // Audio
    /// "auto" | "stereo" (downmix) | "51" (5.1 over HDMI/receiver)
    static var audioOutput: String { d.string(forKey: "audioOutput") ?? "auto" }
    /// Bitstream Dolby/DTS (incl. Atmos via TrueHD/E-AC-3) to the receiver.
    static var audioPassthrough: Bool { d.bool(forKey: "audioPassthrough") }
    static var defaultVolume: Double { d.object(forKey: "defaultVolume") as? Double ?? 100 }
    static var volumeBoost: Bool { d.bool(forKey: "volumeBoost") }

    // Languages (ISO-639 codes; empty = auto/original)
    static var langAudio: String { d.string(forKey: "langAudio") ?? "" }
    static var langSubtitles: String { d.string(forKey: "langSubtitles") ?? "" }
    static var langMetadata: String { d.string(forKey: "langMetadata") ?? "" }
    static var langArtwork: String { d.string(forKey: "langArtwork") ?? "" }

    private static func value(_ key: String, default def: Int) -> Int {
        d.object(forKey: key) as? Int ?? def
    }

    /// Contrast-adaptive sharpening (the FidelityFX-CAS algorithm) hooked
    /// after libplacebo's upscale pass. Only edges below full contrast get
    /// sharpened, so it enhances upscaled detail without halos or ringing.
    private static let casShader = """
    //!HOOK OUTPUT
    //!BIND HOOKED
    //!DESC Adaptive sharpen (CAS)

    vec4 hook() {
        vec3 a = HOOKED_texOff(vec2(-1.0,  0.0)).rgb;
        vec3 b = HOOKED_texOff(vec2( 1.0,  0.0)).rgb;
        vec3 c = HOOKED_texOff(vec2( 0.0, -1.0)).rgb;
        vec3 d = HOOKED_texOff(vec2( 0.0,  1.0)).rgb;
        vec4 e = HOOKED_texOff(vec2( 0.0,  0.0));

        vec3 mn = min(min(min(a, b), min(c, d)), e.rgb);
        vec3 mx = max(max(max(a, b), max(c, d)), e.rgb);
        vec3 amp = sqrt(clamp(min(mn, 1.0 - mx) / max(mx, vec3(1e-5)), 0.0, 1.0));
        // Sharpness 0.5 on AMD's scale: peak weight -1/mix(8, 5, 0.5).
        vec3 w = amp * -0.15385;
        vec3 res = (e.rgb + (a + b + c + d) * w) / (1.0 + 4.0 * w);
        return vec4(clamp(res, 0.0, 1.0), e.a);
    }
    """

    /// The CAS shader written to a temp file (mpv loads shaders by path).
    private static var casPathCache: String?
    static func casShaderPath() -> String {
        if let cached = casPathCache { return cached }
        let path = NSTemporaryDirectory() + "mediaplayer-cas.glsl"
        try? casShader.write(toFile: path, atomically: true, encoding: .utf8)
        casPathCache = path
        return path
    }

    /// Scaler/shader chain for the current video-quality tier. Safe to call
    /// mid-playback; gpu-next reconfigures on the fly.
    static func applyVideo(to player: MPVPlayer) {
        switch videoQuality {
        case "eco":
            player.setString("scale", "bilinear")
            player.setString("cscale", "bilinear")
            player.setString("dscale", "bilinear")
            player.setString("deband", "no")
            player.setString("glsl-shaders", "")
        case "enhanced":
            player.setString("scale", "ewa_lanczossharp")
            player.setString("cscale", "ewa_lanczossharp")
            player.setString("dscale", "hermite")
            player.setString("deband", "yes")
            player.setString("glsl-shaders", casShaderPath())
        default:
            player.setString("scale", "ewa_lanczossharp")
            player.setString("cscale", "ewa_lanczossharp")
            player.setString("dscale", "hermite")
            player.setString("deband", "yes")
            player.setString("glsl-shaders", "")
        }
    }

    /// Push the audio/language preferences onto the player. Call before load
    /// so track selection (alang/slang) applies to the file being opened.
    static func apply(to player: MPVPlayer) {
        applyVideo(to: player)
        switch audioOutput {
        case "stereo": player.setString("audio-channels", "stereo")
        case "51": player.setString("audio-channels", "5.1,stereo")
        default: player.setString("audio-channels", "auto-safe")
        }
        // Passthrough only makes sense into an HDMI receiver — on speakers or
        // headphones it silences every Dolby/DTS track. Keep the format list
        // conservative and let mpv fall back to decoding when the device
        // can't bitstream.
        player.setString("audio-spdif", audioPassthrough ? "ac3,eac3" : "")
        player.setDouble("volume", defaultVolume)
        player.setAudioBoost(volumeBoost)
        player.setString("alang", langAudio.isEmpty ? "" : "\(langAudio),eng,en")
        player.setString("slang", langSubtitles)
    }
}
