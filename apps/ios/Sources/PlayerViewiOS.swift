import SwiftUI
import UIKit
import QuartzCore

/// CAMetalLayer that ignores MoltenVK's forced 1x1 drawableSize (a
/// present-completion hack that can leave the size stuck after the app is
/// backgrounded). Same workaround as MPVKit's demo player.
final class GuardedMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if newValue.width > 1, newValue.height > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

/// UIView whose backing layer is a CAMetalLayer for mpv to render into.
final class MetalHostUIView: UIView {
    override class var layerClass: AnyClass { GuardedMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var onResize: (() -> Void)?
    private var resizeWork: DispatchWorkItem?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        metalLayer.contentsScale = window?.screen.scale ?? 3.0
        syncDrawableSize()
    }

    // Keep the drawable size in lockstep with the view so rotations and
    // size changes don't leave mpv rendering at stale dimensions.
    override func layoutSubviews() {
        super.layoutSubviews()
        syncDrawableSize()
    }

    private func syncDrawableSize() {
        let scale = window?.screen.scale ?? 3.0
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 1, size.height > 1, metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onResize?() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

struct PlayerView: UIViewRepresentable {
    @ObservedObject var player: MPVPlayer

    func makeUIView(context: Context) -> MetalHostUIView {
        let view = MetalHostUIView(frame: .zero)
        view.metalLayer.framebufferOnly = false
        view.onResize = { [weak player] in player?.refreshRenderSize() }
        player.attach(layer: view.metalLayer)
        return view
    }

    func updateUIView(_ uiView: MetalHostUIView, context: Context) {}
}
