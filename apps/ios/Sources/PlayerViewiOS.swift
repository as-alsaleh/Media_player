import SwiftUI
import UIKit
import QuartzCore

/// UIView whose backing layer is a CAMetalLayer for mpv to render into.
final class MetalHostUIView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        metalLayer.contentsScale = window?.screen.scale ?? 3.0
    }
}

struct PlayerView: UIViewRepresentable {
    @ObservedObject var player: MPVPlayer

    func makeUIView(context: Context) -> MetalHostUIView {
        let view = MetalHostUIView(frame: .zero)
        view.metalLayer.framebufferOnly = false
        player.attach(layer: view.metalLayer)
        return view
    }

    func updateUIView(_ uiView: MetalHostUIView, context: Context) {}
}
