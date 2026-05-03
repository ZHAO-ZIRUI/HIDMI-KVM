import AppKit
import SwiftUI

@MainActor
final class HIDMIApplicationDelegate: NSObject, NSApplicationDelegate {
    private let menuCoordinator = HIDMIMenuCoordinator()
    weak var model: AppModel? {
        didSet {
            guard let model else { return }
            menuCoordinator.bind(model: model)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuCoordinator.installOrRepairWhenReady()
    }

    func applicationDidUpdate(_ notification: Notification) {
        menuCoordinator.installOrRepairWhenReady()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.prepareForTermination(timeout: 0.5)
    }
}

@MainActor
final class HIDMIMenuCoordinator {
    private let helpMenuController = HIDMIHelpMenuController()
    private let trackingGate = MenuTrackingGate()
    private var installWorkItem: DispatchWorkItem?

    func bind(model: AppModel) {
        helpMenuController.bind(model: model)
        trackingGate.onBeginTracking = { [weak model] in
            model?.beginMenuTracking()
        }
        trackingGate.onEndTracking = { [weak model] in
            model?.endMenuTracking()
        }
    }

    func installOrRepairWhenReady() {
        installOrRepairWhenReady(attempt: 0)
    }

    private func installOrRepairWhenReady(attempt: Int) {
        installWorkItem?.cancel()
        trackingGate.performWhenIdle { [weak self] in
            guard let self else { return }
            guard let mainMenu = NSApp.mainMenu else {
                self.scheduleInstallRetry(attempt: attempt)
                return
            }
            self.helpMenuController.ensureInstalled(in: mainMenu)
        }
    }

    private func scheduleInstallRetry(attempt: Int) {
        let nextAttempt = min(attempt + 1, 20)
        let delay = min(0.05 * Double(nextAttempt), 0.5)
        let workItem = DispatchWorkItem { [weak self] in
            self?.installOrRepairWhenReady(attempt: nextAttempt)
        }
        installWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

@MainActor
final class HIDMIHelpMenuController: NSObject {
    private let tokenManagementIdentifier = NSUserInterfaceItemIdentifier("HIDMI.Help.TokenManagement")
    private weak var model: AppModel?

    func bind(model: AppModel) {
        self.model = model
    }

    func ensureInstalled(in mainMenu: NSMenu) {
        guard let helpMenu = helpMenu(in: mainMenu) else { return }

        let item: NSMenuItem
        if let existing = helpMenu.items.first(where: {
            $0.identifier == tokenManagementIdentifier || $0.action == #selector(showTokenManagement(_:))
        }) {
            item = existing
        } else {
            item = NSMenuItem()
            helpMenu.addItem(.separator())
            helpMenu.addItem(item)
        }

        item.title = String(localized: "token.management")
        item.action = #selector(showTokenManagement(_:))
        item.target = self
        item.keyEquivalent = ""
        item.identifier = tokenManagementIdentifier
        item.isEnabled = true
    }

    private func helpMenu(in mainMenu: NSMenu) -> NSMenu? {
        let helpTitles = [String(localized: "menu.help"), "Help", "帮助"]
        if let item = mainMenu.items.first(where: { helpTitles.contains($0.title) }) {
            if item.submenu == nil {
                item.submenu = NSMenu(title: item.title)
            }
            return item.submenu
        }

        if let appHelpMenu = NSApp.helpMenu {
            return appHelpMenu
        }

        let item = NSMenuItem(title: String(localized: "menu.help"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: String(localized: "menu.help"))
        item.submenu = submenu
        mainMenu.addItem(item)
        return submenu
    }

    @objc private func showTokenManagement(_ sender: NSMenuItem) {
        DispatchQueue.main.async { [weak self] in
            self?.model?.showTokenManagement()
        }
    }
}

@main
struct HIDMIApp: App {
    @NSApplicationDelegateAdaptor(HIDMIApplicationDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        let appModel = AppModel.makeForCurrentEnvironment()
        _model = StateObject(wrappedValue: appModel)
        appDelegate.model = appModel
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .background(WindowAccessor { window in
                    model.attach(window: window)
                })
                .onAppear {
                    model.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
