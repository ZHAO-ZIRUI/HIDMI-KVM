import Darwin
import AppKit
import CoreVideo
import LocalAuthentication
import Metal
import XCTest
@testable import HIDMI

@MainActor
final class HIDMIControllerTests: XCTestCase {
    func testDiscoveryPrunesOfflineDevicesAfterConfiguredInterval() {
        let store = FakeTokenStore()
        let controller = HIDMIController(
            worker: FakeHIDMIWorker(),
            tokenStore: store,
            tokenPrompt: FakeTokenPrompt(),
            offlineInterval: 45,
            now: { Date(timeIntervalSince1970: 0) }
        )
        let device = makeDevice(id: "device-a", host: "192.168.1.10")
        let start = Date(timeIntervalSince1970: 100)

        controller.mergeDiscoveredDevices([device], seenAt: start)
        XCTAssertEqual(controller.discoveredDevices.map(\.id), ["device-a"])

        controller.pruneOfflineDevices(seenAt: start.addingTimeInterval(44))
        XCTAssertEqual(controller.discoveredDevices.count, 1)

        controller.pruneOfflineDevices(seenAt: start.addingTimeInterval(46))
        XCTAssertTrue(controller.discoveredDevices.isEmpty)
    }

    func testDisplayNameUsesOfferNameAndFallsBackToIPAddress() {
        let controller = HIDMIController(
            worker: FakeHIDMIWorker(),
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        let named = makeDevice(id: "device-a", host: "192.168.1.10", name: "Rack KVM")
        let unnamed = makeDevice(id: "device-b", host: "192.168.1.11", name: "  ")

        controller.mergeDiscoveredDevices([named, unnamed], seenAt: Date())

        let devicesByID = Dictionary(uniqueKeysWithValues: controller.discoveredDevices.map { ($0.id, $0) })
        XCTAssertEqual(devicesByID["device-a"]?.menuTitle, "Rack KVM")
        XCTAssertEqual(devicesByID["device-b"]?.menuTitle, "192.168.1.11")
    }

    func testDiscoveryRefreshesInternalLastSeenWithoutPublishingTimestampOnlyChanges() {
        let controller = HIDMIController(
            worker: FakeHIDMIWorker(),
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(),
            offlineInterval: 45
        )
        let device = makeDevice(id: "device-a", host: "192.168.1.10")
        let start = Date(timeIntervalSince1970: 100)

        controller.mergeDiscoveredDevices([device], seenAt: start)
        XCTAssertEqual(controller.discoveredDevices.first?.lastSeen, start)

        controller.mergeDiscoveredDevices([device], seenAt: start.addingTimeInterval(10))

        XCTAssertEqual(controller.discoveredDevices.first?.lastSeen, start)

        controller.pruneOfflineDevices(seenAt: start.addingTimeInterval(50))
        XCTAssertEqual(controller.discoveredDevices.map(\.id), ["device-a"])

        controller.pruneOfflineDevices(seenAt: start.addingTimeInterval(56))
        XCTAssertTrue(controller.discoveredDevices.isEmpty)
    }

    func testDiscoveryPublishesAvailabilityChanges() {
        let controller = HIDMIController(
            worker: FakeHIDMIWorker(),
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(),
            offlineInterval: 45
        )
        let ready = makeDevice(id: "device-a", host: "192.168.1.10")
        let busy = makeDevice(id: "device-a", host: "192.168.1.10", availability: .busy)
        let start = Date(timeIntervalSince1970: 100)

        controller.mergeDiscoveredDevices([ready], seenAt: start)
        XCTAssertEqual(controller.discoveredDevices.first?.availability, .ready)

        controller.mergeDiscoveredDevices([busy], seenAt: start.addingTimeInterval(1))

        XCTAssertEqual(controller.discoveredDevices.first?.availability, .busy)
        XCTAssertFalse(controller.discoveredDevices.first?.isConnectable ?? true)
    }

    func testStartDiscoveryPerformsStartupAndBackgroundRefreshes() async {
        let worker = FakeHIDMIWorker()
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(),
            discoveryInterval: 0.01
        )

        controller.startDiscovery()
        controller.startDiscovery()

        await waitUntil {
            await worker.discoverBroadcastCallCount() >= 2
        }

        let discoveryCalls = await worker.discoverBroadcastCallCount()
        XCTAssertGreaterThanOrEqual(discoveryCalls, 2)
    }

    func testBackgroundDiscoveryFailureDoesNotSetVisibleFailureStatus() async {
        let worker = FakeHIDMIWorker()
        await worker.setDiscoveryError(HIDMIClientError.message("discovery failed"))
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(),
            discoveryInterval: 0.01
        )

        controller.startDiscovery()

        await waitUntil {
            await worker.discoverBroadcastCallCount() >= 1
        }

        XCTAssertEqual(controller.status, .disconnected)
        XCTAssertNil(controller.lastError)
    }

    func testAppModelStartStartsDiscoveryButDoesNotUnlockTokensOrConnect() async {
        let store = FakeTokenStore()
        store.isSessionUnlocked = false
        store.addKnownToken("saved-token")
        let authenticator = FakeAuthenticator(result: HIDMIAuthenticationContext(context: LAContext()))
        let worker = FakeHIDMIWorker()
        let hidmi = HIDMIController(
            worker: worker,
            tokenStore: store,
            tokenPrompt: FakeTokenPrompt()
        )
        let model = AppModel(
            tokenStore: store,
            authenticator: authenticator,
            hidmi: hidmi,
            cameraPermissionManager: FakeCameraPermissionManager(status: .authorized),
            startsVideoInputSetup: true
        )

        model.start()

        await waitUntil {
            await worker.discoverBroadcastCallCount() >= 1
        }

        let discoveryCalls = await worker.discoverBroadcastCallCount()
        let attempts = await worker.connectAttempts()
        XCTAssertTrue(authenticator.reasons.isEmpty)
        XCTAssertEqual(store.unlockSavedTokensCount, 0)
        XCTAssertEqual(discoveryCalls, 1)
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertFalse(model.hidmi.isConnected)
        XCTAssertNil(model.selectedDeviceID)
    }

    func testEthernetMenuDetailsOmitPorts() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", name: "Rack KVM", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        XCTAssertEqual(controller.menuDeviceStates.first?.menuDetails.map(\.kind), [.transport, .ipAddress])

        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        XCTAssertEqual(controller.menuDeviceStates.first?.menuDetails.map(\.kind), [.transport, .ipAddress])
    }

    func testHIDMenuMarkersShowOnlyConnectedDeviceState() {
        XCTAssertEqual(HIDMIMenuSelectionMarker.available.menuItemState, .off)
        XCTAssertEqual(HIDMIMenuSelectionMarker.selected.menuItemState, .off)
        XCTAssertEqual(HIDMIMenuSelectionMarker.connected.menuItemState, .on)
    }

    func testInputMenuOmitsConnectionStatusAndLastErrorItems() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setConnectError(HIDMIClientError.message("connection refused"))
        let warnings = FakeConnectionWarningPresenter()
        let hidmi = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(),
            warningPresenter: warnings
        )
        let model = AppModel(
            hidmi: hidmi,
            cameraPermissionManager: FakeCameraPermissionManager(status: .authorized),
            startsVideoInputSetup: false
        )
        let menuController = HIDInputMenuController()
        menuController.bind(model: model)

        hidmi.mergeDiscoveredDevices([device], seenAt: Date())
        model.connectHIDMI(device.discoveryID)
        await waitUntil {
            if case .failed = hidmi.status {
                return true
            }
            return false
        }
        menuController.rebuildMenu()

        let titles = menuController.menu.items.map(\.title)
        XCTAssertFalse(titles.contains(String(format: String(localized: "hid.status"), hidmi.menuConnectionStatusText)))
        if let lastError = hidmi.lastError {
            XCTAssertFalse(titles.contains(String(format: String(localized: "hid.last_error"), lastError)))
        }
    }

    func testInputMenuRefreshDoesNotReplaceTopLevelMenuItem() async throws {
        let previousMainMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMainMenu }

        let mainMenu = NSMenu(title: "Test Main Menu")
        mainMenu.addItem(NSMenuItem(title: "HIDMI", action: nil, keyEquivalent: ""))
        mainMenu.addItem(NSMenuItem(title: String(localized: "menu.view"), action: nil, keyEquivalent: ""))
        NSApp.mainMenu = mainMenu

        let hidmi = HIDMIController(
            worker: FakeHIDMIWorker(),
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        let model = AppModel(
            hidmi: hidmi,
            cameraPermissionManager: FakeCameraPermissionManager(status: .authorized),
            startsVideoInputSetup: false
        )
        let menuController = HIDInputMenuController()
        menuController.bind(model: model)
        menuController.installOrUpdate()

        let originalItem = try XCTUnwrap(mainMenu.items.first { $0.submenu === menuController.menu })
        let originalCount = mainMenu.items.count

        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        hidmi.mergeDiscoveredDevices([device], seenAt: Date())
        XCTAssertFalse(menuController.menu.items.contains { $0.title == device.displayName })
        menuController.menuNeedsUpdate(menuController.menu)

        let updatedItem = try XCTUnwrap(mainMenu.items.first { $0.submenu === menuController.menu })
        XCTAssertTrue(updatedItem === originalItem)
        XCTAssertEqual(mainMenu.items.count, originalCount)
        XCTAssertTrue(menuController.menu.items.contains { $0.title == device.displayName })
    }

    func testInputMenuInstallsAfterHelpMenuToAvoidSystemMenuClobbering() throws {
        let previousMainMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMainMenu }

        let mainMenu = NSMenu(title: "Test Main Menu")
        mainMenu.addItem(NSMenuItem(title: "HIDMI", action: nil, keyEquivalent: ""))
        mainMenu.addItem(NSMenuItem(title: String(localized: "menu.view"), action: nil, keyEquivalent: ""))
        mainMenu.addItem(NSMenuItem(title: String(localized: "menu.window"), action: nil, keyEquivalent: ""))
        mainMenu.addItem(NSMenuItem(title: "Help", action: nil, keyEquivalent: ""))
        NSApp.mainMenu = mainMenu

        let hidmi = HIDMIController(
            worker: FakeHIDMIWorker(),
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        let model = AppModel(
            hidmi: hidmi,
            cameraPermissionManager: FakeCameraPermissionManager(status: .authorized),
            startsVideoInputSetup: false
        )
        let menuController = HIDInputMenuController()
        menuController.bind(model: model)
        menuController.installOrUpdate()

        let inputIndex = try XCTUnwrap(mainMenu.items.firstIndex { $0.submenu === menuController.menu })
        let windowIndex = try XCTUnwrap(mainMenu.items.firstIndex { $0.title == String(localized: "menu.window") })
        let helpIndex = try XCTUnwrap(mainMenu.items.firstIndex { $0.title == "Help" })
        XCTAssertGreaterThan(inputIndex, windowIndex)
        XCTAssertGreaterThan(inputIndex, helpIndex)
    }

    func testCustomMenusRepairTopLevelOnModelChangeWithoutEagerSubmenuRebuild() async throws {
        let previousMainMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMainMenu }

        let originalMainMenu = NSMenu(title: "Original Main Menu")
        originalMainMenu.addItem(NSMenuItem(title: "HIDMI", action: nil, keyEquivalent: ""))
        originalMainMenu.addItem(NSMenuItem(title: String(localized: "menu.view"), action: nil, keyEquivalent: ""))
        originalMainMenu.addItem(NSMenuItem(title: String(localized: "menu.window"), action: nil, keyEquivalent: ""))
        NSApp.mainMenu = originalMainMenu

        let hidmi = HIDMIController(
            worker: FakeHIDMIWorker(),
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        let model = AppModel(
            hidmi: hidmi,
            cameraPermissionManager: FakeCameraPermissionManager(status: .authorized),
            startsVideoInputSetup: false
        )
        let inputMenu = HIDInputMenuController()
        let viewMenu = ViewMenuController()
        inputMenu.bind(model: model)
        viewMenu.bind(model: model)
        viewMenu.installOrUpdate()
        inputMenu.installOrUpdate()

        _ = try XCTUnwrap(originalMainMenu.items.first { $0.submenu === inputMenu.menu })
        _ = try XCTUnwrap(originalMainMenu.items.first { $0.submenu === viewMenu.menu })

        let recreatedMainMenu = NSMenu(title: "Recreated Main Menu")
        recreatedMainMenu.addItem(NSMenuItem(title: "HIDMI", action: nil, keyEquivalent: ""))
        recreatedMainMenu.addItem(NSMenuItem(title: String(localized: "menu.view"), action: nil, keyEquivalent: ""))
        recreatedMainMenu.addItem(NSMenuItem(title: String(localized: "menu.window"), action: nil, keyEquivalent: ""))
        NSApp.mainMenu = recreatedMainMenu

        let device = makeDevice(id: "device-a", host: "192.168.1.10", name: "Lazy KVM", requiresAuth: false)
        hidmi.mergeDiscoveredDevices([device], seenAt: Date())
        await waitUntil {
            recreatedMainMenu.items.contains { $0.submenu === inputMenu.menu }
                && recreatedMainMenu.items.contains { $0.submenu === viewMenu.menu }
        }

        XCTAssertTrue(recreatedMainMenu.items.contains { $0.submenu === inputMenu.menu })
        XCTAssertTrue(recreatedMainMenu.items.contains { $0.submenu === viewMenu.menu })
        XCTAssertFalse(inputMenu.menu.items.contains { $0.title == device.displayName })

        inputMenu.menuNeedsUpdate(inputMenu.menu)
        XCTAssertTrue(inputMenu.menu.items.contains { $0.title == device.displayName })
    }

    func testCustomMenusRepairWhenSystemClobbersSubmenus() throws {
        let previousMainMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMainMenu }

        let mainMenu = NSMenu(title: "Test Main Menu")
        mainMenu.addItem(NSMenuItem(title: "HIDMI", action: nil, keyEquivalent: ""))
        mainMenu.addItem(NSMenuItem(title: String(localized: "menu.view"), action: nil, keyEquivalent: ""))
        mainMenu.addItem(NSMenuItem(title: String(localized: "menu.window"), action: nil, keyEquivalent: ""))
        NSApp.mainMenu = mainMenu

        let hidmi = HIDMIController(
            worker: FakeHIDMIWorker(),
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        let model = AppModel(
            hidmi: hidmi,
            cameraPermissionManager: FakeCameraPermissionManager(status: .authorized),
            startsVideoInputSetup: false
        )
        let inputMenu = HIDInputMenuController()
        let viewMenu = ViewMenuController()
        inputMenu.bind(model: model)
        viewMenu.bind(model: model)
        viewMenu.installOrUpdate()
        inputMenu.installOrUpdate()

        try XCTUnwrap(mainMenu.items.first { $0.submenu === inputMenu.menu }).submenu = NSMenu(title: "Clobbered Input")
        try XCTUnwrap(mainMenu.items.first { $0.submenu === viewMenu.menu }).submenu = NSMenu(title: "Clobbered View")

        viewMenu.repairTopLevelInstallation()
        inputMenu.repairTopLevelInstallation()

        XCTAssertTrue(mainMenu.items.contains { $0.submenu === inputMenu.menu })
        XCTAssertTrue(mainMenu.items.contains { $0.submenu === viewMenu.menu })
    }

    func testMenuTrackingSuspendsRemoteInputAndReleasesOnce() async throws {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let hidmi = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        let model = AppModel(
            hidmi: hidmi,
            cameraPermissionManager: FakeCameraPermissionManager(status: .authorized),
            startsVideoInputSetup: false
        )
        let inputMenu = HIDInputMenuController()
        inputMenu.bind(model: model)
        let viewMenu = ViewMenuController()
        viewMenu.bind(model: model)

        hidmi.mergeDiscoveredDevices([device], seenAt: Date())
        model.connectHIDMI(device.discoveryID)
        await waitUntil { hidmi.isConnected }

        let event = try makeKeyEvent()
        XCTAssertTrue(model.handleRemoteInput(.keyDown(event)))
        await waitUntil { await worker.sentReportCount() == 1 }

        inputMenu.menuWillOpen(inputMenu.menu)
        XCTAssertTrue(model.isRemoteInputSuspendedByMenu)
        XCTAssertFalse(model.handleRemoteInput(.keyDown(event)))
        await waitUntil { await worker.bestEffortReleaseAllCallCount() == 1 }
        let suspendedReportCount = await worker.sentReportCount()
        let initialReleaseCount = await worker.bestEffortReleaseAllCallCount()
        XCTAssertEqual(suspendedReportCount, 1)
        XCTAssertEqual(initialReleaseCount, 1)

        viewMenu.menuWillOpen(viewMenu.menu)
        try? await Task.sleep(for: .milliseconds(30))
        let nestedReleaseCount = await worker.bestEffortReleaseAllCallCount()
        XCTAssertEqual(nestedReleaseCount, 1)
        viewMenu.menuDidClose(viewMenu.menu)
        XCTAssertTrue(model.isRemoteInputSuspendedByMenu)

        inputMenu.menuDidClose(inputMenu.menu)
        XCTAssertFalse(model.isRemoteInputSuspendedByMenu)
        XCTAssertTrue(model.handleRemoteInput(.keyDown(event)))
        await waitUntil { await worker.sentReportCount() == 2 }
    }

    func testRemoteInputMapperResetReturnsCompleteReleaseReports() throws {
        var mapper = RemoteInputMapper()
        let key = try makeKeyEvent()
        let mouse = try makeMouseEvent(type: .leftMouseDown)

        XCTAssertFalse(mapper.map(.keyDown(key)).isEmpty)
        XCTAssertEqual(
            mapper.map(.mouseDown(mouse, button: 1, absolute: RemoteAbsolutePointer(x: 123, y: 456)), preferAbsolute: true),
            [.absoluteMouse(buttons: 1, x: 123, y: 456)]
        )

        let releases = mapper.reset()

        XCTAssertEqual(
            releases,
            [
                .keyboard(modifiers: 0, keys: []),
                .mouse(buttons: 0, dx: 0, dy: 0, wheel: 0),
                .absoluteMouse(buttons: 0, x: 123, y: 456)
            ]
        )
        XCTAssertEqual(mapper.reset(), [.keyboard(modifiers: 0, keys: [])])
    }

    func testMappedEmptyReasonIdentifiesAbsolutePointerGate() throws {
        let event = try makeMouseEvent()

        XCTAssertEqual(
            RemoteInputEvent.mouseMoved(event, scale: .zero, absolute: nil)
                .mappedEmptyReason(preferAbsolute: true),
            "absolute_pointer_unavailable"
        )
    }

    func testAbsolutePointerReportsKeepRelativeFallbackDeltas() throws {
        var mapper = RemoteInputMapper()
        let event = try makeMouseMovedEvent(deltaX: 6, deltaY: -4)

        let reports = mapper.map(
            .mouseMoved(event, scale: CGSize(width: 2, height: 3), absolute: RemoteAbsolutePointer(x: 111, y: 222)),
            preferAbsolute: true
        )

        XCTAssertEqual(reports, [.absoluteMouse(buttons: 0, x: 111, y: 222, dx: 12, dy: -12)])
    }

    func testMouseFrameStateAssignsSeqAndSampleTimestamp() throws {
        var state = HIDMIMouseFrameState()

        let first = try state.makeFrame(
            sessionID: 42,
            report: .absoluteMouse(buttons: 0, x: 100, y: 200),
            sampleMonoUs: 111
        )
        let second = try state.makeFrame(
            sessionID: 42,
            report: .absoluteMouse(buttons: 1, x: 101, y: 201),
            sampleMonoUs: 222
        )

        XCTAssertEqual(first.sessionID, 42)
        XCTAssertEqual(first.channelID, .channelMouse)
        XCTAssertEqual(first.seq, 1)
        XCTAssertEqual(first.mouseState.sampleMonoUs, 111)
        XCTAssertEqual(second.seq, 2)
        XCTAssertEqual(second.mouseState.sampleMonoUs, 222)
        XCTAssertTrue(second.mouseState.hasReliableEdge_p)
    }

    func testMouseFrameStateCarriesRelativeFallbackDeltas() throws {
        var state = HIDMIMouseFrameState()

        let absolute = try state.makeFrame(
            sessionID: 42,
            report: .absoluteMouse(buttons: 0, x: 100, y: 200, dx: 7, dy: -5),
            sampleMonoUs: 111
        )
        let relative = try state.makeFrame(
            sessionID: 42,
            report: .mouse(buttons: 1, dx: -130, dy: 128, wheel: 3),
            sampleMonoUs: 222
        )

        XCTAssertEqual(absolute.mouseState.absX, 100)
        XCTAssertEqual(absolute.mouseState.absY, 200)
        XCTAssertEqual(absolute.mouseState.relDx, 7)
        XCTAssertEqual(absolute.mouseState.relDy, -5)
        XCTAssertEqual(relative.mouseState.absX, 100)
        XCTAssertEqual(relative.mouseState.absY, 200)
        XCTAssertEqual(relative.mouseState.relDx, -127)
        XCTAssertEqual(relative.mouseState.relDy, 127)
        XCTAssertEqual(relative.mouseState.wheelDeltaY, 3)
        XCTAssertTrue(relative.mouseState.hasReliableEdge_p)
    }

    func testSendReportsSendsEachEventBatchWithoutDroppingReports() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        let reports = (0..<1_000).map { index in
            RemoteInputReport.absoluteMouse(buttons: 0, x: index % 32_768, y: (index * 2) % 32_768)
        }
        for report in reports {
            controller.sendReports([report])
        }

        await waitUntil { await worker.sentReportCount() == reports.count }
        let sentReports = await worker.sentReportsSnapshot()
        XCTAssertEqual(sentReports, reports)
        let callCount = await worker.sendReportsCallCount()
        XCTAssertEqual(callCount, reports.count)
    }

    func testPointerMoveReportsSendImmediately() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        let reports = (0..<5).map { RemoteInputReport.absoluteMouse(buttons: 0, x: $0, y: $0) }
        for report in reports {
            controller.sendReports([report], source: .pointerMove)
        }

        await waitUntil { await worker.sentReportCount() == reports.count }
        let sentReports = await worker.sentReportsSnapshot()
        XCTAssertEqual(sentReports.count, reports.count)
        for report in reports {
            XCTAssertTrue(sentReports.contains(report))
        }
        XCTAssertEqual(controller.inputDiagnostics.mouseEventsCaptured, reports.count)
        XCTAssertEqual(controller.inputDiagnostics.mouseReportsWritten, reports.count)
    }

    func testPointerMoveReportsCarryCaptureTimestampToMouseWriter() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        controller.sendReports(
            [.absoluteMouse(buttons: 0, x: 10, y: 11)],
            source: .pointerMove,
            sampleMonoUs: 123_456
        )

        await waitUntil { await worker.sentReportCount() == 1 }
        let sampledReports = await worker.sampledReportsSnapshot()
        XCTAssertEqual(sampledReports.map(\.sampleMonoUs), [123_456])
    }

    func testKeyboardReportsUseDedicatedWriterAndBypassWorkerActor() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        await worker.setSendReportsDelay(0.03)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        controller.sendReports(
            [.keyboard(modifiers: 0, keys: [4])],
            sampleMonoUs: 654_321
        )

        await waitUntil { await worker.sentReportCount() == 1 }
        let sentReports = await worker.sentReportsSnapshot()
        XCTAssertEqual(sentReports, [.keyboard(modifiers: 0, keys: [4])])
        let sampledReports = await worker.sampledReportsSnapshot()
        XCTAssertEqual(sampledReports.map(\.sampleMonoUs), [654_321])
        let workerSendReportsCalls = await worker.workerSendReportsCallCount()
        XCTAssertEqual(workerSendReportsCalls, 0)
    }

    func testKeyboardReportsAreOrderedWithSlowWriter() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        await worker.setSendReportsDelay(0.02)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        let reports: [RemoteInputReport] = [
            .keyboard(modifiers: 0, keys: [4]),
            .keyboard(modifiers: 2, keys: [4, 5]),
            .keyboard(modifiers: 0, keys: [])
        ]
        for report in reports {
            controller.sendReports([report])
        }

        await waitUntil { await worker.sentReportCount() == reports.count }
        let sentReports = await worker.sentReportsSnapshot()
        XCTAssertEqual(sentReports, reports)
        let workerSendReportsCalls = await worker.workerSendReportsCallCount()
        XCTAssertEqual(workerSendReportsCalls, 0)
    }

    func testKeyboardFrameStateAssignsSeqAndClampsSnapshot() {
        var state = HIDMIKeyboardFrameState()

        let first = state.makeKeyboardStateFrame(
            sessionID: 42,
            modifiers: 0x1ff,
            keys: [1, 256, 4, 5, 6, 7, 8]
        )
        let second = state.makeKeyboardSpecialFrame(
            sessionID: 42,
            special: .keyboardSpecialCtrlAltDel
        )

        XCTAssertEqual(first.sessionID, 42)
        XCTAssertEqual(first.channelID, .channelKeyboard)
        XCTAssertEqual(first.seq, 1)
        XCTAssertEqual(first.keyboardState.modifierMask, 0xff)
        XCTAssertEqual(first.keyboardState.pressedUsageIds, [1, 0xff, 4, 5, 6, 7])
        XCTAssertEqual(second.seq, 2)
        XCTAssertEqual(second.keyboardSpecial.specID, .keyboardSpecialCtrlAltDel)
    }

    func testPointerMovesAreNotCoalescedWithSlowWorker() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        await worker.setSendReportsDelay(0.03)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        let reports = (0..<10).map { RemoteInputReport.absoluteMouse(buttons: 0, x: $0, y: $0) }
        for report in reports {
            controller.sendReports([report], source: .pointerMove)
        }

        await waitUntil { await worker.sentReportCount() == reports.count }
        let sentReports = await worker.sentReportsSnapshot()
        XCTAssertEqual(sentReports.count, reports.count)
        for report in reports {
            XCTAssertTrue(sentReports.contains(report))
        }
        XCTAssertEqual(controller.inputDiagnostics.mouseEventsCaptured, reports.count)
        XCTAssertEqual(controller.inputDiagnostics.mouseReportsWritten, reports.count)
    }

    func testReliableReportDoesNotDropEarlierPointerMoves() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        await worker.setSendReportsDelay(0.03)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        let firstMove = RemoteInputReport.absoluteMouse(buttons: 0, x: 10, y: 10)
        let stalePendingMove = RemoteInputReport.absoluteMouse(buttons: 0, x: 20, y: 20)
        let buttonEdge = RemoteInputReport.absoluteMouse(buttons: 1, x: 21, y: 21)
        controller.sendReports([firstMove], source: .pointerMove)
        controller.sendReports([stalePendingMove], source: .pointerMove)
        controller.sendReports([buttonEdge], source: .reliable)

        await waitUntil { await worker.sentReportCount() == 3 }
        let sentReports = await worker.sentReportsSnapshot()
        XCTAssertEqual(sentReports.count, 3)
        XCTAssertTrue(sentReports.contains(firstMove))
        XCTAssertTrue(sentReports.contains(stalePendingMove))
        XCTAssertTrue(sentReports.contains(buttonEdge))
    }

    func testPointerMoveBurstSendsEveryCapturedEvent() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        let reports = (0..<50).map { RemoteInputReport.absoluteMouse(buttons: 0, x: $0, y: $0) }
        for report in reports {
            controller.sendReports([report], source: .pointerMove)
        }

        await waitUntil { await worker.sentReportCount() == reports.count }
        let sentReports = await worker.sentReportsSnapshot()
        XCTAssertEqual(sentReports, reports)
    }

    func testExtraCapabilityDoesNotEnableClientSideFlowControl() async {
        let device = makeDevice(
            id: "device-a",
            host: "192.168.1.10",
            requiresAuth: false,
            capabilities: ["keyboard", "mouse", "release_all", "absolute_pointer", "future_capability"]
        )
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        controller.sendReports([.absoluteMouse(buttons: 0, x: 10, y: 11)], source: .pointerMove)

        await waitUntil { await worker.sentReportCount() == 1 }
        let sentReports = await worker.sentReportsSnapshot()
        XCTAssertEqual(sentReports, [.absoluteMouse(buttons: 0, x: 10, y: 11)])
    }

    func testStaleInputFailureAfterReconnectIsIgnored() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        await worker.setSendReportsDelay(0.05)
        await worker.setSendReportsError(HIDMIClientError.message(String(localized: "error.socket_closed")))
        let warnings = FakeConnectionWarningPresenter()
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(),
            warningPresenter: warnings,
            reconnectDelays: []
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        controller.sendReports([.keyboard(modifiers: 0, keys: [4])])
        try? await Task.sleep(for: .milliseconds(10))
        controller.connect(to: device.discoveryID)

        await waitUntil { await worker.connectAttempts().count >= 2 }
        await waitUntil { controller.isConnected }
        XCTAssertTrue(warnings.lostWarnings.isEmpty)
        XCTAssertTrue(warnings.failureWarnings.isEmpty)
    }

    func testBackgroundBusyDiscoveryDoesNotDropActiveConnection() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        await worker.setDiscoveryError(HIDMIClientError.server(code: "BUSY", detail: "A client is already active"))
        controller.refreshDiscoveredDevices(source: .background)
        await waitUntil { await worker.discoverBroadcastCallCount() >= 1 }

        XCTAssertTrue(controller.isConnected)
        if case .connected = controller.status {
            XCTAssertTrue(true)
        } else {
            XCTFail("background BUSY discovery should not replace the connected state")
        }
    }

    func testAbsolutePointerCapabilityControlsRemotePointerMode() async {
        let device = makeDevice(
            id: "device-a",
            host: "192.168.1.10",
            requiresAuth: false,
            capabilities: ["keyboard", "mouse", "release_all"]
        )
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        XCTAssertFalse(controller.usesAbsolutePointer)
    }

    func testPreviewHostViewIgnoresRemoteInputWhenDisabled() throws {
        let view = PreviewHostView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var handledEvents = 0
        view.inputHandler = { _ in
            handledEvents += 1
            return true
        }
        let keyEvent = try makeKeyEvent()
        let mouseEvent = try makeMouseEvent()

        view.isRemoteInputEnabled = false
        XCTAssertFalse(view.acceptsFirstResponder)
        view.mouseMoved(with: mouseEvent)
        view.keyDown(with: keyEvent)
        XCTAssertEqual(handledEvents, 0)

        view.isRemoteInputEnabled = true
        XCTAssertTrue(view.acceptsFirstResponder)
        view.keyDown(with: keyEvent)
        XCTAssertEqual(handledEvents, 1)
    }

    func testPreviewHostViewRequestsFirstResponderWhenRemoteInputIsEnabled() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = PreviewHostView(frame: window.contentView?.bounds ?? .zero)
        view.isRemoteInputEnabled = false
        window.contentView = view
        defer {
            window.contentView = NSView(frame: .zero)
            window.orderOut(nil)
        }

        XCTAssertFalse(window.firstResponder === view)
        view.isRemoteInputEnabled = true

        XCTAssertTrue(window.firstResponder === view)
    }

    func testCaptureDeviceIdentityFilterExcludesIPhoneAndContinuityCamera() {
        XCTAssertTrue(CaptureDeviceStore.shouldExcludeVideoDeviceIdentity(
            name: "Garry's iPhone Camera",
            modelID: "UVC Camera",
            uniqueID: "camera-1",
            isContinuityCamera: false
        ))
        XCTAssertTrue(CaptureDeviceStore.shouldExcludeVideoDeviceIdentity(
            name: "Continuity Camera",
            modelID: "camera",
            uniqueID: "camera-2",
            isContinuityCamera: false
        ))
        XCTAssertTrue(CaptureDeviceStore.shouldExcludeVideoDeviceIdentity(
            name: "Capture Card",
            modelID: "UVC Camera",
            uniqueID: "camera-3",
            isContinuityCamera: true
        ))
        XCTAssertFalse(CaptureDeviceStore.shouldExcludeVideoDeviceIdentity(
            name: "USB Video",
            modelID: "UVC Camera",
            uniqueID: "camera-4",
            isContinuityCamera: false
        ))
    }

    func testCaptureFormatPreferenceRestoresAvailableFormatAndFallsBackToAutomatic() {
        let preferred = makeCaptureFormat(id: "capture-a#2", width: 1920, height: 1080, maxFrameRate: 59.94, mediaSubType: fourCC("MJPG"))
        let alternate = makeCaptureFormat(id: "capture-a#1", width: 1280, height: 720, maxFrameRate: 60, mediaSubType: fourCC("MJPG"))
        let preference = CaptureFormatPreference.explicit(CaptureFormatSignature(format: preferred))

        XCTAssertEqual(
            CaptureDeviceStore.resolvedFormatSelection(preference: preference, formats: [alternate, preferred]),
            .explicit(preferred.id)
        )
        XCTAssertEqual(
            CaptureDeviceStore.resolvedFormatSelection(preference: preference, formats: [alternate]),
            .automatic
        )
        XCTAssertEqual(
            CaptureDeviceStore.resolvedFormatSelection(preference: .automatic, formats: [preferred]),
            .automatic
        )
    }

    func testCaptureFormatPreferenceStorePersistsAutomaticAndExplicitSelections() throws {
        let suiteName = "HIDMICaptureFormatPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = UserDefaultsCaptureFormatPreferenceStore(defaults: defaults)
        let signature = CaptureFormatSignature(width: 1920, height: 1080, maxFrameRate: 60, mediaSubType: fourCC("NV12"))

        store.setPreference(.explicit(signature), for: "capture-a")
        XCTAssertEqual(store.preference(for: "capture-a"), .explicit(signature))

        let reloadedStore = UserDefaultsCaptureFormatPreferenceStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.preference(for: "capture-a"), .explicit(signature))

        reloadedStore.setPreference(.automatic, for: "capture-a")
        XCTAssertEqual(store.preference(for: "capture-a"), .automatic)
    }

    func testOriginalInputSizingUsesBackingScaleAndPixelAlignment() {
        XCTAssertEqual(
            PreviewSizing.frameSize(
                mode: .scaled(1.0),
                inputSize: CGSize(width: 3840, height: 2160),
                availableSize: CGSize(width: 5000, height: 3000),
                backingScaleFactor: 2
            ),
            CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(
            PreviewSizing.frameSize(
                mode: .fit,
                inputSize: CGSize(width: 3840, height: 2160),
                availableSize: CGSize(width: 100.75, height: 80.75),
                backingScaleFactor: 2
            ),
            CGSize(width: 100.5, height: 56.5)
        )
    }

    func testPreviewLayoutTopReservedHeightOnlyAppliesOutsideFullScreen() {
        XCTAssertEqual(PreviewLayout.topReservedHeight(isFullScreen: false), 32)
        XCTAssertEqual(PreviewLayout.topReservedHeight(isFullScreen: true), 0)
    }

    func testPreviewRenderGeometryAlignsDrawableAndAspectFitRectToPhysicalPixels() {
        XCTAssertEqual(
            PreviewRenderGeometry.drawableSize(
                boundsSize: CGSize(width: 100.75, height: 80.75),
                backingScaleFactor: 2
            ),
            CGSize(width: 201, height: 161)
        )

        XCTAssertEqual(
            PreviewRenderGeometry.aspectFitRect(
                sourceSize: CGSize(width: 3840, height: 2160),
                destinationSize: CGSize(width: 201, height: 161)
            ),
            CGRect(x: 0, y: 24, width: 201, height: 113)
        )
    }

    func testCaptureSessionPresetPolicyPrefersResolutionSpecificPresets() {
        XCTAssertEqual(
            CaptureSessionPresetPolicy.preferredPresets(
                for: VideoDimensions(width: 3840, height: 2160)
            ).first,
            .hd4K3840x2160
        )
        XCTAssertEqual(
            CaptureSessionPresetPolicy.preferredPresets(
                for: VideoDimensions(width: 1920, height: 1080)
            ).first,
            .hd1920x1080
        )
        XCTAssertEqual(
            CaptureSessionPresetPolicy.preferredPresets(for: nil),
            [.high]
        )
    }

    func testCaptureVideoOutputSettingsPreferBiPlanarFormatsAndFallbackToBGRA() {
        let videoRange = CaptureVideoOutputSettings.videoSettings(
            supportedPixelFormats: [
                kCVPixelFormatType_32BGRA,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        XCTAssertEqual(
            videoRange?[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        let bgra = CaptureVideoOutputSettings.videoSettings(
            supportedPixelFormats: [kCVPixelFormatType_32BGRA]
        )
        XCTAssertEqual(bgra?[kCVPixelBufferPixelFormatTypeKey as String] as? OSType, kCVPixelFormatType_32BGRA)
        XCTAssertNil(CaptureVideoOutputSettings.videoSettings(supportedPixelFormats: []))
    }

    func testAppModelUsesActualFrameDimensionsAsInputSize() {
        let model = AppModel(startsVideoInputSetup: false)
        let descriptor = CaptureFrameDescriptor(
            dimensions: VideoDimensions(width: 3840, height: 2160),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        model.updateActualVideoFrame(descriptor)

        XCTAssertEqual(model.inputSize, CGSize(width: 3840, height: 2160))
    }

    func testAppModelDebouncesTransientFrameDimensionChanges() async {
        let model = AppModel(startsVideoInputSetup: false, frameStabilizationInterval: 0.05)
        let fourK = CaptureFrameDescriptor(
            dimensions: VideoDimensions(width: 3840, height: 2160),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let fullHD = CaptureFrameDescriptor(
            dimensions: VideoDimensions(width: 1920, height: 1080),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        model.updateActualVideoFrame(fourK)
        model.updateActualVideoFrame(fullHD)
        model.updateActualVideoFrame(fourK)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(model.inputSize, CGSize(width: 3840, height: 2160))

        model.updateActualVideoFrame(fullHD)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(model.inputSize, CGSize(width: 1920, height: 1080))
    }

    func testCaptureFrameDescriptorReporterOnlyReportsChanges() {
        let reporter = CaptureFrameDescriptorReporter()
        let fourK = CaptureFrameDescriptor(
            dimensions: VideoDimensions(width: 3840, height: 2160),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let fullHD = CaptureFrameDescriptor(
            dimensions: VideoDimensions(width: 1920, height: 1080),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        XCTAssertNotNil(reporter.observationIfNeeded(fourK, reportGeneration: 0))
        XCTAssertNil(reporter.observationIfNeeded(fourK, reportGeneration: 0))
        XCTAssertNotNil(reporter.observationIfNeeded(fullHD, reportGeneration: 0))

        reporter.reset()
        XCTAssertNotNil(reporter.observationIfNeeded(fullHD, reportGeneration: 0))
    }

    func testCaptureFrameDescriptorReporterReportsFirstFrameForNewGeneration() throws {
        let reporter = CaptureFrameDescriptorReporter()
        let fourK = CaptureFrameDescriptor(
            dimensions: VideoDimensions(width: 3840, height: 2160),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        let first = try XCTUnwrap(reporter.observationIfNeeded(fourK, reportGeneration: 1))
        XCTAssertNil(reporter.observationIfNeeded(fourK, reportGeneration: 1))
        let nextGeneration = try XCTUnwrap(reporter.observationIfNeeded(fourK, reportGeneration: 2))

        XCTAssertGreaterThan(nextGeneration.sequence, first.sequence)
        XCTAssertEqual(nextGeneration.reportGeneration, 2)
    }

    func testCaptureFormatFallbackPolicyPrefersStableActualFormatThenPreviousSelection() {
        let fourK = makeCaptureFormat(id: "capture-a#1", width: 3840, height: 2160, maxFrameRate: 30, mediaSubType: fourCC("MJPG"))
        let fullHD = makeCaptureFormat(id: "capture-a#2", width: 1920, height: 1080, maxFrameRate: 60, mediaSubType: fourCC("MJPG"))

        XCTAssertEqual(
            CaptureFormatFallbackPolicy.fallbackSelection(
                stableDimensions: fullHD.dimensions,
                previousSelection: .explicit(fourK.id),
                formats: [fourK, fullHD]
            ),
            .explicit(fullHD.id)
        )
        XCTAssertEqual(
            CaptureFormatFallbackPolicy.fallbackSelection(
                stableDimensions: VideoDimensions(width: 1280, height: 720),
                previousSelection: .explicit(fourK.id),
                formats: [fourK, fullHD]
            ),
            .explicit(fourK.id)
        )
    }

    func testCaptureFormatConfirmationRequiresExactActiveFormatSignature() {
        let target = CaptureFormatSignature(
            width: 3840,
            height: 2160,
            maxFrameRate: 60,
            mediaSubType: fourCC("MJPG")
        )
        let sameDimensionsDifferentSubtype = CaptureFormatSignature(
            width: 3840,
            height: 2160,
            maxFrameRate: 60,
            mediaSubType: fourCC("NV12")
        )
        let descriptor = CaptureFrameDescriptor(
            dimensions: VideoDimensions(width: 3840, height: 2160),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        XCTAssertTrue(CaptureFormatFallbackPolicy.matches(
            targetSignature: nil,
            activeFormatSignature: nil,
            descriptor: descriptor
        ))
        XCTAssertTrue(CaptureFormatFallbackPolicy.matches(
            targetSignature: target,
            activeFormatSignature: target,
            descriptor: descriptor
        ))
        XCTAssertFalse(CaptureFormatFallbackPolicy.matches(
            targetSignature: target,
            activeFormatSignature: sameDimensionsDifferentSubtype,
            descriptor: descriptor
        ))
        XCTAssertFalse(CaptureFormatFallbackPolicy.matches(
            targetSignature: target,
            activeFormatSignature: nil,
            descriptor: descriptor
        ))
    }

    func testCaptureStreamChangePolicyDoesNotReconfigureForFormatDescriptionChanges() {
        XCTAssertFalse(CaptureStreamChangePolicy.requiresSessionReconfiguration(.formatDescription))
        XCTAssertTrue(CaptureStreamChangePolicy.requiresSessionReconfiguration(.sessionFailure))
    }

    func testCameraPermissionStartupRequestsOnlyWhenNotDeterminedAndShowsSettingsActionWhenDenied() async {
        let notDetermined = FakeCameraPermissionManager(status: .notDetermined, requestResult: false)
        let requestingModel = AppModel(
            cameraPermissionManager: notDetermined,
            startsVideoInputSetup: true
        )

        requestingModel.start()
        requestingModel.start()

        XCTAssertEqual(notDetermined.requestAccessCount, 1)
        await waitUntil { requestingModel.showsCameraPermissionSettingsAction }

        let denied = FakeCameraPermissionManager(status: .denied)
        let deniedModel = AppModel(
            cameraPermissionManager: denied,
            startsVideoInputSetup: true
        )

        deniedModel.start()
        XCTAssertEqual(denied.requestAccessCount, 0)
        XCTAssertTrue(deniedModel.showsCameraPermissionSettingsAction)

        deniedModel.openCameraPrivacySettings()
        XCTAssertEqual(denied.openSettingsCount, 1)
    }

    func testCameraPermissionRequestTimeoutShowsSettingsActionWhenSystemDoesNotReply() async {
        let stalled = FakeCameraPermissionManager(status: .notDetermined, requestResult: nil)
        let model = AppModel(
            cameraPermissionManager: stalled,
            startsVideoInputSetup: true,
            cameraPermissionRequestTimeoutInterval: 0.01
        )

        model.start()

        XCTAssertEqual(stalled.requestAccessCount, 1)
        await waitUntil { model.showsCameraPermissionSettingsAction }
    }

    func testOriginalInputWindowPlanningPreservesTopLeftAndFitsVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let contentSize = WindowResizePlanning.originalInputContentSize(
            inputSize: CGSize(width: 3840, height: 2160),
            backingScaleFactor: 2,
            visibleFrame: visibleFrame,
            topReservedHeight: 32
        )
        XCTAssertEqual(contentSize, CGSize(width: 1920, height: 1112))

        let fullScreenContentSize = WindowResizePlanning.originalInputContentSize(
            inputSize: CGSize(width: 3840, height: 2160),
            backingScaleFactor: 2,
            visibleFrame: visibleFrame,
            topReservedHeight: 0
        )
        XCTAssertEqual(fullScreenContentSize, CGSize(width: 1920, height: 1080))

        let heightConstrained = WindowResizePlanning.originalInputContentSize(
            inputSize: CGSize(width: 3840, height: 2160),
            backingScaleFactor: 2,
            visibleFrame: CGRect(x: 0, y: 0, width: 2000, height: 900),
            topReservedHeight: 32
        )
        XCTAssertEqual(heightConstrained, CGSize(width: 1543, height: 900))

        let frame = WindowResizePlanning.framePreservingTopLeft(
            oldFrame: CGRect(x: 120, y: 240, width: 640, height: 360),
            proposedFrameSize: CGSize(width: 960, height: 540),
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(frame.origin.x, 120)
        XCTAssertEqual(frame.maxY, 600)

        let clamped = WindowResizePlanning.framePreservingTopLeft(
            oldFrame: CGRect(x: 1800, y: 100, width: 200, height: 200),
            proposedFrameSize: CGSize(width: 600, height: 500),
            visibleFrame: visibleFrame
        )
        XCTAssertLessThanOrEqual(clamped.maxX, visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(clamped.minY, visibleFrame.minY)
    }

    func testPreviewHostViewUsesOnlyOneVideoBackend() {
        let view = PreviewHostView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))

        if MTLCreateSystemDefaultDevice() != nil {
            XCTAssertTrue(view.usesMetalBackendForTesting)
            XCTAssertFalse(view.usesPreviewLayerBackendForTesting)
        } else {
            XCTAssertFalse(view.usesMetalBackendForTesting)
            XCTAssertTrue(view.usesPreviewLayerBackendForTesting)
        }
    }

    func testViewMenuControllerBuildsExpectedSectionsAndHasNoImages() {
        let model = AppModel(startsVideoInputSetup: false)
        let controller = ViewMenuController()
        controller.bind(model: model)
        controller.rebuildMenu()

        let items = controller.menu.items
        XCTAssertEqual(items.count, 8)
        XCTAssertEqual(items[0].title, String(localized: "device.none"))
        XCTAssertTrue(items[1].isSeparatorItem)
        XCTAssertEqual(items[2].title, String(localized: "format.device_options"))
        XCTAssertEqual(items[3].title, String(localized: "device.refresh"))
        XCTAssertTrue(items[4].isSeparatorItem)
        XCTAssertEqual(items[5].title, String(localized: "view.original_input"))
        XCTAssertEqual(items[5].state, .off)
        XCTAssertEqual(items[6].title, String(localized: "view.fit_to_window"))
        XCTAssertEqual(items[6].state, .on)
        XCTAssertEqual(items[7].action, #selector(NSWindow.toggleFullScreen(_:)))
        assertNoImages(in: controller.menu)
    }

    func testViewMenuMarksOriginalInputAndFitToWindowModes() {
        let model = AppModel(startsVideoInputSetup: false)
        let controller = ViewMenuController()
        controller.bind(model: model)

        controller.rebuildMenu()
        XCTAssertEqual(controller.menu.items[5].state, .off)
        XCTAssertEqual(controller.menu.items[6].state, .on)

        model.updateActualVideoFrame(CaptureFrameDescriptor(
            dimensions: VideoDimensions(width: 3840, height: 2160),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ))
        model.showOriginalInput()
        controller.rebuildMenu()
        XCTAssertEqual(controller.menu.items[5].state, .on)
        XCTAssertEqual(controller.menu.items[6].state, .off)

        model.fitToWindow()
        controller.rebuildMenu()
        XCTAssertEqual(controller.menu.items[5].state, .off)
        XCTAssertEqual(controller.menu.items[6].state, .on)
    }

    func testUSBMenuDetailsUseDevicePathOrDeviceID() {
        let device = makeDevice(id: "device-usb", host: "", name: "USB KVM", transport: .usb, usbInterface: "/dev/hidraw0")
        let fallback = makeDevice(id: "device-usb-fallback", host: "", name: "USB KVM", transport: .usb)
        let controller = HIDMIController(
            worker: FakeHIDMIWorker(),
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )

        controller.mergeDiscoveredDevices([device, fallback], seenAt: Date())

        let devicesByID = Dictionary(uniqueKeysWithValues: controller.discoveredDevices.map { ($0.id, $0) })
        XCTAssertEqual(devicesByID["device-usb"]?.menuDetails().map(\.kind), [.transport, .usbInterface])
        XCTAssertTrue(devicesByID["device-usb"]?.menuDetails().last?.title.contains("/dev/hidraw0") == true)
        XCTAssertTrue(devicesByID["device-usb-fallback"]?.menuDetails().last?.title.contains("device-usb-fallback") == true)
    }

    func testTokenAttemptsPreferredFirstThenOtherKnownTokensAndMenuMarkers() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10")
        let store = FakeTokenStore()
        let right = store.addKnownToken("right-token")
        let wrong = store.addKnownToken("wrong-token")
        store.preferredTokenByDeviceID[device.deviceID] = wrong.id

        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("right-token", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: store,
            tokenPrompt: FakeTokenPrompt()
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)

        XCTAssertEqual(controller.menuDeviceStates.first?.marker, .selected)

        await waitUntil { controller.isConnected }

        let attempts = await worker.connectAttempts()
        XCTAssertEqual(attempts, ["wrong-token", "right-token"])
        XCTAssertEqual(controller.connectedDeviceID, device.discoveryID)
        XCTAssertEqual(controller.menuDeviceStates.first?.marker, .connected)
        XCTAssertEqual(store.successfulUses, [right.id: device.deviceID])
    }

    func testTokenCandidateReadFailureFallsBackToManualTokenPrompt() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10")
        let store = FakeTokenStore()
        store.addKnownToken("right-token")
        store.candidatesError = HIDMITokenStoreError.storage("read failed")
        let prompt = FakeTokenPrompt(result: HIDMITokenPromptResult(token: "manual-token", remember: true))
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("manual-token", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: store,
            tokenPrompt: prompt
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        let attempts = await worker.connectAttempts()
        XCTAssertEqual(prompt.requestedDeviceIDs, [device.discoveryID])
        XCTAssertEqual(attempts, ["manual-token"])
        XCTAssertEqual(store.savedTokenValues, ["manual-token"])
    }

    func testRequiresAuthWithoutCandidatesPromptsWithoutEmptyTokenAttempt() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: true)
        let prompt = FakeTokenPrompt(result: HIDMITokenPromptResult(token: "manual-token", remember: false))
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("manual-token", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: prompt
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        let attempts = await worker.connectAttempts()
        XCTAssertEqual(attempts, ["manual-token"])
        XCTAssertEqual(prompt.requestedDeviceIDs, [device.discoveryID])
    }

    func testDeviceThatDoesNotRequireAuthTriesEmptyTokenBeforePrompting() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let prompt = FakeTokenPrompt(result: HIDMITokenPromptResult(token: "manual-token", remember: false))
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: prompt
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        let attempts = await worker.connectAttempts()
        XCTAssertEqual(attempts, [""])
        XCTAssertTrue(prompt.requestedDeviceIDs.isEmpty)
    }

    func testAppModelConnectsWithSavedTokensWithoutAuthenticating() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10")
        let store = FakeTokenStore()
        let token = store.addKnownToken("right-token")
        let authenticator = FakeAuthenticator(result: HIDMIAuthenticationContext(context: LAContext()))
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("right-token", device: device)
        let hidmi = HIDMIController(
            worker: worker,
            tokenStore: store,
            tokenPrompt: FakeTokenPrompt()
        )
        let model = AppModel(
            tokenStore: store,
            authenticator: authenticator,
            hidmi: hidmi,
            startsVideoInputSetup: false
        )

        model.start()

        model.hidmi.mergeDiscoveredDevices([device], seenAt: Date())
        model.connectHIDMI(device.discoveryID)
        await waitUntil { model.hidmi.isConnected }

        XCTAssertTrue(authenticator.reasons.isEmpty)
        XCTAssertEqual(store.unlockSavedTokensCount, 0)
        XCTAssertEqual(store.successfulUses, [token.id: device.deviceID])
    }

    func testAppModelConnectionWithNoReadableCandidatesPromptsForManualTokenWithoutAuthenticating() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10")
        let store = FakeTokenStore()
        store.isSessionUnlocked = false
        store.addKnownToken("saved-token")
        let prompt = FakeTokenPrompt(result: HIDMITokenPromptResult(token: "manual-token", remember: true))
        let authenticator = FakeAuthenticator(result: nil)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("manual-token", device: device)
        let hidmi = HIDMIController(
            worker: worker,
            tokenStore: store,
            tokenPrompt: prompt
        )
        let model = AppModel(
            tokenStore: store,
            authenticator: authenticator,
            hidmi: hidmi,
            startsVideoInputSetup: false
        )

        model.start()

        model.hidmi.mergeDiscoveredDevices([device], seenAt: Date())
        model.connectHIDMI(device.discoveryID)
        await waitUntil { model.hidmi.isConnected }

        let attempts = await worker.connectAttempts()
        XCTAssertTrue(authenticator.reasons.isEmpty)
        XCTAssertEqual(store.unlockSavedTokensCount, 0)
        XCTAssertEqual(prompt.requestedDeviceIDs, [device.discoveryID])
        XCTAssertEqual(attempts, ["manual-token"])
        XCTAssertEqual(store.savedTokenValues, ["manual-token"])
    }

    func testRediscoveryUpdatesDisplayNameWithoutLosingConnectedState() async {
        let first = makeDevice(id: "device-a", host: "192.168.1.10", name: "Rack KVM", requiresAuth: false)
        let renamed = makeDevice(id: "device-a", host: "192.168.1.10", name: "Renamed KVM", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: first)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )

        controller.mergeDiscoveredDevices([first], seenAt: Date())
        controller.connect(to: first.discoveryID)
        await waitUntil { controller.isConnected }
        controller.mergeDiscoveredDevices([renamed], seenAt: Date())

        XCTAssertEqual(controller.connectedDeviceID, first.discoveryID)
        XCTAssertEqual(controller.menuDeviceStates.first?.marker, .connected)
        XCTAssertEqual(controller.menuDeviceStates.first?.device.menuTitle, "Renamed KVM")
    }

    func testPromptTokenIsRequestedAndRememberedAfterKnownTokensFail() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10")
        let store = FakeTokenStore()
        store.addKnownToken("stale-token")

        let prompt = FakeTokenPrompt(result: HIDMITokenPromptResult(token: "fresh-token", remember: true))
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("fresh-token", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: store,
            tokenPrompt: prompt
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        let attempts = await worker.connectAttempts()
        XCTAssertEqual(attempts, ["stale-token", "fresh-token"])
        XCTAssertEqual(prompt.requestedDeviceIDs, [device.discoveryID])
        XCTAssertEqual(store.savedTokenValues, ["fresh-token"])
        XCTAssertEqual(store.successfulUses.values.first, device.deviceID)
    }

    func testCtrlAltDelUsesKeyboardWriter() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }
        controller.sendCtrlAltDel()
        await waitUntil { await worker.ctrlAltDelCount() == 1 }

        let ctrlAltDelCount = await worker.ctrlAltDelCount()
        XCTAssertEqual(ctrlAltDelCount, 1)
        let workerCtrlAltDelCalls = await worker.workerCtrlAltDelCallCount()
        XCTAssertEqual(workerCtrlAltDelCalls, 0)
    }

    func testCtrlAltDelPreservesKeyboardWriterOrder() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        await worker.setSendReportsDelay(0.02)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }
        controller.sendReports([.keyboard(modifiers: 0, keys: [4])])
        controller.sendCtrlAltDel()

        await waitUntil { await worker.ctrlAltDelCount() == 1 }
        let events = await worker.keyboardEventsSnapshot()
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0].hasPrefix("keyboard:"))
        XCTAssertEqual(events[1], "ctrl_alt_del")
    }

    func testKeepaliveFailureClearsConnectionAndNotifiesOwner() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        await worker.setPingError(HIDMIClientError.message("Socket closed"))
        let warnings = FakeConnectionWarningPresenter()
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(),
            warningPresenter: warnings,
            keepaliveInterval: 0.01,
            reconnectDelays: []
        )
        var lostCount = 0
        controller.onConnectionLost = {
            lostCount += 1
        }

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }
        await waitUntil {
            if case .failed = controller.status {
                return true
            }
            return false
        }

        XCTAssertFalse(controller.isConnected)
        XCTAssertEqual(lostCount, 1)
        XCTAssertEqual(warnings.lostWarnings.count, 1)
        XCTAssertTrue(warnings.failureWarnings.isEmpty)
    }

    func testSingleKeepaliveTimeoutDoesNotDisconnectOrWarn() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        await worker.setPingFailures([HIDMIClientError.posix("read", EAGAIN)])
        let warnings = FakeConnectionWarningPresenter()
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(),
            warningPresenter: warnings,
            keepaliveInterval: 0.01,
            reconnectDelays: []
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }
        await waitUntil { await worker.pingCallCount() >= 1 }

        XCTAssertTrue(controller.isConnected)
        XCTAssertTrue(warnings.lostWarnings.isEmpty)
        XCTAssertTrue(warnings.failureWarnings.isEmpty)
    }

    func testRepeatedKeepaliveTimeoutConfirmsDisconnectOnce() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        await worker.setPingFailures([
            HIDMIClientError.posix("read", EAGAIN),
            HIDMIClientError.posix("read", EAGAIN),
            HIDMIClientError.posix("read", EAGAIN)
        ])
        let warnings = FakeConnectionWarningPresenter()
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(),
            warningPresenter: warnings,
            keepaliveInterval: 0.01,
            reconnectDelays: []
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }
        await waitUntil {
            if case .failed = controller.status {
                return true
            }
            return false
        }

        XCTAssertFalse(controller.isConnected)
        XCTAssertEqual(warnings.lostWarnings.count, 1)
        XCTAssertTrue(warnings.failureWarnings.isEmpty)
    }

    func testAutomaticReconnectUsesCachedTokenWithoutPrompt() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: true)
        let tokenID = UUID()
        let token = HIDMITokenMetadata(id: tokenID, preview: "cached", createdAt: Date(), lastUsedAt: nil)
        let store = FakeTokenStore()
        store.records = [token]
        store.tokenValuesByID[tokenID] = "cached-token"
        let prompt = FakeTokenPrompt(result: HIDMITokenPromptResult(token: "manual-token", remember: true))
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("cached-token", device: device)
        await worker.setPingFailures([HIDMIClientError.message(String(localized: "error.socket_closed"))])
        let warnings = FakeConnectionWarningPresenter()
        let controller = HIDMIController(
            worker: worker,
            tokenStore: store,
            tokenPrompt: prompt,
            warningPresenter: warnings,
            keepaliveInterval: 0.01,
            reconnectDelays: [0.01]
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }
        await waitUntil { await worker.connectAttempts().count >= 2 }
        await waitUntil { controller.isConnected }

        let attempts = await worker.connectAttempts()
        XCTAssertEqual(attempts, ["cached-token", "cached-token"])
        XCTAssertTrue(prompt.requestedDeviceIDs.isEmpty)
        XCTAssertEqual(warnings.lostWarnings.count, 1)
        XCTAssertTrue(warnings.failureWarnings.isEmpty)
    }

    func testConnectionFailurePresentsWarningAndKeepsFailedState() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setConnectError(HIDMIClientError.message("connection refused"))
        let warnings = FakeConnectionWarningPresenter()
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(),
            warningPresenter: warnings
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)

        await waitUntil {
            if case .failed = controller.status {
                return true
            }
            return false
        }

        XCTAssertFalse(controller.isConnected)
        XCTAssertEqual(warnings.failureWarnings.count, 1)
        XCTAssertEqual(warnings.failureWarnings.first?.deviceID, device.discoveryID)
        XCTAssertTrue(warnings.lostWarnings.isEmpty)
    }

    func testUnavailableHIDDeviceDoesNotAttemptConnectionAndWarns() async {
        let device = makeDevice(
            id: "device-a",
            host: "192.168.1.10",
            requiresAuth: false,
            capabilities: [],
            availability: .hidUnavailable
        )
        let worker = FakeHIDMIWorker()
        let warnings = FakeConnectionWarningPresenter()
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(),
            warningPresenter: warnings
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)

        XCTAssertFalse(controller.isConnected)
        let attempts = await worker.connectAttempts()
        XCTAssertEqual(attempts, [])
        XCTAssertEqual(warnings.failureWarnings.count, 1)
        XCTAssertTrue(warnings.failureWarnings.first?.message.contains(String(localized: "error.hid_unavailable")) == true)
    }

    func testBusyDeviceDoesNotAttemptConnectionOrWarn() async {
        let device = makeDevice(
            id: "device-a",
            host: "192.168.1.10",
            requiresAuth: false,
            availability: .busy
        )
        let worker = FakeHIDMIWorker()
        let warnings = FakeConnectionWarningPresenter()
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(),
            warningPresenter: warnings
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)

        XCTAssertFalse(controller.isConnected)
        let attempts = await worker.connectAttempts()
        XCTAssertEqual(attempts, [])
        XCTAssertTrue(warnings.failureWarnings.isEmpty)
        if case .failed(let message) = controller.status {
            XCTAssertEqual(message, String(localized: "error.server_busy"))
        } else {
            XCTFail("Expected busy device connection to fail locally")
        }
    }

    func testConnectionWarningIsThrottledPerDeviceErrorAndOperation() async {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setConnectError(HIDMIClientError.server(code: "HID_FAILURE", detail: "hid failed"))
        let warnings = FakeConnectionWarningPresenter()
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(),
            warningPresenter: warnings,
            now: { currentDate }
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { warnings.failureWarnings.count == 1 }

        controller.connect(to: device.discoveryID)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(warnings.failureWarnings.count, 1)

        currentDate = currentDate.addingTimeInterval(31)
        controller.connect(to: device.discoveryID)
        await waitUntil { warnings.failureWarnings.count == 2 }
    }

    func testAppTerminationPerformsBoundedBestEffortShutdown() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let hidmi = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        let model = AppModel(
            hidmi: hidmi,
            cameraPermissionManager: FakeCameraPermissionManager(status: .authorized),
            startsVideoInputSetup: false
        )

        hidmi.mergeDiscoveredDevices([device], seenAt: Date())
        model.connectHIDMI(device.discoveryID)
        await waitUntil { hidmi.isConnected }

        let start = Date()
        model.prepareForTermination(timeout: 0.05)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.5)
        await waitUntil { await worker.shutdownBestEffortCallCount() == 1 }
        XCTAssertFalse(hidmi.isConnected)
    }

    func testTokenPromptCancellationDoesNotPresentConnectionWarning() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: true)
        let warnings = FakeConnectionWarningPresenter()
        let controller = HIDMIController(
            worker: FakeHIDMIWorker(),
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(result: nil),
            warningPresenter: warnings
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil {
            if case .disconnected = controller.status {
                return true
            }
            return false
        }

        XCTAssertTrue(warnings.failureWarnings.isEmpty)
        XCTAssertTrue(warnings.lostWarnings.isEmpty)
    }

    func testServerRestartReconnectFailureWarnsOnceThenAllowsReconnect() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let warnings = FakeConnectionWarningPresenter()
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt(),
            warningPresenter: warnings
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        await worker.setConnectError(HIDMIClientError.message("server restarting"))
        controller.connect(to: device.discoveryID)
        await waitUntil {
            if case .failed = controller.status {
                return true
            }
            return false
        }

        XCTAssertFalse(controller.isConnected)
        XCTAssertEqual(warnings.failureWarnings.count, 1)

        await worker.setConnectError(nil)
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        XCTAssertEqual(controller.connectedDeviceID, device.discoveryID)
        XCTAssertEqual(warnings.failureWarnings.count, 1)
        XCTAssertTrue(warnings.lostWarnings.isEmpty)
    }

    func testInvalidOfferPortThrowsRecoverableError() {
        let offer: [String: Any] = [
            "type": "offer",
            "device_id": "device-a",
            "session_id": "session-a",
            "server_nonce": "nonce-a",
            "tcp_port": 70_000
        ]

        XCTAssertThrowsError(try HIDMIClient.device(
            fromOffer: offer,
            host: "192.168.1.10",
            udpPort: HIDMIClient.defaultUDPPort,
            clientID: "client",
            clientNonce: "client-nonce"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("tcp_port"))
        }
    }

    func testServerHIDErrorsAreNotClassifiedAsProtocolFailures() {
        let details = [
            "HID writer is not available; retrying",
            "HID write timed out",
            "failed to open /dev/hidg0",
            "USB gadget endpoint is unavailable",
            "HID_FAILURE: keyboard special failed"
        ]

        for detail in details {
            for code in ["ERROR", "KEYBOARD_ERROR"] {
                let error = HIDMIClientError.server(code: code, detail: detail)
                XCTAssertEqual(error.connectionFailureKind, .hidFailure)
                XCTAssertEqual(error.userFacingConnectionDescription, String(localized: "error.hid_unavailable"))
            }
        }
    }

    func testProtocolErrorsRemainProtocolFailures() {
        for detail in [
            "frame channel/session mismatch",
            "invalid TCP frame protobuf",
            "unsupported keyboard frame"
        ] {
            let error = HIDMIClientError.server(code: "ERROR", detail: detail)
            XCTAssertEqual(error.connectionFailureKind, .protocolFailure)
            XCTAssertEqual(error.userFacingConnectionDescription, String(localized: "error.protocol_failure"))
        }

        let oversized = HIDMIClientError.message(String(localized: "error.response_too_large"))
        XCTAssertEqual(oversized.connectionFailureKind, .protocolFailure)
    }

    func testAuthRateLimitedErrorUsesSpecificUserFacingMessage() {
        let error = HIDMIClientError.server(code: "AUTH_RATE_LIMITED", detail: String(localized: "error.auth_rate_limited"))
        XCTAssertFalse(error.isAuthenticationFailure)
        XCTAssertEqual(error.userFacingConnectionDescription, String(localized: "error.auth_rate_limited"))
    }

    func testOfferCallbackMatchingIgnoresStaleDatagrams() throws {
        func packetData(body: (inout Hidmi_Kvm_Input_V1_UdpPacket) -> Void) throws -> Data {
            var packet = Hidmi_Kvm_Input_V1_UdpPacket()
            packet.protocolVersion = HIDMIClient.proto
            body(&packet)
            return try packet.serializedData()
        }

        let valid = try packetData { packet in
            packet.offerCallback = Hidmi_Kvm_Input_V1_OfferCallback.with {
                $0.serverID = 123
                $0.bootID = 456
                $0.accept = true
                $0.sessionID = 789
                $0.connectDeadlineMs = 5_000
            }
        }
        let wrongServer = try packetData { packet in
            packet.offerCallback = Hidmi_Kvm_Input_V1_OfferCallback.with {
                $0.serverID = 321
                $0.bootID = 456
                $0.accept = true
            }
        }
        let wrongBoot = try packetData { packet in
            packet.offerCallback = Hidmi_Kvm_Input_V1_OfferCallback.with {
                $0.serverID = 123
                $0.bootID = 654
                $0.accept = true
            }
        }
        let discover = try packetData { packet in
            packet.discover = Hidmi_Kvm_Input_V1_Discover.with {
                $0.serverID = 123
                $0.bootID = 456
            }
        }
        var wrongProtocolPacket = Hidmi_Kvm_Input_V1_UdpPacket()
        wrongProtocolPacket.protocolVersion = HIDMIClient.proto + 1
        wrongProtocolPacket.offerCallback = Hidmi_Kvm_Input_V1_OfferCallback.with {
            $0.serverID = 123
            $0.bootID = 456
            $0.accept = true
        }
        let wrongProtocol = try wrongProtocolPacket.serializedData()

        XCTAssertNil(HIDMIClient.matchingOfferCallback(from: Data([0xff]), expectedServerID: 123, expectedBootID: 456))
        XCTAssertNil(HIDMIClient.matchingOfferCallback(from: wrongServer, expectedServerID: 123, expectedBootID: 456))
        XCTAssertNil(HIDMIClient.matchingOfferCallback(from: wrongBoot, expectedServerID: 123, expectedBootID: 456))
        XCTAssertNil(HIDMIClient.matchingOfferCallback(from: discover, expectedServerID: 123, expectedBootID: 456))
        XCTAssertNil(HIDMIClient.matchingOfferCallback(from: wrongProtocol, expectedServerID: 123, expectedBootID: 456))

        let callback = try XCTUnwrap(HIDMIClient.matchingOfferCallback(from: valid, expectedServerID: 123, expectedBootID: 456))
        XCTAssertTrue(callback.accept)
        XCTAssertEqual(callback.sessionID, 789)
        XCTAssertEqual(HIDMIClient.offerCallbackRejectionReason(from: Data([0xff]), expectedServerID: 123, expectedBootID: 456), "invalid_protobuf")
        XCTAssertEqual(HIDMIClient.offerCallbackRejectionReason(from: wrongServer, expectedServerID: 123, expectedBootID: 456), "server_id")
        XCTAssertEqual(HIDMIClient.offerCallbackRejectionReason(from: wrongBoot, expectedServerID: 123, expectedBootID: 456), "boot_id")
        XCTAssertEqual(HIDMIClient.offerCallbackRejectionReason(from: discover, expectedServerID: 123, expectedBootID: 456), "discover")
        XCTAssertEqual(HIDMIClient.offerCallbackRejectionReason(from: wrongProtocol, expectedServerID: 123, expectedBootID: 456), "protocol_version")
    }

    func testHIDUnavailableOfferIsDiscoverableButNotConnectable() throws {
        let offer: [String: Any] = [
            "type": "offer",
            "status": "hid_unavailable",
            "code": "HID_UNAVAILABLE",
            "device_id": "device-a",
            "device_name": "Rack KVM",
            "session_id": "session-a",
            "server_nonce": "nonce-a",
            "tcp_port": 12_345,
            "capabilities": ["keyboard", "mouse", "absolute_pointer"]
        ]

        let device = try HIDMIClient.device(
            fromOffer: offer,
            host: "192.168.1.10",
            udpPort: HIDMIClient.defaultUDPPort,
            clientID: "client",
            clientNonce: "client-nonce"
        )

        XCTAssertEqual(device.availability, .hidUnavailable)
        XCTAssertTrue(device.capabilities.isEmpty)
        XCTAssertFalse(device.supportsAbsolutePointer)
        XCTAssertThrowsError(try HIDMIClient.connect(device: device, token: "", timeout: 0.01, establishedIOTimeout: 0.01)) { error in
            XCTAssertEqual((error as? HIDMIClientError)?.connectionFailureKind, .hidFailure)
        }
    }

    func testDiscoverParsesBusyAndHIDMetadata() throws {
        let discover = Hidmi_Kvm_Input_V1_Discover.with {
            $0.serverID = 123
            $0.bootID = 456
            $0.serverName = "Rack KVM"
            $0.tcpAcceptMin = 10_000
            $0.tcpAcceptMax = 60_999
            $0.challengeNonce = Data(repeating: 7, count: 16)
            $0.isBusy = true
            $0.hidStatus = .ready
            $0.hidAvailable = true
            $0.absolutePointerAvailable = false
            $0.relativePointerAvailable = true
            $0.capabilities = ["keyboard", "mouse", "release_all", "relative_pointer"]
        }

        let device = try HIDMIClient.device(
            fromDiscover: discover,
            host: "192.168.1.10",
            udpPort: HIDMIClient.defaultUDPPort,
            client: ClientIdentity(id: 42, nonce: Data(repeating: 1, count: 16))
        )

        XCTAssertEqual(device.availability, .busy)
        XCTAssertFalse(device.availability.isConnectable)
        XCTAssertFalse(device.supportsAbsolutePointer)
        XCTAssertEqual(device.capabilities, Set(["keyboard", "mouse", "release_all", "relative_pointer"]))
    }

    func testDiscoverParsesHIDUnavailableMetadata() throws {
        let discover = Hidmi_Kvm_Input_V1_Discover.with {
            $0.serverID = 123
            $0.bootID = 456
            $0.serverName = "Rack KVM"
            $0.tcpAcceptMin = 10_000
            $0.tcpAcceptMax = 60_999
            $0.challengeNonce = Data(repeating: 7, count: 16)
            $0.hidStatus = .deviceUnavailable
            $0.hidAvailable = false
        }

        let device = try HIDMIClient.device(
            fromDiscover: discover,
            host: "192.168.1.10",
            udpPort: HIDMIClient.defaultUDPPort,
            client: ClientIdentity(id: 42, nonce: Data(repeating: 1, count: 16))
        )

        XCTAssertEqual(device.availability, .hidUnavailable)
        XCTAssertFalse(device.availability.isConnectable)
        XCTAssertTrue(device.capabilities.isEmpty)
    }

    func testDiscoverParsesWLANInterfaceType() throws {
        let discover = Hidmi_Kvm_Input_V1_Discover.with {
            $0.serverID = 123
            $0.bootID = 456
            $0.serverName = "Rack KVM"
            $0.interfaceType = .ifaceWlan
            $0.tcpAcceptMin = 10_000
            $0.tcpAcceptMax = 60_999
            $0.challengeNonce = Data(repeating: 7, count: 16)
            $0.hidStatus = .ready
            $0.hidAvailable = true
            $0.relativePointerAvailable = true
            $0.capabilities = ["keyboard", "mouse", "release_all", "relative_pointer"]
        }

        let device = try HIDMIClient.device(
            fromDiscover: discover,
            host: "192.168.1.10",
            udpPort: HIDMIClient.defaultUDPPort,
            client: ClientIdentity(id: 42, nonce: Data(repeating: 1, count: 16))
        )

        XCTAssertEqual(device.transport, .wlan)
        XCTAssertEqual(HIDMIDiscoveredDevice(device: device, lastSeen: Date()).menuDetails().first?.title, String(localized: "hid.device.wlan_device"))
    }

    func testMultipleInterfaceDiscoversMergeByDiscoveryID() {
        let controller = HIDMIController(
            worker: FakeHIDMIWorker(),
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )
        let ethernet = makeDevice(id: "device-a", host: "192.168.1.10", transport: .ethernet)
        let wlan = makeDevice(id: "device-a", host: "192.168.1.11", transport: .wlan)

        controller.mergeDiscoveredDevices([ethernet, wlan], seenAt: Date())

        XCTAssertEqual(controller.discoveredDevices.count, 1)
        XCTAssertEqual(controller.discoveredDevices.first?.id, "device-a")
    }

    func testInvalidSessionPortThrowsRecoverableError() {
        XCTAssertThrowsError(try HIDMISession(host: "127.0.0.1", port: 70_000, timeout: 0.01)) { error in
            XCTAssertTrue(error.localizedDescription.contains("port"))
        }
    }

    func testAbsolutePointerIsEnabledWhenCapabilityIsPresent() async {
        let device = makeDevice(id: "device-a", host: "192.168.1.10", requiresAuth: false)
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        XCTAssertTrue(controller.usesAbsolutePointer)
    }

    func testAbsolutePointerIsDisabledWhenCapabilityIsMissing() async {
        let device = makeDevice(
            id: "device-a",
            host: "192.168.1.10",
            requiresAuth: false,
            capabilities: ["keyboard", "mouse", "release_all"]
        )
        let worker = FakeHIDMIWorker()
        await worker.setAcceptedToken("", device: device)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: FakeTokenStore(),
            tokenPrompt: FakeTokenPrompt()
        )

        controller.mergeDiscoveredDevices([device], seenAt: Date())
        controller.connect(to: device.discoveryID)
        await waitUntil { controller.isConnected }

        XCTAssertFalse(controller.usesAbsolutePointer)
    }

    func testSwitchingDevicesBlocksInputUntilNewDeviceIsConnected() async {
        let first = makeDevice(id: "device-a", host: "192.168.1.10", name: "First KVM")
        let second = makeDevice(id: "device-b", host: "192.168.1.11", name: "Second KVM")
        let store = FakeTokenStore()
        store.addKnownToken("shared-token")
        let worker = VirtualSwitchingHIDMIServerWorker(acceptedToken: "shared-token")
        await worker.addDevice(first)
        await worker.addDevice(second)
        let controller = HIDMIController(
            worker: worker,
            tokenStore: store,
            tokenPrompt: FakeTokenPrompt()
        )

        controller.mergeDiscoveredDevices([first, second], seenAt: Date())
        controller.connect(to: first.discoveryID)
        await waitUntil { controller.connectedDeviceID == first.discoveryID }

        controller.sendReports([.keyboard(modifiers: 0, keys: [4])])
        await waitUntil { await worker.reportCountsByDeviceID()["device-a"] == 1 }

        await worker.setConnectDelay(0.2)
        controller.connect(to: second.discoveryID)

        XCTAssertNil(controller.connectedDeviceID)
        XCTAssertFalse(controller.isConnected)

        controller.sendReports([.keyboard(modifiers: 0, keys: [5])])
        try? await Task.sleep(for: .milliseconds(50))
        let countsDuringSwitch = await worker.reportCountsByDeviceID()
        XCTAssertEqual(countsDuringSwitch, ["device-a": 1])

        await waitUntil { controller.connectedDeviceID == second.discoveryID }
        controller.sendReports([.keyboard(modifiers: 0, keys: [6])])
        await waitUntil { await worker.reportCountsByDeviceID()["device-b"] == 1 }

        let finalCounts = await worker.reportCountsByDeviceID()
        XCTAssertEqual(finalCounts, ["device-a": 1, "device-b": 1])
    }

    func testTokenManagementModelAddsAndDeletesSelectedToken() {
        let store = FakeTokenStore()
        let model = TokenManagementModel(tokenStore: store)

        XCTAssertTrue(model.addToken("abc123"))
        XCTAssertEqual(model.tokens.count, 1)
        XCTAssertEqual(store.savedTokenValues, ["abc123"])
        XCTAssertEqual(model.tokens.first.map { model.displayValue(for: $0) }, "abc123")

        model.selectedTokenID = model.tokens.first?.id
        model.deleteSelectedToken()

        XCTAssertTrue(model.tokens.isEmpty)
        XCTAssertTrue(store.deletedTokenIDs.count == 1)
    }

    func testTokenManagementModelShowsReadFailureInsteadOfMaskedSecret() {
        let store = FakeTokenStore()
        store.isSessionUnlocked = false
        let token = store.addKnownToken("abc123")
        let model = TokenManagementModel(tokenStore: store)

        XCTAssertTrue(model.displayValue(for: token).contains(token.preview))
        XCTAssertTrue(model.displayValue(for: token).contains(String(localized: "token.value.unavailable.prefix")))
    }

    func testTokenManagementLastUsedSummaryUsesHoursAndDaysOnly() {
        let model = TokenManagementModel(tokenStore: FakeTokenStore())
        let now = Date(timeIntervalSince1970: 10 * 24 * 60 * 60)

        XCTAssertEqual(
            model.lastUsedSummary(for: now.addingTimeInterval(-30 * 60), now: now),
            String(localized: "token.age.less_than_hour")
        )
        XCTAssertEqual(
            model.lastUsedSummary(for: now.addingTimeInterval(-5 * 60 * 60), now: now),
            String.localizedStringWithFormat(String(localized: "token.age.hours"), 5)
        )
        XCTAssertEqual(
            model.lastUsedSummary(for: now.addingTimeInterval(-26 * 60 * 60), now: now),
            String.localizedStringWithFormat(String(localized: "token.age.day"), 1)
        )
        XCTAssertEqual(
            model.lastUsedSummary(for: now.addingTimeInterval(-3 * 24 * 60 * 60), now: now),
            String.localizedStringWithFormat(String(localized: "token.age.days"), 3)
        )
    }

    func testLocalTokenStorePersistsTokensWithoutSessionUnlock() throws {
        let suiteName = "HIDMITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HIDMITokenStore-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("tokens.json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let firstStore = LocalHIDMITokenStore(defaults: defaults, storeURL: storeURL)
        let token = try firstStore.saveToken("  local-token  ")

        XCTAssertTrue(firstStore.isSessionUnlocked)
        XCTAssertEqual(try firstStore.candidates(preferredForDeviceID: nil).map(\.value), ["local-token"])

        let secondStore = LocalHIDMITokenStore(defaults: defaults, storeURL: storeURL)
        XCTAssertTrue(secondStore.isSessionUnlocked)
        XCTAssertEqual(try secondStore.tokenValue(id: token.id), "local-token")

        let attributes = try FileManager.default.attributesOfItem(atPath: storeURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(permissions, 0o600)
    }

    func testTokenPromptStateDisablesEmptyTokensAndTrimsConfirmedToken() {
        var state = HIDMITokenPromptState(token: "   ", remember: true)
        XCTAssertFalse(state.canConfirm)
        XCTAssertNil(state.confirmedResult())

        state.token = "  manual-token  "

        XCTAssertTrue(state.canConfirm)
        XCTAssertEqual(
            state.confirmedResult(),
            HIDMITokenPromptResult(token: "manual-token", remember: true)
        )
    }

    func testTokenPromptStateReturnsRememberSelection() {
        let remembered = HIDMITokenPromptState(token: "manual-token", remember: true)
        let temporary = HIDMITokenPromptState(token: "manual-token", remember: false)

        XCTAssertEqual(remembered.confirmedResult()?.remember, true)
        XCTAssertEqual(temporary.confirmedResult()?.remember, false)
    }

    func testTokenPromptContentUsesDisplayNameAndAddressFallback() {
        let named = HIDMIDiscoveredDevice(
            device: makeDevice(id: "device-a", host: "192.168.1.10", name: "Rack KVM"),
            lastSeen: Date()
        )
        let fallback = HIDMIDiscoveredDevice(
            device: makeDevice(id: "device-b", host: "", name: "", transport: .usb),
            lastSeen: Date()
        )

        let namedContent = HIDMITokenPromptContent(device: named)
        let fallbackContent = HIDMITokenPromptContent(device: fallback)

        XCTAssertTrue(namedContent.message.contains("Rack KVM"))
        XCTAssertTrue(namedContent.message.contains("192.168.1.10"))
        XCTAssertTrue(fallbackContent.message.contains("device-b"))
    }

    func testTokenPromptUsesGlassContainerAndVerticalFullWidthButtonRow() {
        let device = HIDMIDiscoveredDevice(
            device: makeDevice(id: "device-a", host: "192.168.1.10", name: "Rack KVM"),
            lastSeen: Date()
        )
        let controller = HIDMITokenPromptViewController(content: HIDMITokenPromptContent(device: device))

        XCTAssertTrue(controller.view is NSGlassEffectView)
        XCTAssertEqual(controller.buttonRow.orientation, .vertical)
        XCTAssertEqual(controller.buttonRow.alignment, .leading)
        XCTAssertEqual(controller.buttonRow.distribution, .fillEqually)
        XCTAssertTrue(controller.buttonRow.views.first === controller.confirmButton)
        XCTAssertTrue(controller.buttonRow.views.contains(controller.confirmButton))

        let rowButtons = controller.buttonRow.views.compactMap { $0 as? NSButton }
        XCTAssertEqual(rowButtons.count, 2)
        XCTAssertTrue(rowButtons.allSatisfy { $0.bezelStyle == .glass })
    }

    func testUITestingFactoryUsesFakeDiscoveryAndTokenStore() async {
        let previousUITesting = getenv("HIDMI_UI_TESTING").map { String(cString: $0) }
        let previousToken = getenv("HIDMI_UI_TEST_TOKEN").map { String(cString: $0) }
        setenv("HIDMI_UI_TESTING", "1", 1)
        setenv("HIDMI_UI_TEST_TOKEN", "factory-token", 1)
        defer {
            restoreEnvironment("HIDMI_UI_TESTING", previousUITesting)
            restoreEnvironment("HIDMI_UI_TEST_TOKEN", previousToken)
        }

        let model = AppModel.makeForCurrentEnvironment()
        model.start()
        model.startHIDMIDiscovery()
        await waitUntil { !model.hidmi.discoveredDevices.isEmpty }

        XCTAssertEqual(model.hidmi.discoveredDevices.first?.host, "192.0.2.10")

        guard let deviceID = model.hidmi.discoveredDevices.first?.id else {
            XCTFail("Expected fake HIDMI device")
            return
        }
        model.connectHIDMI(deviceID)
        await waitUntil { model.hidmi.isConnected }

        XCTAssertEqual(model.hidmi.connectedDeviceID, deviceID)
        XCTAssertTrue(model.hidmi.usesAbsolutePointer)
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<100 {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeKeyEvent(
        characters: String = "a",
        keyCode: UInt16 = 0
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func makeMouseEvent(type: NSEvent.EventType = .mouseMoved) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
    }

    private func makeMouseMovedEvent(deltaX: Int64, deltaY: Int64) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ))
        event.setIntegerValueField(.mouseEventDeltaX, value: deltaX)
        event.setIntegerValueField(.mouseEventDeltaY, value: deltaY)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func restoreEnvironment(_ name: String, _ previous: String?) {
        if let previous {
            setenv(name, previous, 1)
        } else {
            unsetenv(name)
        }
    }

    private func assertNoImages(in menu: NSMenu, file: StaticString = #filePath, line: UInt = #line) {
        for item in menu.items {
            XCTAssertNil(item.image, "Unexpected image on menu item \(item.title)", file: file, line: line)
            if let submenu = item.submenu {
                assertNoImages(in: submenu, file: file, line: line)
            }
        }
    }
}

private func makeDevice(
    id: String,
    host: String,
    name: String = "HIDMI KVM",
    transport: HIDMIDeviceTransport = .ethernet,
    usbInterface: String? = nil,
    requiresAuth: Bool = true,
    capabilities: Set<String> = ["keyboard", "mouse", "release_all", "absolute_pointer"],
    availability: HIDMIDeviceAvailability = .ready
) -> HIDMIDevice {
    HIDMIDevice(
        host: host,
        udpPort: HIDMIClient.defaultUDPPort,
        tcpPort: 12_345,
        deviceID: id,
        deviceName: name,
        sessionID: "session-\(id)",
        serverNonce: "server-\(id)",
        clientID: "client",
        clientNonce: "client-nonce",
        requiresAuth: requiresAuth,
        capabilities: capabilities,
        availability: availability,
        transport: transport,
        usbInterface: usbInterface
    )
}

private func makeCaptureFormat(
    id: String,
    width: Int32,
    height: Int32,
    maxFrameRate: Double,
    mediaSubType: FourCharCode
) -> CaptureFormat {
    CaptureFormat(
        id: id,
        index: 0,
        dimensions: VideoDimensions(width: width, height: height),
        maxFrameRate: maxFrameRate,
        mediaSubType: mediaSubType
    )
}

private func fourCC(_ value: String) -> FourCharCode {
    let bytes = Array(value.utf8.prefix(4))
    return bytes.reduce(FourCharCode(0)) { result, byte in
        (result << 8) | FourCharCode(byte)
    }
}

private final class FakeCameraPermissionManager: CameraPermissionManaging {
    private let statusValue: CameraPermissionStatus
    private let requestResult: Bool?
    private(set) var requestAccessCount = 0
    private(set) var openSettingsCount = 0

    init(status: CameraPermissionStatus, requestResult: Bool? = true) {
        self.statusValue = status
        self.requestResult = requestResult
    }

    func authorizationStatus() -> CameraPermissionStatus {
        statusValue
    }

    func requestAccess(completion: @escaping @Sendable (Bool) -> Void) {
        requestAccessCount += 1
        guard let requestResult else { return }
        completion(requestResult)
    }

    func openCameraPrivacySettings() {
        openSettingsCount += 1
    }
}

private final class FakeHIDMIReportSink: @unchecked Sendable {
    private let lock = NSLock()
    private var reports = [RemoteInputReport]()
    private var sampledReports = [HIDMISampledInputReport]()
    private var callCount = 0
    private var delay: TimeInterval = 0
    private var failure: Error?

    func setDelay(_ delay: TimeInterval) {
        lock.lock()
        self.delay = delay
        lock.unlock()
    }

    func setFailure(_ failure: Error?) {
        lock.lock()
        self.failure = failure
        lock.unlock()
    }

    func reportCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return reports.count
    }

    func sendCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func snapshot() -> [RemoteInputReport] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }

    func sampledSnapshot() -> [HIDMISampledInputReport] {
        lock.lock()
        defer { lock.unlock() }
        return sampledReports
    }

    private func behavior() -> (delay: TimeInterval, failure: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (delay, failure)
    }

    private func record(_ sampledReports: [HIDMISampledInputReport]) {
        lock.lock()
        callCount += 1
        self.sampledReports.append(contentsOf: sampledReports)
        reports.append(contentsOf: sampledReports.map(\.report))
        lock.unlock()
    }

    func appendSync(_ sampledReports: [HIDMISampledInputReport]) throws {
        let current = behavior()
        if current.delay > 0 {
            Thread.sleep(forTimeInterval: current.delay)
        }
        if let currentFailure = current.failure {
            throw currentFailure
        }
        record(sampledReports)
    }

    func appendAsync(_ sampledReports: [HIDMISampledInputReport]) async throws {
        let current = behavior()
        if current.delay > 0 {
            try? await Task.sleep(for: .seconds(current.delay))
        }
        if let currentFailure = current.failure {
            throw currentFailure
        }
        record(sampledReports)
    }
}

private final class FakeHIDMIMouseReportWriter: HIDMIMouseReportWriting, @unchecked Sendable {
    private let sink: FakeHIDMIReportSink
    private let queue = DispatchQueue(label: "FakeHIDMIMouseReportWriter")

    init(sink: FakeHIDMIReportSink) {
        self.sink = sink
    }

    func enqueueMouseReports(
        _ reports: [HIDMISampledInputReport],
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        queue.async { [sink] in
            do {
                try sink.appendSync(reports)
                completion(.success(reports.count))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

private final class FakeHIDMIKeyboardReportWriter: HIDMIKeyboardReportWriting, @unchecked Sendable {
    private let sink: FakeHIDMIReportSink
    private let queue = DispatchQueue(label: "FakeHIDMIKeyboardReportWriter")
    private let lock = NSLock()
    private var ctrlAltDelCalls = 0
    private var events = [String]()

    init(sink: FakeHIDMIReportSink) {
        self.sink = sink
    }

    func enqueueKeyboardReports(
        _ reports: [HIDMISampledInputReport],
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        queue.async { [sink] in
            do {
                try sink.appendSync(reports)
                self.recordEvents(reports.map { "keyboard:\($0.report)" })
                completion(.success(reports.count))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func enqueueCtrlAltDel(
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async {
            self.lock.lock()
            self.ctrlAltDelCalls += 1
            self.events.append("ctrl_alt_del")
            self.lock.unlock()
            completion(.success(()))
        }
    }

    func ctrlAltDelCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return ctrlAltDelCalls
    }

    func eventsSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    private func recordEvents(_ events: [String]) {
        lock.lock()
        self.events.append(contentsOf: events)
        lock.unlock()
    }
}

private actor FakeHIDMIWorker: HIDMIWorkerProtocol {
    private let reportSink = FakeHIDMIReportSink()
    private lazy var keyboardWriter = FakeHIDMIKeyboardReportWriter(sink: reportSink)
    private var acceptedTokens = [String: HIDMIDevice]()
    private var attempts = [String]()
    private var workerCtrlAltDelCalls = 0
    private var workerSendReportsCalls = 0
    private var pingFailure: Error?
    private var pingFailures = [Error]()
    private var pingCalls = 0
    private var connectFailure: Error?
    private var discoveryError: Error?
    private var discoveryResults = [[HIDMIDevice]]()
    private var discoverBroadcastCalls = 0
    private var releaseAllCalls = 0
    private var bestEffortReleaseAllCalls = 0
    private var shutdownBestEffortCalls = 0
    private var connectionGeneration: UInt64 = 0

    func setAcceptedToken(_ token: String, device: HIDMIDevice) {
        acceptedTokens[token] = device
    }

    func setPingError(_ error: Error) {
        pingFailure = error
    }

    func setPingFailures(_ errors: [Error]) {
        pingFailures = errors
    }

    func setConnectError(_ error: Error?) {
        connectFailure = error
    }

    func setSendReportsDelay(_ delay: TimeInterval) {
        reportSink.setDelay(delay)
    }

    func setSendReportsError(_ error: Error?) {
        reportSink.setFailure(error)
    }

    func setDiscoveryError(_ error: Error?) {
        discoveryError = error
    }

    func setDiscoveryResults(_ results: [[HIDMIDevice]]) {
        discoveryResults = results
    }

    func connectAttempts() -> [String] {
        attempts
    }

    func discoverBroadcastCallCount() -> Int {
        discoverBroadcastCalls
    }

    func ctrlAltDelCount() -> Int {
        workerCtrlAltDelCalls + keyboardWriter.ctrlAltDelCount()
    }

    func workerCtrlAltDelCallCount() -> Int {
        workerCtrlAltDelCalls
    }

    func workerSendReportsCallCount() -> Int {
        workerSendReportsCalls
    }

    func keyboardEventsSnapshot() -> [String] {
        keyboardWriter.eventsSnapshot()
    }

    func pingCallCount() -> Int {
        pingCalls
    }

    func sentReportCount() -> Int {
        reportSink.reportCount()
    }

    func sendReportsCallCount() -> Int {
        reportSink.sendCallCount()
    }

    func releaseAllCallCount() -> Int {
        releaseAllCalls
    }

    func bestEffortReleaseAllCallCount() -> Int {
        bestEffortReleaseAllCalls
    }

    func shutdownBestEffortCallCount() -> Int {
        shutdownBestEffortCalls
    }

    func sentReportsSnapshot() -> [RemoteInputReport] {
        reportSink.snapshot()
    }

    func sampledReportsSnapshot() -> [HIDMISampledInputReport] {
        reportSink.sampledSnapshot()
    }

    func discoverBroadcast(timeout: TimeInterval) async throws -> [HIDMIDevice] {
        discoverBroadcastCalls += 1
        if let discoveryError {
            throw discoveryError
        }
        if !discoveryResults.isEmpty {
            return discoveryResults.removeFirst()
        }
        return []
    }

    func connect(device: HIDMIDevice, token: String, timeout: TimeInterval, establishedIOTimeout: TimeInterval) async throws -> HIDMIWorkerConnection {
        attempts.append(token)
        connectionGeneration &+= 1
        if let connectFailure {
            throw connectFailure
        }
        if let device = acceptedTokens[token] {
            return HIDMIWorkerConnection(
                device: device,
                generation: connectionGeneration,
                mouseWriter: FakeHIDMIMouseReportWriter(sink: reportSink),
                keyboardWriter: keyboardWriter
            )
        }
        throw HIDMIClientError.message("HELLO_REJECTED: authentication failed")
    }

    func disconnect() async {
        connectionGeneration &+= 1
    }

    func releaseAll(generation: UInt64) async throws {
        guard generation == connectionGeneration else { return }
        releaseAllCalls += 1
    }

    func releaseAllBestEffort(generation: UInt64, timeout: TimeInterval) async {
        guard generation == connectionGeneration else { return }
        bestEffortReleaseAllCalls += 1
    }

    func shutdownBestEffort(timeout: TimeInterval) async {
        shutdownBestEffortCalls += 1
        connectionGeneration &+= 1
    }

    func ping(generation: UInt64) async throws {
        guard generation == connectionGeneration else { return }
        pingCalls += 1
        if !pingFailures.isEmpty {
            throw pingFailures.removeFirst()
        }
        if let pingFailure {
            throw pingFailure
        }
    }

    func sendReports(_ reports: [HIDMISampledInputReport], generation: UInt64) async throws {
        guard generation == connectionGeneration else { return }
        workerSendReportsCalls += 1
        try await reportSink.appendAsync(reports)
    }

    func sendCtrlAltDel(generation: UInt64) async throws {
        guard generation == connectionGeneration else { return }
        workerCtrlAltDelCalls += 1
    }
}

private actor VirtualSwitchingHIDMIServerWorker: HIDMIWorkerProtocol {
    private let acceptedToken: String
    private let reportCounter = DeviceReportCounter()
    private var devicesByHost = [String: HIDMIDevice]()
    private var currentDeviceID: String?
    private var connectDelay: TimeInterval = 0
    private var connectionGeneration: UInt64 = 0

    init(acceptedToken: String) {
        self.acceptedToken = acceptedToken
    }

    func addDevice(_ device: HIDMIDevice) {
        devicesByHost[device.host] = device
    }

    func setConnectDelay(_ delay: TimeInterval) {
        connectDelay = delay
    }

    func reportCountsByDeviceID() -> [String: Int] {
        reportCounter.snapshot()
    }

    func discoverBroadcast(timeout: TimeInterval) async throws -> [HIDMIDevice] {
        Array(devicesByHost.values)
    }

    func connect(device: HIDMIDevice, token: String, timeout: TimeInterval, establishedIOTimeout: TimeInterval) async throws -> HIDMIWorkerConnection {
        currentDeviceID = nil
        connectionGeneration &+= 1
        if connectDelay > 0 {
            try? await Task.sleep(for: .seconds(connectDelay))
        }
        guard token == acceptedToken, devicesByHost[device.host] != nil else {
            throw HIDMIClientError.message("HELLO_REJECTED: authentication failed")
        }
        currentDeviceID = device.deviceID
        let writer = DeviceReportCountingWriter(counter: reportCounter, deviceID: device.deviceID)
        return HIDMIWorkerConnection(
            device: device,
            generation: connectionGeneration,
            mouseWriter: writer,
            keyboardWriter: writer
        )
    }

    func disconnect() async {
        currentDeviceID = nil
        connectionGeneration &+= 1
    }

    func releaseAll(generation: UInt64) async throws {}

    func releaseAllBestEffort(generation: UInt64, timeout: TimeInterval) async {}

    func shutdownBestEffort(timeout: TimeInterval) async {
        currentDeviceID = nil
        connectionGeneration &+= 1
    }

    func ping(generation: UInt64) async throws {
        guard generation == connectionGeneration else { return }
        guard currentDeviceID != nil else {
            throw HIDMIClientError.message(String(localized: "error.not_connected"))
        }
    }

    func sendReports(_ reports: [HIDMISampledInputReport], generation: UInt64) async throws {
        guard generation == connectionGeneration else { return }
        guard let currentDeviceID else {
            throw HIDMIClientError.message(String(localized: "error.not_connected"))
        }
        reportCounter.append(deviceID: currentDeviceID, count: reports.count)
    }

    func sendCtrlAltDel(generation: UInt64) async throws {}
}

private final class DeviceReportCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = [String: Int]()

    func append(deviceID: String, count: Int) {
        lock.lock()
        counts[deviceID, default: 0] += count
        lock.unlock()
    }

    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }
}

private final class DeviceReportCountingWriter: HIDMIMouseReportWriting, HIDMIKeyboardReportWriting, @unchecked Sendable {
    private let counter: DeviceReportCounter
    private let deviceID: String
    private let queue = DispatchQueue(label: "DeviceReportCountingWriter")

    init(counter: DeviceReportCounter, deviceID: String) {
        self.counter = counter
        self.deviceID = deviceID
    }

    func enqueueMouseReports(
        _ reports: [HIDMISampledInputReport],
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        enqueue(count: reports.count) {
            completion(.success(reports.count))
        }
    }

    func enqueueKeyboardReports(
        _ reports: [HIDMISampledInputReport],
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        enqueue(count: reports.count) {
            completion(.success(reports.count))
        }
    }

    func enqueueCtrlAltDel(
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async {
            completion(.success(()))
        }
    }

    private func enqueue(count: Int, completion: @escaping @Sendable () -> Void) {
        queue.async { [counter, deviceID] in
            counter.append(deviceID: deviceID, count: count)
            completion()
        }
    }
}

@MainActor
private final class FakeConnectionWarningPresenter: HIDMIConnectionWarningPresenting {
    struct Warning: Equatable {
        let deviceID: String?
        let message: String
    }

    private(set) var failureWarnings = [Warning]()
    private(set) var lostWarnings = [Warning]()

    func showConnectionFailure(device: HIDMIDiscoveredDevice, message: String) {
        failureWarnings.append(Warning(deviceID: device.id, message: message))
    }

    func showConnectionLost(device: HIDMIDiscoveredDevice?, message: String) {
        lostWarnings.append(Warning(deviceID: device?.id, message: message))
    }
}

private final class FakeTokenPrompt: HIDMITokenPrompting {
    var result: HIDMITokenPromptResult?
    var requestedDeviceIDs = [HIDMIDiscoveredDevice.ID]()

    init(result: HIDMITokenPromptResult? = nil) {
        self.result = result
    }

    func requestToken(for device: HIDMIDiscoveredDevice) async -> HIDMITokenPromptResult? {
        requestedDeviceIDs.append(device.id)
        return result
    }
}

private final class FakeTokenStore: HIDMITokenStoreProtocol {
    var isSessionUnlocked = true
    var records = [HIDMITokenMetadata]()
    var tokenValuesByID = [UUID: String]()
    var preferredTokenByDeviceID = [String: UUID]()
    var successfulUses = [UUID: String]()
    var savedTokenValues = [String]()
    var deletedTokenIDs = [UUID]()
    var unlockSavedTokensCount = 0
    var unlockError: Error?
    var candidatesError: Error?

    func migrateLegacyTokensIfNeeded() {}

    func metadata() -> [HIDMITokenMetadata] {
        records
    }

    func unlockSavedTokens(context: HIDMIAuthenticationContext?) throws {
        unlockSavedTokensCount += 1
        if let unlockError {
            isSessionUnlocked = false
            throw unlockError
        }
        isSessionUnlocked = true
    }

    func candidates(preferredForDeviceID deviceID: String?) throws -> [HIDMITokenCandidate] {
        if let candidatesError {
            throw candidatesError
        }
        guard isSessionUnlocked else { return [] }
        var ordered = records
        if let deviceID,
           let preferredID = preferredTokenByDeviceID[deviceID],
           let index = ordered.firstIndex(where: { $0.id == preferredID }) {
            let preferred = ordered.remove(at: index)
            ordered.insert(preferred, at: 0)
        }
        return ordered.compactMap { record in
            guard let value = tokenValuesByID[record.id] else { return nil }
            return HIDMITokenCandidate(id: record.id, preview: record.preview, value: value)
        }
    }

    func tokenValue(id: UUID) throws -> String {
        guard isSessionUnlocked else {
            throw HIDMITokenStoreError.sessionLocked
        }
        guard let value = tokenValuesByID[id] else {
            throw HIDMITokenStoreError.tokenNotFound
        }
        return value
    }

    @discardableResult
    func saveToken(_ token: String) throws -> HIDMITokenMetadata {
        let record = addKnownToken(token)
        savedTokenValues.append(token)
        return record
    }

    func deleteToken(id: UUID) throws {
        deletedTokenIDs.append(id)
        records.removeAll { $0.id == id }
        tokenValuesByID[id] = nil
    }

    func recordSuccessfulUse(tokenID: UUID, deviceID: String) {
        successfulUses[tokenID] = deviceID
    }

    @discardableResult
    func addKnownToken(_ token: String) -> HIDMITokenMetadata {
        let record = HIDMITokenMetadata(
            id: UUID(),
            preview: "******** \(token.suffix(4))",
            createdAt: Date(),
            lastUsedAt: nil
        )
        records.append(record)
        tokenValuesByID[record.id] = token
        return record
    }
}

private final class FakeAuthenticator: DeviceOwnerAuthenticating {
    let result: HIDMIAuthenticationContext?
    var reasons = [String]()

    init(result: HIDMIAuthenticationContext?) {
        self.result = result
    }

    func authenticate(reason: String) async -> HIDMIAuthenticationContext? {
        reasons.append(reason)
        return result
    }
}
