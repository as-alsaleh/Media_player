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

    /// Push the audio/language preferences onto the player. Call before load
    /// so track selection (alang/slang) applies to the file being opened.
    static func apply(to player: MPVPlayer) {
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
