import SwiftUI
import AppKit
import QuartzCore

/// NSView backed by a CAMetalLayer that mpv renders into.
final class MetalHostView: NSView {
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.framebufferOnly = false
        return layer
    }

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
