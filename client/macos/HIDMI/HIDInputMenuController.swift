import AppKit
import Combine

@MainActor
final class HIDInputMenuController: NSObject, NSMenuDelegate {
    private let menuIdentifier = NSUserInterfaceItemIdentifier("HIDMI.HIDInputMenu")
    private weak var model: AppModel?
    private var cancellable: AnyCancellable?
    private var pendingTopLevelRepair: DispatchWorkItem?
    private var menuItem: NSMenuItem?
    private var maintainsTopLevelMenu = false
    private var needsMenuRebuild = true
    private var isMenuTracking = false
    let menu = NSMenu(title: String(localized: "menu.hid"))

    override init() {
        menu.autoenablesItems = false
        super.init()
    }

    func bind(model: AppModel) {
        self.model = model
        cancellable = model.objectWillChange.sink { [weak self] _ in
            self?.markMenuNeedsRebuild()
            self?.scheduleTopLevelRepair()
        }
    }

    func installOrUpdate() {
        maintainsTopLevelMenu = true
        guard ensureInstalled() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.installOrUpdate()
            }
            return
        }
        rebuildMenu()
    }

    func repairTopLevelInstallation() {
        guard !isMenuTracking else { return }
        _ = ensureInstalled()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model?.startHIDMIDiscovery()
        rebuildMenuIfNeeded()
    }

    func menuWillOpen(_ menu: NSMenu) {
        pendingTopLevelRepair?.cancel()
        isMenuTracking = true
        model?.beginMenuTracking()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuTracking = false
        model?.endMenuTracking()
    }

    private func install(in mainMenu: NSMenu) {
        let item: NSMenuItem
        if let existingIndex = existingInputMenuIndex(in: mainMenu),
           let existingItem = mainMenu.item(at: existingIndex) {
            item = existingItem
        } else {
            item = NSMenuItem(title: String(localized: "menu.hid"), action: nil, keyEquivalent: "")
            mainMenu.insertItem(item, at: insertionIndex(in: mainMenu))
        }

        if menuItem !== item, menuItem?.submenu === menu {
            menuItem?.submenu = nil
        }

        item.title = String(localized: "menu.hid")
        item.action = nil
        item.keyEquivalent = ""
        item.identifier = menuIdentifier
        item.submenu = menu
        menu.delegate = self
        menuItem = item
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard maintainsTopLevelMenu else {
            return false
        }
        guard let mainMenu = NSApp.mainMenu else {
            return false
        }

        if menuItem?.menu !== mainMenu || menuItem?.submenu !== menu {
            install(in: mainMenu)
        } else if !mainMenu.items.contains(where: { $0.identifier == menuIdentifier }) {
            install(in: mainMenu)
        }

        let title = String(localized: "menu.hid")
        if menuItem?.title != title {
            menuItem?.title = title
        }
        if menu.title != title {
            menu.title = title
        }
        return true
    }

    private func markMenuNeedsRebuild() {
        needsMenuRebuild = true
    }

    private func scheduleTopLevelRepair() {
        guard maintainsTopLevelMenu else { return }
        pendingTopLevelRepair?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.repairTopLevelInstallation()
        }
        pendingTopLevelRepair = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func rebuildMenuIfNeeded() {
        guard needsMenuRebuild else { return }
        rebuildMenu()
    }

    private func insertionIndex(in mainMenu: NSMenu) -> Int {
        let helpTitles = ["Help", "帮助"]
        if let helpIndex = mainMenu.items.firstIndex(where: { helpTitles.contains($0.title) }) {
            return min(helpIndex + 1, mainMenu.items.count)
        }

        let windowTitles = [String(localized: "menu.window"), "Window", "窗口"]
        if let windowIndex = mainMenu.items.lastIndex(where: { windowTitles.contains($0.title) }) {
            return min(windowIndex + 1, mainMenu.items.count)
        }

        let viewTitles = [String(localized: "menu.view"), "View", "显示", "画面"]
        if let viewIndex = mainMenu.items.firstIndex(where: { viewTitles.contains($0.title) }) {
            return min(viewIndex + 1, mainMenu.items.count)
        }

        return min(4, mainMenu.items.count)
    }

    private func existingInputMenuIndex(in mainMenu: NSMenu) -> Int? {
        let titles = [String(localized: "menu.hid"), "HID", "Input", "输入"]
        return mainMenu.items.firstIndex { item in
            item.identifier == menuIdentifier || titles.contains(item.title)
        }
    }

    func rebuildMenu() {
        guard let model else { return }
        needsMenuRebuild = false
        menu.removeAllItems()

        let deviceStates = model.hidmi.menuDeviceStates
        if deviceStates.isEmpty {
            let item = NSMenuItem(title: String(localized: "hid.device.none"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for state in deviceStates {
                menu.addItem(deviceMenuItem(for: state, model: model))
            }
        }

        menu.addItem(.separator())
        let refresh = NSMenuItem(
            title: String(localized: "hid.refresh_devices"),
            action: #selector(refreshDevices(_:)),
            keyEquivalent: ""
        )
        refresh.target = self
        refresh.isEnabled = !model.hidmi.isDiscovering
        menu.addItem(refresh)

        menu.addItem(.separator())
        let releaseAll = NSMenuItem(
            title: String(localized: "hid.release_all"),
            action: #selector(releaseAll(_:)),
            keyEquivalent: ""
        )
        releaseAll.target = self
        releaseAll.isEnabled = model.hidmi.isConnected
        menu.addItem(releaseAll)

        let ctrlAltDel = NSMenuItem(
            title: String(localized: "hid.send_ctrl_alt_del"),
            action: #selector(sendCtrlAltDel(_:)),
            keyEquivalent: ""
        )
        ctrlAltDel.target = self
        ctrlAltDel.isEnabled = model.hidmi.isConnected
        menu.addItem(ctrlAltDel)

        menu.addItem(.separator())
        let tokenManagement = NSMenuItem(
            title: String(localized: "token.management"),
            action: #selector(showTokenManagement(_:)),
            keyEquivalent: ""
        )
        tokenManagement.target = self
        menu.addItem(tokenManagement)
    }

    private func deviceMenuItem(for state: HIDMIMenuDeviceState, model: AppModel) -> NSMenuItem {
        let item = NSMenuItem(title: state.device.menuTitle, action: nil, keyEquivalent: "")
        item.state = state.marker.menuItemState

        let submenu = NSMenu(title: state.device.menuTitle)
        let actionTitle = state.marker == .connected
            ? String(localized: "hid.device.disconnect_this_device")
            : String(localized: "hid.device.connect_this_device")
        let action = NSMenuItem(
            title: actionTitle,
            action: state.marker == .connected ? #selector(disconnectDevice(_:)) : #selector(connectDevice(_:)),
            keyEquivalent: ""
        )
        action.target = self
        action.representedObject = state.id
        action.isEnabled = state.marker == .connected || !model.hidmi.status.isConnecting
        submenu.addItem(action)

        submenu.addItem(.separator())
        for detail in state.menuDetails {
            let detailItem = NSMenuItem(title: detail.title, action: nil, keyEquivalent: "")
            detailItem.isEnabled = false
            submenu.addItem(detailItem)
        }

        item.submenu = submenu
        return item
    }

    @objc private func connectDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? HIDMIDiscoveredDevice.ID else { return }
        DispatchQueue.main.async { [weak self] in
            self?.model?.connectHIDMI(id)
        }
    }

    @objc private func disconnectDevice(_ sender: NSMenuItem) {
        model?.disconnectHIDMI()
    }

    @objc private func refreshDevices(_ sender: NSMenuItem) {
        model?.refreshHIDMIDevices()
    }

    @objc private func releaseAll(_ sender: NSMenuItem) {
        model?.releaseRemoteInput()
    }

    @objc private func sendCtrlAltDel(_ sender: NSMenuItem) {
        model?.sendCtrlAltDel()
    }

    @objc private func showTokenManagement(_ sender: NSMenuItem) {
        DispatchQueue.main.async { [weak self] in
            self?.model?.showTokenManagement()
        }
    }
}

extension HIDMIMenuSelectionMarker {
    var menuItemState: NSControl.StateValue {
        switch self {
        case .connected:
            return .on
        case .selected:
            return .off
        case .available:
            return .off
        }
    }
}

private extension HIDMIController.Status {
    var isConnecting: Bool {
        if case .connecting = self {
            return true
        }
        return false
    }
}
