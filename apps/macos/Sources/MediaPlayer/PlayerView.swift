import SwiftUI
import AppKit
import QuartzCore

/// CAMetalLayer that ignores MoltenVK's forced 1x1 drawableSize (a
/// present-completion hack that can leave the size stuck after the window
/// is minimized). Same workaround as MPVKit's demo player.
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

/// NSView backed by a CAMetalLayer that mpv renders into.
final class MetalHostView: NSView {
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// Fired (debounced) after the drawable size actually changes.
    var onResize: (() -> Void)?
    private var resizeWork: DispatchWorkItem?
    private var windowObservers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func makeBackingLayer() -> CALayer {
        let layer = GuardedMetalLayer()
        layer.framebufferOnly = false
        return layer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2.0
        syncDrawableSize()
    }

    // Keep the layer's drawable size in lockstep with the view. Without
    // this, fullscreen toggles / window resizes leave mpv rendering at the
    // old dimensions (cropped or letterboxed picture) until the swapchain
    // happens to recreate.
    override func layout() {
        super.layout()
        syncDrawableSize()
    }

    private func syncDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2.0
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 1, size.height > 1, metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        scheduleReconfig()
    }

    // Belt and suspenders: window-state transitions can leave MoltenVK's
    // swapchain at a stale extent even when the drawable size compares
    // equal (the guarded setter swallows the 1×1 poison, so the "change"
    // that would trigger a poke never happens). Force a reconfig on every
    // fullscreen / minimize / screen transition unconditionally.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        let transitions: [Notification.Name] = [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeScreenNotification,
        ]
        for name in transitions {
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                self?.forceReconfig()
            })
        }
    }

    private func forceReconfig() {
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 1, size.height > 1 {
            metalLayer.drawableSize = size
        }
        scheduleReconfig()
    }

    private func scheduleReconfig() {
        // The embedded MoltenVK context only reads the drawable size on
        // reconfig — poke the player once the size settles so the
        // swapchain follows (fullscreen toggles, minimize/restore).
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onResize?() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }
}

struct PlayerView: NSViewRepresentable {
    @ObservedObject var player: MPVPlayer

    func makeNSView(context: Context) -> MetalHostView {
        let view = MetalHostView(frame: .zero)
        view.onResize = { [weak player] in player?.refreshRenderSize() }
        player.attach(layer: view.metalLayer)
        return view
    }

    func updateNSView(_ nsView: MetalHostView, context: Context) {}
}
