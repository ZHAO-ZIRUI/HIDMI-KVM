import AppKit

@MainActor
final class HIDInputMenuController: NSObject, NSMenuDelegate {
    private let menuIdentifier = NSUserInterfaceItemIdentifier("HIDMI.HIDInputMenu")
    private weak var model: AppModel?
    private var menuItem: NSMenuItem?
    let menu = NSMenu(title: String(localized: "menu.hid"))

    override init() {
        menu.autoenablesItems = false
        super.init()
    }

    func bind(model: AppModel) {
        self.model = model
    }

    func installOrUpdate() {
        guard let mainMenu = NSApp.mainMenu else { return }
        ensureTopLevelInstalled(in: mainMenu)
    }

    func repairTopLevelInstallation() {
        installOrUpdate()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuildMenu()
    }

    func ensureTopLevelInstalled(in mainMenu: NSMenu) {
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

    private func insertionIndex(in mainMenu: NSMenu) -> Int {
        let videoTitles = [String(localized: "menu.video"), "Video", "画面"]
        if let videoIndex = mainMenu.items.firstIndex(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("HIDMI.VideoMenu") || videoTitles.contains($0.title)
        }) {
            return min(videoIndex + 1, mainMenu.items.count)
        }

        let windowTitles = [String(localized: "menu.window"), "Window", "窗口"]
        if let windowIndex = mainMenu.items.firstIndex(where: { windowTitles.contains($0.title) }) {
            return windowIndex
        }

        let helpTitles = ["Help", "帮助"]
        if let helpIndex = mainMenu.items.firstIndex(where: { helpTitles.contains($0.title) }) {
            return helpIndex
        }

        let editTitles = ["Edit", "编辑"]
        if let editIndex = mainMenu.items.firstIndex(where: { editTitles.contains($0.title) }) {
            return min(editIndex + 1, mainMenu.items.count)
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
        let snapshot = model.menuState.snapshot
        menu.removeAllItems()

        if snapshot.inputDevices.isEmpty {
            let item = NSMenuItem(title: String(localized: "hid.device.none"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for device in snapshot.inputDevices {
                menu.addItem(deviceMenuItem(for: device))
            }
        }

        menu.addItem(.separator())
        let refresh = NSMenuItem(
            title: String(localized: "hid.refresh_devices"),
            action: #selector(refreshDevices(_:)),
            keyEquivalent: ""
        )
        refresh.target = self
        refresh.isEnabled = true
        menu.addItem(refresh)

        menu.addItem(.separator())
        let releaseAll = NSMenuItem(
            title: String(localized: "hid.release_all"),
            action: #selector(releaseAll(_:)),
            keyEquivalent: ""
        )
        releaseAll.target = self
        releaseAll.isEnabled = snapshot.isHIDMIConnected
        menu.addItem(releaseAll)

        let ctrlAltDel = NSMenuItem(
            title: String(localized: "hid.send_ctrl_alt_del"),
            action: #selector(sendCtrlAltDel(_:)),
            keyEquivalent: ""
        )
        ctrlAltDel.target = self
        ctrlAltDel.isEnabled = snapshot.isHIDMIConnected
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

    private func deviceMenuItem(for device: AppMenuInputDeviceItem) -> NSMenuItem {
        let item = NSMenuItem(title: device.title, action: nil, keyEquivalent: "")
        item.state = device.marker.menuItemState

        let submenu = NSMenu(title: device.title)
        let action = NSMenuItem(
            title: device.actionTitle,
            action: device.marker == .connected ? #selector(disconnectDevice(_:)) : #selector(connectDevice(_:)),
            keyEquivalent: ""
        )
        action.target = self
        action.representedObject = device.id
        action.isEnabled = device.isActionEnabled
        submenu.addItem(action)

        submenu.addItem(.separator())
        for detail in device.details {
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
            self?.model?.applyCurrentMenuSnapshotWhenSafe()
        }
    }

    @objc private func disconnectDevice(_ sender: NSMenuItem) {
        model?.disconnectHIDMI()
        model?.applyCurrentMenuSnapshotWhenSafe()
    }

    @objc private func refreshDevices(_ sender: NSMenuItem) {
        model?.refreshHIDMIMenuDevices()
    }

    @objc private func releaseAll(_ sender: NSMenuItem) {
        model?.releaseRemoteInput()
        model?.applyCurrentMenuSnapshotWhenSafe()
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
