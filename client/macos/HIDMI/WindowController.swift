import AppKit
import SwiftUI

@MainActor
final class WindowController {
    private weak var window: NSWindow?

    var backingScaleFactor: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window

        window.title = "HIDMI"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.styleMask.insert(.fullSizeContentView)
        window.collectionBehavior.insert(.fullScreenPrimary)
    }

    func resizeContent(to requestedSize: CGSize) {
        guard let window, requestedSize.width > 0, requestedSize.height > 0 else { return }

        let screen = window.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxContentSize = CGSize(width: visibleFrame.width, height: visibleFrame.height)
        let scale = min(1.0, maxContentSize.width / requestedSize.width, maxContentSize.height / requestedSize.height)
        let contentSize = CGSize(
            width: floor(requestedSize.width * scale),
            height: floor(requestedSize.height * scale)
        )

        let contentRect = NSRect(origin: .zero, size: contentSize)
        var frame = window.frameRect(forContentRect: contentRect)
        frame.origin.x = visibleFrame.midX - frame.width / 2
        frame.origin.y = visibleFrame.midY - frame.height / 2

        window.setFrame(frame, display: true, animate: true)
    }

    func resizeToOriginalInput(inputSize: CGSize) {
        guard let window, inputSize.width > 0, inputSize.height > 0 else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }

        let screen = window.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let contentSize = WindowResizePlanning.originalInputContentSize(
            inputSize: inputSize,
            backingScaleFactor: window.backingScaleFactor,
            visibleFrame: visibleFrame
        )
        let contentRect = NSRect(origin: .zero, size: contentSize)
        let proposedFrame = window.frameRect(forContentRect: contentRect)
        let frame = WindowResizePlanning.framePreservingTopLeft(
            oldFrame: window.frame,
            proposedFrameSize: proposedFrame.size,
            visibleFrame: visibleFrame
        )

        window.setFrame(frame, display: true, animate: true)
    }

}

struct WindowAccessor: NSViewRepresentable {
    let onWindowAvailable: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.postsFrameChangedNotifications = false

        DispatchQueue.main.async {
            if let window = view.window {
                onWindowAvailable(window)
            }
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onWindowAvailable(window)
            }
        }
    }
}
