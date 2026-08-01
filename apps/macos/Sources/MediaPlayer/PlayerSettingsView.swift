import SwiftUI

/// Infuse-style playback settings: audio/subtitle tracks, subtitle size and
/// timing, volume, speed. Values map straight onto mpv properties.
struct PlayerSettingsView: View {
    @ObservedObject var player: MPVPlayer

    @State private var tracks: [MPVPlayer.Track] = []
    @State private var volume: Double = 100
    @State private var speed: Double = 1.0
    @State private var subScale: Double = 1.0
    @State private var subDelay: Double = 0
    @State private var subPos: Double = 100
    @State private var subColor = "White"
    @State private var subBold = false
    @State private var subBackground = false
    @State private var audioDelay: Double = 0
    @State private var boost = false
    @State private var chapters: [MPVPlayer.Chapter] = []

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private let subColors: [(name: String, value: String, swatch: Color)] = [
        ("White", "#FFFFFFFF", .white),
        ("Yellow", "#FFFFEE00", .yellow),
        ("Cyan", "#FF00E5FF", .cyan),
        ("Green", "#FF00E676", .green),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Audio", icon: "speaker.wave.2.fill") {
                    trackButtons(type: "audio", prefix: "aid", allowOff: false)
                    labeledSlider("Volume", value: $volume, range: 0...130, suffix: "%") {
                        player.setDouble("volume", volume)
                    }
                    stepperRow("Audio Sync", value: $audioDelay, step: 0.1, unit: "s") {
                        player.setDouble("audio-delay", audioDelay)
                    }
                }

                section("Subtitles", icon: "captions.bubble.fill") {
                    trackButtons(type: "sub", prefix: "sid", allowOff: true)
                    labeledSlider("Size", value: $subScale, range: 0.5...2.0, suffix: "×") {
                        player.setDouble("sub-scale", subScale)
                    }
                    labeledSlider("Height", value: $subPos, range: 30...100, suffix: "") {
                        player.setDouble("sub-pos", subPos)
                    }
                    stepperRow("Subtitle Sync", value: $subDelay, step: 0.5, unit: "s") {
                        player.setDouble("sub-delay", subDelay)
                    }

                    // Style
                    HStack(spacing: 6) {
                        Text("Color").font(.system(size: 12.5))
                        Spacer()
                        ForEach(subColors, id: \.name) { c in
                            Button {
                                subColor = c.name
                                player.setString("sub-color", c.value)
                            } label: {
                                Circle()
                                    .fill(c.swatch)
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().stroke(
                                        subColor == c.name ? .white : .white.opacity(0.2),
                                        lineWidth: subColor == c.name ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Toggle(isOn: $subBold) {
                        Text("Bold").font(.system(size: 12.5))
                    }
                    .onChange(of: subBold) {
                        player.setString("sub-bold", subBold ? "yes" : "no")
                    }
                    Toggle(isOn: $subBackground) {
                        Text("Background box").font(.system(size: 12.5))
                    }
                    .onChange(of: subBackground) {
                        player.setString("sub-back-color", subBackground ? "#C0000000" : "#00000000")
                    }
                }

                section("Playback", icon: "play.circle.fill") {
                    Toggle(isOn: $boost) {
                        Text("Volume Boost (night mode)").font(.system(size: 12.5))
                    }
                    .onChange(of: boost) { player.setAudioBoost(boost) }
                    HStack(spacing: 6) {
                        ForEach(speeds, id: \.self) { s in
                            Button {
                                speed = s
                                player.setDouble("speed", s)
                            } label: {
                                Text(s == 1.0 ? "1×" : String(format: "%g×", s))
                                    .font(.system(size: 12, weight: speed == s ? .bold : .regular))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(
                                        speed == s ? Color.white.opacity(0.25) : .white.opacity(0.07),
                                        in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !chapters.isEmpty {
                    section("Chapters", icon: "list.bullet") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(chapters) { chapter in
                                trackRow(
                                    label: chapter.title,
                                    selected: player.timePos >= chapter.time &&
                                        (chapters.first { $0.time > chapter.time }?.time ?? .infinity) > player.timePos
                                ) {
                                    player.seek(to: chapter.time)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        #if os(macOS)
        .frame(width: 320, height: 440)
        #endif
        .onAppear {
            tracks = player.tracks()
            volume = player.getDouble("volume")
            speed = max(player.getDouble("speed"), 0.5)
            let scale = player.getDouble("sub-scale")
            subScale = scale > 0 ? scale : 1.0
            subDelay = player.getDouble("sub-delay")
            let pos = player.getDouble("sub-pos")
            subPos = pos > 0 ? pos : 100
            audioDelay = player.getDouble("audio-delay")
            chapters = player.chapters()
        }
    }

    @ViewBuilder
    private func section(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func trackButtons(type: String, prefix: String, allowOff: Bool) -> some View {
        let list = tracks.filter { $0.type == type }
        VStack(alignment: .leading, spacing: 4) {
            if allowOff {
                trackRow(label: "Off", selected: !list.contains { $0.selected }) {
                    player.setTrack(type: prefix, id: 0)
                    refreshTracks()
                }
            }
            ForEach(list) { track in
                trackRow(label: track.label, selected: track.selected) {
                    player.setTrack(type: prefix, id: track.id)
                    refreshTracks()
                }
            }
            if list.isEmpty {
                Text("No tracks").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func trackRow(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? .white : .secondary)
                Text(label).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12.5))
    }

    private func refreshTracks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            tracks = player.tracks()
        }
    }

    private func labeledSlider(
        _ label: String, value: Binding<Double>, range: ClosedRange<Double>,
        suffix: String, onChange: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: suffix == "%" ? "%.0f%@" : "%.1f%@", value.wrappedValue, suffix))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 12.5))
            CompatSlider(value: value, range: range, onEdit: onChange)
        }
    }

    private func stepperRow(
        _ label: String, value: Binding<Double>, step: Double, unit: String,
        onChange: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            Button {
                value.wrappedValue -= step
                onChange()
            } label: { Image(systemName: "minus.circle") }
            Text(String(format: "%+.1f%@", value.wrappedValue, unit))
                .monospacedDigit()
                .frame(width: 52)
            Button {
                value.wrappedValue += step
                onChange()
            } label: { Image(systemName: "plus.circle") }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12.5))
    }
}
