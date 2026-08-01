import SwiftUI
import AppKit
import QuartzCore

/// NSView backed by a CAMetalLayer that mpv renders into.
final class MetalHostView: NSView {
    let metalLayer = CAMetalLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.frame = bounds
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer = metalLayer
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2.0
    }
}

struct PlayerView: NSViewRepresentable {
    @ObservedObject var player: MPVPlayer

    func makeNSView(context: Context) -> MetalHostView {
        let view = MetalHostView(frame: .zero)
        player.attach(layer: view.metalLayer)
        return view
    }

    func updateNSView(_ nsView: MetalHostView, context: Context) {}
}
