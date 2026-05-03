import AppKit

@MainActor
final class VideoMenuController: NSObject, NSMenuDelegate {
    private let menuIdentifier = NSUserInterfaceItemIdentifier("HIDMI.VideoMenu")
    private weak var model: AppModel?
    private var menuItem: NSMenuItem?
    let menu = NSMenu(title: String(localized: "menu.video"))

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
        if let videoIndex = existingVideoMenuIndex(in: mainMenu),
           let existingItem = mainMenu.item(at: videoIndex) {
            item = existingItem
        } else {
            item = NSMenuItem(title: String(localized: "menu.video"), action: nil, keyEquivalent: "")
            mainMenu.insertItem(item, at: insertionIndex(in: mainMenu))
        }

        if menuItem !== item, menuItem?.submenu === menu {
            menuItem?.submenu = nil
        }

        item.title = String(localized: "menu.video")
        item.action = nil
        item.keyEquivalent = ""
        item.identifier = menuIdentifier
        item.submenu = menu
        menu.delegate = self
        menuItem = item
    }

    func rebuildMenu() {
        guard let model else { return }
        let snapshot = model.menuState.snapshot
        menu.removeAllItems()

        menu.addItem(statusBarItem(snapshot: snapshot))
        menu.addItem(.separator())
        addVideoDeviceItems(snapshot: snapshot)
        menu.addItem(.separator())
        menu.addItem(deviceOptionsItem(snapshot: snapshot))
        menu.addItem(refreshDevicesItem())
        menu.addItem(.separator())
        menu.addItem(originalInputItem(snapshot: snapshot))
        menu.addItem(fitToWindowItem(snapshot: snapshot))
        clearImages(in: menu)
    }

    private func existingVideoMenuIndex(in mainMenu: NSMenu) -> Int? {
        let titles = [String(localized: "menu.video"), "Video", "画面"]
        return mainMenu.items.firstIndex { item in
            item.identifier == menuIdentifier || titles.contains(item.title)
        }
    }

    private func insertionIndex(in mainMenu: NSMenu) -> Int {
        let viewTitles = [String(localized: "menu.view"), "View", "显示"]
        if let viewIndex = mainMenu.items.firstIndex(where: { viewTitles.contains($0.title) }) {
            return min(viewIndex + 1, mainMenu.items.count)
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

    private func addVideoDeviceItems(snapshot: AppMenuSnapshot) {
        if snapshot.captureDevices.isEmpty {
            let item = NSMenuItem(title: String(localized: "device.none"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        for device in snapshot.captureDevices {
            let item = NSMenuItem(
                title: device.title,
                action: #selector(selectVideoDevice(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.id
            item.state = device.isSelected ? .on : .off
            menu.addItem(item)
        }
    }

    private func deviceOptionsItem(snapshot: AppMenuSnapshot) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "format.device_options"), action: nil, keyEquivalent: "")
        item.isEnabled = snapshot.isCaptureDeviceOptionsEnabled

        let submenu = NSMenu(title: String(localized: "format.device_options"))
        let automatic = NSMenuItem(
            title: String(localized: "format.auto_best"),
            action: #selector(selectAutomaticFormat(_:)),
            keyEquivalent: ""
        )
        automatic.target = self
        automatic.state = snapshot.usesAutomaticCaptureFormat ? .on : .off
        automatic.isEnabled = snapshot.isCaptureDeviceOptionsEnabled
        submenu.addItem(automatic)

        submenu.addItem(.separator())
        if snapshot.captureFormats.isEmpty {
            let empty = NSMenuItem(title: String(localized: "format.none"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for format in snapshot.captureFormats {
                let formatItem = NSMenuItem(
                    title: format.title,
                    action: #selector(selectFormat(_:)),
                    keyEquivalent: ""
                )
                formatItem.target = self
                formatItem.representedObject = format.id
                formatItem.state = format.isSelected ? .on : .off
                submenu.addItem(formatItem)
            }
        }

        item.submenu = submenu
        return item
    }

    private func refreshDevicesItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "device.refresh"),
            action: #selector(refreshDevices(_:)),
            keyEquivalent: "r"
        )
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        return item
    }

    private func statusBarItem(snapshot: AppMenuSnapshot) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "view.status_bar"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: String(localized: "view.status_bar"))
        submenu.autoenablesItems = false

        submenu.addItem(statusBarDetailItem(
            title: String(localized: "status_bar.icons_only"),
            mode: .iconOnly,
            snapshot: snapshot
        ))
        submenu.addItem(statusBarDetailItem(
            title: String(localized: "status_bar.detailed"),
            mode: .detailed,
            snapshot: snapshot
        ))

        submenu.addItem(.separator())

        submenu.addItem(statusBarVisibilityItem(
            title: String(localized: "status_bar.hidden"),
            visibility: .hidden,
            snapshot: snapshot
        ))
        submenu.addItem(statusBarVisibilityItem(
            title: String(localized: "status_bar.window_only"),
            visibility: .windowOnly,
            snapshot: snapshot
        ))
        submenu.addItem(statusBarVisibilityItem(
            title: String(localized: "status_bar.full_screen_only"),
            visibility: .fullScreenOnly,
            snapshot: snapshot
        ))
        submenu.addItem(statusBarVisibilityItem(
            title: String(localized: "status_bar.always_show"),
            visibility: .always,
            snapshot: snapshot
        ))

        item.submenu = submenu
        return item
    }

    private func statusBarDetailItem(
        title: String,
        mode: StatusBarDetailMode,
        snapshot: AppMenuSnapshot
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(selectStatusBarDetailMode(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = mode.rawValue
        item.state = snapshot.statusBarDetailMode == mode ? .on : .off
        return item
    }

    private func statusBarVisibilityItem(
        title: String,
        visibility: StatusBarVisibility,
        snapshot: AppMenuSnapshot
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(selectStatusBarVisibility(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = visibility.rawValue
        item.state = snapshot.statusBarVisibility == visibility ? .on : .off
        return item
    }

    private func originalInputItem(snapshot: AppMenuSnapshot) -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "view.original_input"),
            action: #selector(showOriginalInput(_:)),
            keyEquivalent: "0"
        )
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        item.isEnabled = snapshot.canShowOriginalInput
        item.state = snapshot.isOriginalInputMode ? .on : .off
        return item
    }

    private func fitToWindowItem(snapshot: AppMenuSnapshot) -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "view.fit_to_window"),
            action: #selector(fitToWindow(_:)),
            keyEquivalent: "9"
        )
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        item.state = snapshot.isFitToWindowMode ? .on : .off
        return item
    }

    @objc private func selectVideoDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CaptureDevice.ID else { return }
        model?.selectDevice(id)
        model?.applyCurrentMenuSnapshotWhenSafe()
    }

    @objc private func selectAutomaticFormat(_ sender: NSMenuItem) {
        model?.selectAutomaticFormat()
        model?.applyCurrentMenuSnapshotWhenSafe()
    }

    @objc private func selectFormat(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CaptureFormat.ID else { return }
        model?.selectFormat(id)
        model?.applyCurrentMenuSnapshotWhenSafe()
    }

    @objc private func refreshDevices(_ sender: NSMenuItem) {
        model?.refreshCaptureMenuDevices()
    }

    @objc private func selectStatusBarDetailMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = StatusBarDetailMode(rawValue: rawValue) else { return }
        model?.setStatusBarDetailMode(mode)
        model?.applyCurrentMenuSnapshotWhenSafe()
    }

    @objc private func selectStatusBarVisibility(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let visibility = StatusBarVisibility(rawValue: rawValue) else { return }
        model?.setStatusBarVisibility(visibility)
        model?.applyCurrentMenuSnapshotWhenSafe()
    }

    @objc private func showOriginalInput(_ sender: NSMenuItem) {
        model?.showOriginalInput()
        model?.applyCurrentMenuSnapshotWhenSafe()
    }

    @objc private func fitToWindow(_ sender: NSMenuItem) {
        model?.fitToWindow()
        model?.applyCurrentMenuSnapshotWhenSafe()
    }

    private func clearImages(in menu: NSMenu) {
        for item in menu.items {
            item.image = nil
            if let submenu = item.submenu {
                clearImages(in: submenu)
            }
        }
    }
}
