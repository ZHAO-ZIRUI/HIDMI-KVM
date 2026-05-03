import AppKit

@MainActor
final class MenuTrackingGate: NSObject {
    var onBeginTracking: (() -> Void)?
    var onEndTracking: (() -> Void)?

    private var trackingDepth = 0
    private var deferredJobs: [() -> Void] = []

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidEndTracking(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var isTracking: Bool {
        trackingDepth > 0
    }

    func performWhenIdle(_ job: @escaping () -> Void) {
        guard trackingDepth == 0 else {
            deferredJobs.append(job)
            return
        }
        job()
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu,
              menu === NSApp.mainMenu else { return }
        trackingDepth += 1
        if trackingDepth == 1 {
            onBeginTracking?()
        }
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu,
              menu === NSApp.mainMenu,
              trackingDepth > 0 else { return }
        trackingDepth -= 1
        guard trackingDepth == 0 else { return }

        onEndTracking?()
        let jobs = deferredJobs
        deferredJobs.removeAll()
        guard !jobs.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for job in jobs {
                self.performWhenIdle(job)
            }
        }
    }
}
