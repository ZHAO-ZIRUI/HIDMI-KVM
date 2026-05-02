import AppKit
import Combine

@MainActor
final class ViewMenuController: NSObject, NSMenuDelegate {
    private let menuIdentifier = NSUserInterfaceItemIdentifier("HIDMI.ViewMenu")
    private weak var model: AppModel?
    private var cancellable: AnyCancellable?
    private var pendingTopLevelRepair: DispatchWorkItem?
    private var menuItem: NSMenuItem?
    private var maintainsTopLevelMenu = false
    private var needsMenuRebuild = true
    private var isMenuTracking = false
    let menu = NSMenu(title: String(localized: "menu.view"))

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

    func install(in mainMenu: NSMenu) {
        let item: NSMenuItem
        if let viewIndex = existingViewMenuIndex(in: mainMenu),
           let existingItem = mainMenu.item(at: viewIndex) {
            item = existingItem
        } else {
            item = NSMenuItem(title: String(localized: "menu.view"), action: nil, keyEquivalent: "")
            mainMenu.insertItem(item, at: insertionIndex(in: mainMenu))
        }

        if menuItem !== item, menuItem?.submenu === menu {
            menuItem?.submenu = nil
        }

        item.title = String(localized: "menu.view")
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

        let title = String(localized: "menu.view")
        if menuItem?.title != title {
            menuItem?.title = title
        }
        if menu.title != title {
            menu.title = title
        }
        return true
    }

    func rebuildMenu() {
        guard let model else { return }
        needsMenuRebuild = false
        menu.removeAllItems()

        addVideoDeviceItems(model: model)
        menu.addItem(.separator())
        menu.addItem(deviceOptionsItem(model: model))
        menu.addItem(refreshDevicesItem())
        menu.addItem(.separator())
        menu.addItem(originalInputItem(model: model))
        menu.addItem(fitToWindowItem(model: model))
        menu.addItem(zoomInItem())
        menu.addItem(zoomOutItem())
        menu.addItem(fullScreenItem())
        clearImages(in: menu)
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

    private func existingViewMenuIndex(in mainMenu: NSMenu) -> Int? {
        let titles = [String(localized: "menu.view"), "View", "显示", "画面"]
        return mainMenu.items.firstIndex { item in
            item.identifier == menuIdentifier || titles.contains(item.title)
        }
    }

    private func insertionIndex(in mainMenu: NSMenu) -> Int {
        let editTitles = ["Edit", "编辑"]
        if let editIndex = mainMenu.items.firstIndex(where: { editTitles.contains($0.title) }) {
            return min(editIndex + 1, mainMenu.items.count)
        }
        let windowTitles = [String(localized: "menu.window"), "Window", "窗口"]
        if let windowIndex = mainMenu.items.firstIndex(where: { windowTitles.contains($0.title) }) {
            return windowIndex
        }
        return min(3, mainMenu.items.count)
    }

    private func addVideoDeviceItems(model: AppModel) {
        if model.devices.isEmpty {
            let item = NSMenuItem(title: String(localized: "device.none"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        for device in model.devices {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(selectVideoDevice(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.id
            item.state = model.selectedDeviceID == device.id ? .on : .off
            menu.addItem(item)
        }
    }

    private func deviceOptionsItem(model: AppModel) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "format.device_options"), action: nil, keyEquivalent: "")
        item.isEnabled = model.selectedDeviceID != nil

        let submenu = NSMenu(title: String(localized: "format.device_options"))
        let automatic = NSMenuItem(
            title: String(localized: "format.auto_best"),
            action: #selector(selectAutomaticFormat(_:)),
            keyEquivalent: ""
        )
        automatic.target = self
        automatic.state = model.usesAutomaticFormat ? .on : .off
        automatic.isEnabled = model.selectedDeviceID != nil
        submenu.addItem(automatic)

        submenu.addItem(.separator())
        if model.currentFormats.isEmpty {
            let empty = NSMenuItem(title: String(localized: "format.none"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for format in model.currentFormats {
                let formatItem = NSMenuItem(
                    title: format.menuTitle,
                    action: #selector(selectFormat(_:)),
                    keyEquivalent: ""
                )
                formatItem.target = self
                formatItem.representedObject = format.id
                formatItem.state = !model.usesAutomaticFormat && model.selectedFormatID == format.id ? .on : .off
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

    private func originalInputItem(model: AppModel) -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "view.original_input"),
            action: #selector(showOriginalInput(_:)),
            keyEquivalent: "0"
        )
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        item.isEnabled = model.inputSize != nil
        item.state = model.isOriginalInputMode ? .on : .off
        return item
    }

    private func fitToWindowItem(model: AppModel) -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "view.fit_to_window"),
            action: #selector(fitToWindow(_:)),
            keyEquivalent: "9"
        )
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        item.state = model.isFitToWindowMode ? .on : .off
        return item
    }

    private func zoomInItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "view.zoom_in"),
            action: #selector(performZoomIn(_:)),
            keyEquivalent: "+"
        )
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        return item
    }

    private func zoomOutItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "view.zoom_out"),
            action: #selector(performZoomOut(_:)),
            keyEquivalent: "-"
        )
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        return item
    }

    func fullScreenItem() -> NSMenuItem {
        let isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true
        let item = NSMenuItem(
            title: String(localized: isFullScreen ? "view.exit_full_screen" : "view.enter_full_screen"),
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        item.keyEquivalentModifierMask = [.control, .command]
        item.target = nil
        item.image = nil
        return item
    }

    @objc private func selectVideoDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CaptureDevice.ID else { return }
        model?.selectDevice(id)
    }

    @objc private func selectAutomaticFormat(_ sender: NSMenuItem) {
        model?.selectAutomaticFormat()
    }

    @objc private func selectFormat(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CaptureFormat.ID else { return }
        model?.selectFormat(id)
    }

    @objc private func refreshDevices(_ sender: NSMenuItem) {
        model?.refreshDevices()
    }

    @objc private func showOriginalInput(_ sender: NSMenuItem) {
        model?.showOriginalInput()
    }

    @objc private func fitToWindow(_ sender: NSMenuItem) {
        model?.fitToWindow()
    }

    @objc private func performZoomIn(_ sender: NSMenuItem) {
        model?.zoomIn()
    }

    @objc private func performZoomOut(_ sender: NSMenuItem) {
        model?.zoomOut()
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
