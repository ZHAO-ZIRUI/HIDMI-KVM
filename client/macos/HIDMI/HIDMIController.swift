import AppKit
import Combine
import Foundation

struct HIDMIDiscoveredDevice: Identifiable, Equatable, Sendable {
    let id: String
    var host: String
    var udpPort: Int
    var tcpPort: Int
    var deviceID: String
    var displayName: String
    var transport: HIDMIDeviceTransport
    var usbInterface: String?
    var summary: String
    var supportsAbsolutePointer: Bool
    var requiresAuth: Bool
    var availability: HIDMIDeviceAvailability
    var lastSeen: Date

    init(device: HIDMIDevice, lastSeen: Date) {
        id = device.discoveryID
        host = device.host
        udpPort = device.udpPort
        tcpPort = device.tcpPort
        deviceID = device.deviceID
        displayName = device.displayName
        transport = device.transport
        usbInterface = device.usbInterface
        summary = device.summary
        supportsAbsolutePointer = device.supportsAbsolutePointer
        requiresAuth = device.requiresAuth
        availability = device.availability
        self.lastSeen = lastSeen
    }

    var menuTitle: String {
        displayName
    }

    var connectionAddressSummary: String {
        switch transport {
        case .ethernet, .wlan:
            return host.isEmpty ? id : host
        case .usb:
            if let trimmed = usbInterface?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
            return deviceID.isEmpty ? id : deviceID
        }
    }

    var isConnectable: Bool {
        availability.isConnectable
    }

    func menuDetails() -> [HIDMIMenuDeviceDetail] {
        switch transport {
        case .ethernet:
            return [
                HIDMIMenuDeviceDetail(
                    kind: .transport,
                    title: String(localized: "hid.device.eth_device")
                ),
                HIDMIMenuDeviceDetail(
                    kind: .ipAddress,
                    title: String(format: String(localized: "hid.device.ip_addr"), host)
                )
            ]
        case .wlan:
            return [
                HIDMIMenuDeviceDetail(
                    kind: .transport,
                    title: String(localized: "hid.device.wlan_device")
                ),
                HIDMIMenuDeviceDetail(
                    kind: .ipAddress,
                    title: String(format: String(localized: "hid.device.ip_addr"), host)
                )
            ]
        case .usb:
            let devicePathOrID: String
            if let trimmed = usbInterface?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                devicePathOrID = trimmed
            } else if !deviceID.isEmpty {
                devicePathOrID = deviceID
            } else {
                devicePathOrID = "-"
            }
            return [
                HIDMIMenuDeviceDetail(
                    kind: .transport,
                    title: String(localized: "hid.device.usb_device")
                ),
                HIDMIMenuDeviceDetail(
                    kind: .usbInterface,
                    title: String(format: String(localized: "hid.device.usb_interface"), devicePathOrID)
                )
            ]
        }
    }
}

enum HIDMIMenuDeviceDetailKind: String, Equatable, Sendable {
    case transport
    case ipAddress
    case usbInterface
}

struct HIDMIMenuDeviceDetail: Identifiable, Equatable, Sendable {
    let kind: HIDMIMenuDeviceDetailKind
    let title: String

    var id: String {
        kind.rawValue
    }
}

enum HIDMIMenuSelectionMarker: Equatable {
    case connected
    case selected
    case available
}

enum HIDMIDiscoveryRefreshSource: Equatable {
    case startup
    case background
    case manual
}

struct HIDMIMenuDeviceState: Identifiable, Equatable {
    let id: HIDMIDiscoveredDevice.ID
    let device: HIDMIDiscoveredDevice
    let marker: HIDMIMenuSelectionMarker

    var menuDetails: [HIDMIMenuDeviceDetail] {
        device.menuDetails()
    }
}

@MainActor
protocol HIDMIConnectionWarningPresenting: AnyObject {
    func showConnectionFailure(device: HIDMIDiscoveredDevice, message: String)
    func showConnectionLost(device: HIDMIDiscoveredDevice?, message: String)
}

@MainActor
final class AlertHIDMIConnectionWarningPresenter: HIDMIConnectionWarningPresenting {
    func showConnectionFailure(device: HIDMIDiscoveredDevice, message: String) {
        let body = String(
            format: String(localized: "hid.connection.warning.failure_message"),
            device.displayName,
            device.connectionAddressSummary,
            message
        )
        showWarning(
            title: String(localized: "hid.connection.warning.failure_title"),
            message: body
        )
    }

    func showConnectionLost(device: HIDMIDiscoveredDevice?, message: String) {
        let deviceSummary = device.map { "\($0.displayName) (\($0.connectionAddressSummary))" }
            ?? String(localized: "hid.connection.warning.unknown_device")
        let body = String(
            format: String(localized: "hid.connection.warning.lost_message"),
            deviceSummary,
            message
        )
        showWarning(
            title: String(localized: "hid.connection.warning.lost_title"),
            message: body
        )
    }

    private func showWarning(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok"))

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

protocol HIDMIWorkerProtocol: Sendable {
    func discoverBroadcast(timeout: TimeInterval) async throws -> [HIDMIDevice]
    func connect(device: HIDMIDevice, token: String, timeout: TimeInterval, establishedIOTimeout: TimeInterval) async throws -> HIDMIWorkerConnection
    func disconnect() async
    func releaseAll(generation: UInt64) async throws
    func releaseAllBestEffort(generation: UInt64, timeout: TimeInterval) async
    func shutdownBestEffort(timeout: TimeInterval) async
    func ping(generation: UInt64) async throws
    func sendReports(_ reports: [HIDMISampledInputReport], generation: UInt64) async throws
    func sendCtrlAltDel(generation: UInt64) async throws
}

struct HIDMIWorkerConnection: Sendable {
    let device: HIDMIDevice
    let generation: UInt64
    let mouseWriter: (any HIDMIMouseReportWriting)?
    let keyboardWriter: (any HIDMIKeyboardReportWriting)?

    init(
        device: HIDMIDevice,
        generation: UInt64,
        mouseWriter: (any HIDMIMouseReportWriting)? = nil,
        keyboardWriter: (any HIDMIKeyboardReportWriting)? = nil
    ) {
        self.device = device
        self.generation = generation
        self.mouseWriter = mouseWriter
        self.keyboardWriter = keyboardWriter
    }
}

enum HIDMIInputReportSource: Sendable, Equatable {
    case reliable
    case pointerMove
}

struct HIDMIInputDiagnostics: Equatable, Sendable {
    var mouseEventsCaptured = 0
    var mouseReportsWritten = 0
    var mouseSendErrors = 0
}

private enum HIDMIConnectionOperation {
    case connect
    case keepalive
    case inputReport
    case releaseAll
    case ctrlAltDel

    var localizedTitle: String {
        switch self {
        case .connect:
            return String(localized: "hid.operation.connect")
        case .keepalive:
            return String(localized: "hid.operation.keepalive")
        case .inputReport:
            return String(localized: "hid.operation.input_report")
        case .releaseAll:
            return String(localized: "hid.operation.release_all")
        case .ctrlAltDel:
            return String(localized: "hid.operation.ctrl_alt_del")
        }
    }
}

@MainActor
final class HIDMIController: ObservableObject {
    enum Status: Equatable {
        case disconnected
        case discovering
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var lastError: String?
    @Published private(set) var usesAbsolutePointer = false
    @Published private(set) var discoveredDevices: [HIDMIDiscoveredDevice] = []
    @Published private(set) var selectedDeviceID: HIDMIDiscoveredDevice.ID?
    @Published private(set) var connectedDeviceID: HIDMIDiscoveredDevice.ID?
    @Published private(set) var endpointConnectionFailuresByDeviceID = [HIDMIDiscoveredDevice.ID: String]()
    private(set) var inputDiagnostics = HIDMIInputDiagnostics()

    var onConnectionLost: (() -> Void)?

    private let worker: any HIDMIWorkerProtocol
    private let tokenStore: HIDMITokenStoreProtocol
    private let tokenPrompt: HIDMITokenPrompting
    private let warningPresenter: HIDMIConnectionWarningPresenting
    private let timeout: TimeInterval
    private let establishedIOTimeout: TimeInterval
    private let discoveryInterval: TimeInterval
    private let offlineInterval: TimeInterval
    private let keepaliveInterval: TimeInterval
    private let keepaliveFailureLimit: Int
    private let reconnectDelays: [TimeInterval]
    private let now: () -> Date
    private var discoveryTask: Task<Void, Never>?
    private var discoveryRefreshTask: Task<Void, Never>?
    private var discoveryRefreshSource: HIDMIDiscoveryRefreshSource?
    private var discoveryRefreshGeneration = 0
    private var connectionTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectionAttemptID = 0
    private var activeConnectionGeneration: UInt64?
    private var activeMouseWriter: (any HIDMIMouseReportWriting)?
    private var activeKeyboardWriter: (any HIDMIKeyboardReportWriting)?
    private var keepaliveFailureCount = 0
    private var lastSeenByDeviceID = [HIDMIDiscoveredDevice.ID: Date]()
    private var knownDevicesByID = [HIDMIDiscoveredDevice.ID: HIDMIDevice]()
    private var lastWarningDateByKey = [String: Date]()
    init(
        worker: any HIDMIWorkerProtocol = HIDMIWorker(),
        tokenStore: HIDMITokenStoreProtocol,
        tokenPrompt: HIDMITokenPrompting = AlertHIDMITokenPrompt(),
        warningPresenter: HIDMIConnectionWarningPresenting = AlertHIDMIConnectionWarningPresenter(),
        timeout: TimeInterval = 3.0,
        establishedIOTimeout: TimeInterval = 15.0,
        discoveryInterval: TimeInterval = 1.0,
        offlineInterval: TimeInterval = 45.0,
        keepaliveInterval: TimeInterval = 1.0,
        keepaliveFailureLimit: Int = 3,
        reconnectDelays: [TimeInterval] = [1.0, 2.0, 4.0, 8.0, 15.0],
        now: @escaping () -> Date = Date.init
    ) {
        self.worker = worker
        self.tokenStore = tokenStore
        self.tokenPrompt = tokenPrompt
        self.warningPresenter = warningPresenter
        self.timeout = timeout
        self.establishedIOTimeout = establishedIOTimeout
        self.discoveryInterval = discoveryInterval
        self.offlineInterval = offlineInterval
        self.keepaliveInterval = keepaliveInterval
        self.keepaliveFailureLimit = max(1, keepaliveFailureLimit)
        self.reconnectDelays = reconnectDelays
        self.now = now
    }

    deinit {
        discoveryTask?.cancel()
        discoveryRefreshTask?.cancel()
        connectionTask?.cancel()
        keepaliveTask?.cancel()
        reconnectTask?.cancel()
    }

    var isConnected: Bool {
        connectedDeviceID != nil
    }

    var connectingDeviceID: HIDMIDiscoveredDevice.ID? {
        if case .connecting = status {
            return selectedDeviceID
        }
        return nil
    }

    var isDiscovering: Bool {
        if case .discovering = status {
            return true
        }
        return discoveryRefreshTask != nil && discoveryRefreshSource == .manual
    }

    var statusText: String {
        switch status {
        case .disconnected:
            return String(localized: "hidmi.status.disconnected")
        case .discovering:
            return String(localized: "hidmi.status.discovering")
        case .connecting(let summary):
            return String(format: String(localized: "hidmi.status.connecting_device"), summary)
        case .connected(let summary):
            return String(format: String(localized: "hidmi.status.connected"), summary)
        case .failed(let message):
            return String(format: String(localized: "hidmi.status.failed"), message)
        }
    }

    var menuConnectionStatusText: String {
        isConnected
            ? String(localized: "hidmi.connection_status.connected")
            : String(localized: "hidmi.connection_status.disconnected")
    }

    var menuDeviceStates: [HIDMIMenuDeviceState] {
        discoveredDevices.map { device in
            let marker: HIDMIMenuSelectionMarker
            if connectedDeviceID == device.id {
                marker = .connected
            } else if selectedDeviceID == device.id {
                marker = .selected
            } else {
                marker = .available
            }
            return HIDMIMenuDeviceState(id: device.id, device: device, marker: marker)
        }
    }

    func startDiscovery() {
        guard discoveryTask == nil else { return }
        refreshDiscoveredDevices(source: .startup)
        let interval = discoveryInterval
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                self.refreshDiscoveredDevices(source: .background)
            }
        }
    }

    func refreshDiscoveredDevices(
        source: HIDMIDiscoveryRefreshSource = .manual,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        if source == .manual {
            endpointConnectionFailuresByDeviceID.removeAll()
        }
        if let discoveryRefreshTask {
            guard source == .manual && discoveryRefreshSource != .manual else { return }
            discoveryRefreshTask.cancel()
            self.discoveryRefreshTask = nil
            discoveryRefreshSource = nil
        }

        let shouldShowStatus = source == .manual && !isConnected
        if shouldShowStatus {
            setStatus(.discovering)
        }
        discoveryRefreshGeneration += 1
        let generation = discoveryRefreshGeneration
        discoveryRefreshSource = source
        discoveryRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let devices = try await worker.discoverBroadcast(timeout: 1.0)
                await MainActor.run {
                    guard self.discoveryRefreshGeneration == generation else { return }
                    self.mergeDiscoveredDevices(devices, seenAt: self.now())
                    if shouldShowStatus {
                        self.setStatus(.disconnected)
                    }
                    self.clearDiscoveryRefresh(generation: generation)
                    completion?()
                }
            } catch {
                await MainActor.run {
                    guard self.discoveryRefreshGeneration == generation else { return }
                    self.pruneOfflineDevices(seenAt: self.now())
                    if shouldShowStatus {
                        self.setFailure(error.localizedDescription, clearSelection: false)
                    }
                    self.clearDiscoveryRefresh(generation: generation)
                    completion?()
                }
            }
        }
    }

    func connect(to id: HIDMIDiscoveredDevice.ID, presentFailureWarning: Bool = true) {
        guard let device = discoveredDevices.first(where: { $0.id == id }) else { return }
        guard device.isConnectable else {
            selectedDeviceID = id
            let message = device.availability.userFacingConnectionDescription
            endpointConnectionFailuresByDeviceID[id] = message
            let kind = device.availability.connectionFailureKind
            setFailure(message, clearSelection: false)
            if presentFailureWarning, kind != .busy, shouldPresentWarning(deviceID: device.id, kind: kind, operation: .connect) {
                warningPresenter.showConnectionFailure(device: device, message: message)
            }
            return
        }
        cancelReconnect()
        connectionAttemptID += 1
        let attemptID = connectionAttemptID
        selectedDeviceID = id
        endpointConnectionFailuresByDeviceID[id] = nil
        connectionTask?.cancel()
        let hadActiveConnection = connectedDeviceID != nil
        stopKeepalive()
        activeConnectionGeneration = nil
        activeMouseWriter = nil
        activeKeyboardWriter = nil
        connectedDeviceID = nil
        usesAbsolutePointer = false
        setStatus(.connecting(device.summary))
        connectionTask = Task { [weak self] in
            _ = await self?.connectToDevice(
                device,
                attemptID: attemptID,
                disconnectExistingSession: hadActiveConnection,
                allowTokenPrompt: true,
                presentFailureWarning: presentFailureWarning
            )
        }
    }

    func cancelConnectionAttempt() {
        guard connectingDeviceID != nil else { return }
        connectionAttemptID += 1
        connectionTask?.cancel()
        connectionTask = nil
        activeConnectionGeneration = nil
        activeMouseWriter = nil
        activeKeyboardWriter = nil
        connectedDeviceID = nil
        usesAbsolutePointer = false
        setStatus(.disconnected)
    }

    func disconnect() {
        cancelReconnect()
        connectionAttemptID += 1
        connectionTask?.cancel()
        stopKeepalive()
        activeConnectionGeneration = nil
        activeMouseWriter = nil
        activeKeyboardWriter = nil
        connectedDeviceID = nil
        usesAbsolutePointer = false
        Task {
            await worker.disconnect()
        }
        setStatus(.disconnected)
    }

    func releaseAll() {
        guard isConnected, let generation = activeConnectionGeneration else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.worker.releaseAll(generation: generation)
                guard self.isActiveConnectionGeneration(generation) else { return }
                self.recordSuccessfulConnectionOperation()
            } catch {
                guard self.isActiveConnectionGeneration(generation) else { return }
                self.handleConnectionOperationFailure(error, operation: .releaseAll)
            }
        }
    }

    func releaseAllBestEffort(timeout: TimeInterval = 0.3) {
        guard isConnected, let generation = activeConnectionGeneration else { return }
        Task { [worker] in
            await worker.releaseAllBestEffort(generation: generation, timeout: timeout)
        }
    }

    func prepareForTermination(timeout: TimeInterval = 0.5) {
        connectionTask?.cancel()
        keepaliveTask?.cancel()
        reconnectTask?.cancel()
        activeConnectionGeneration = nil
        activeMouseWriter = nil
        activeKeyboardWriter = nil
        connectedDeviceID = nil
        usesAbsolutePointer = false

        let worker = worker
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await worker.shutdownBestEffort(timeout: timeout)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    func sendReports(
        _ reports: [RemoteInputReport],
        source: HIDMIInputReportSource = .reliable,
        sampleMonoUs: UInt64 = HIDMIMonotonic.microseconds()
    ) {
        guard !reports.isEmpty else { return }
        guard isConnected, let generation = activeConnectionGeneration else {
            HIDMIInputTrace.log(
                "send_drop",
                fields: [
                    "reason": "not_connected",
                    "source": "\(source)"
                ]
            )
            return
        }
        let sampledReports = reports.map {
            HIDMISampledInputReport(report: $0, sampleMonoUs: sampleMonoUs)
        }
        let mouseReports = sampledReports.filter(\.report.isMouseReport)
        let keyboardReports = sampledReports.filter(\.report.isKeyboardReport)
        if source == .pointerMove {
            inputDiagnostics.mouseEventsCaptured += mouseReports.count
        }
        HIDMIInputTrace.log(
            "send_called",
            fields: [
                "count": "\(reports.count)",
                "generation": "\(generation)",
                "keyboard_count": "\(keyboardReports.count)",
                "mouse_count": "\(mouseReports.count)",
                "sample_mono_us": "\(sampleMonoUs)",
                "source": "\(source)"
            ]
        )
        if !mouseReports.isEmpty {
            enqueueMouseReports(mouseReports, generation: generation, operation: .inputReport)
        }
        if !keyboardReports.isEmpty {
            enqueueKeyboardReports(
                keyboardReports,
                generation: generation,
                operation: .inputReport
            )
        }
    }

    private func enqueueMouseReports(
        _ reports: [HIDMISampledInputReport],
        generation: UInt64,
        operation: HIDMIConnectionOperation
    ) {
        guard let activeMouseWriter else {
            inputDiagnostics.mouseSendErrors += 1
            HIDMIInputTrace.log(
                "writer_enqueue",
                fields: [
                    "count": "\(reports.count)",
                    "error": "missing_writer",
                    "generation": "\(generation)"
                ]
            )
            handleConnectionOperationFailure(
                HIDMIClientError.message(String(localized: "error.not_connected")),
                operation: operation
            )
            return
        }
        activeMouseWriter.enqueueMouseReports(reports) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.isActiveConnectionGeneration(generation) else { return }
                switch result {
                case .success(let count):
                    self.inputDiagnostics.mouseReportsWritten += count
                    self.recordSuccessfulConnectionOperation()
                case .failure(let error):
                    self.inputDiagnostics.mouseSendErrors += 1
                    self.handleConnectionOperationFailure(error, operation: operation)
                }
            }
        }
    }

    private func enqueueKeyboardReports(
        _ reports: [HIDMISampledInputReport],
        generation: UInt64,
        operation: HIDMIConnectionOperation
    ) {
        guard let activeKeyboardWriter else {
            HIDMIInputTrace.log(
                "keyboard_enqueue",
                fields: [
                    "count": "\(reports.count)",
                    "error": "missing_writer",
                    "generation": "\(generation)"
                ]
            )
            handleConnectionOperationFailure(
                HIDMIClientError.message(String(localized: "error.not_connected")),
                operation: operation
            )
            return
        }
        activeKeyboardWriter.enqueueKeyboardReports(reports) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.isActiveConnectionGeneration(generation) else { return }
                switch result {
                case .success:
                    self.recordSuccessfulConnectionOperation()
                case .failure(let error):
                    self.handleConnectionOperationFailure(error, operation: operation)
                }
            }
        }
    }

    func sendCtrlAltDel() {
        guard isConnected, let generation = activeConnectionGeneration else { return }
        guard let activeKeyboardWriter else {
            handleConnectionOperationFailure(
                HIDMIClientError.message(String(localized: "error.not_connected")),
                operation: .ctrlAltDel
            )
            return
        }
        activeKeyboardWriter.enqueueCtrlAltDel { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.isActiveConnectionGeneration(generation) else { return }
                switch result {
                case .success:
                    self.recordSuccessfulConnectionOperation()
                case .failure(let error):
                    self.handleConnectionOperationFailure(error, operation: .ctrlAltDel)
                }
            }
        }
    }

    func mergeDiscoveredDevices(_ devices: [HIDMIDevice], seenAt: Date) {
        var current = Dictionary(uniqueKeysWithValues: discoveredDevices.map { ($0.id, $0) })
        for device in devices {
            let discovered = HIDMIDiscoveredDevice(device: device, lastSeen: seenAt)
            lastSeenByDeviceID[discovered.id] = seenAt
            knownDevicesByID[discovered.id] = device
            current[discovered.id] = discovered
        }
        applyDiscoveredDeviceList(current.values, seenAt: seenAt)
        updateInputCapabilities()
    }

    func pruneOfflineDevices(seenAt: Date) {
        applyDiscoveredDeviceList(discoveredDevices, seenAt: seenAt)
        updateInputCapabilities()
    }

    private func clearDiscoveryRefresh(generation: Int) {
        guard discoveryRefreshGeneration == generation else { return }
        discoveryRefreshTask = nil
        discoveryRefreshSource = nil
    }

    private func applyDiscoveredDeviceList<S: Sequence>(
        _ devices: S,
        seenAt: Date
    ) where S.Element == HIDMIDiscoveredDevice {
        let next = devices
            .filter { device in
                device.id == connectedDeviceID
                    || seenAt.timeIntervalSince(lastSeenByDeviceID[device.id] ?? device.lastSeen) <= offlineInterval
            }
            .sorted {
                $0.menuTitle.localizedStandardCompare($1.menuTitle) == .orderedAscending
            }
        let visibleIDs = Set(next.map(\.id))
        lastSeenByDeviceID = lastSeenByDeviceID.filter { visibleIDs.contains($0.key) }
        knownDevicesByID = knownDevicesByID.filter { visibleIDs.contains($0.key) }
        if !discoveryDeviceListsMatchForPublishing(discoveredDevices, next) {
            discoveredDevices = next
        }
    }

    private func discoveryDeviceListsMatchForPublishing(
        _ lhs: [HIDMIDiscoveredDevice],
        _ rhs: [HIDMIDiscoveredDevice]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.id == right.id
                && left.host == right.host
                && left.udpPort == right.udpPort
                && left.tcpPort == right.tcpPort
                && left.deviceID == right.deviceID
                && left.displayName == right.displayName
                && left.transport == right.transport
                && left.usbInterface == right.usbInterface
                && left.summary == right.summary
                && left.supportsAbsolutePointer == right.supportsAbsolutePointer
                && left.requiresAuth == right.requiresAuth
                && left.availability == right.availability
        }
    }

    private func connectToDevice(
        _ device: HIDMIDiscoveredDevice,
        attemptID: Int,
        disconnectExistingSession: Bool,
        allowTokenPrompt: Bool,
        presentFailureWarning: Bool
    ) async -> Bool {
        if disconnectExistingSession {
            await worker.disconnect()
            guard isCurrentConnectionAttempt(attemptID, deviceID: device.id) else { return false }
        }

        let candidates: [HIDMITokenCandidate]
        let candidateLoadFailure: String?
        do {
            candidates = try tokenStore.candidates(preferredForDeviceID: device.deviceID)
            candidateLoadFailure = nil
        } catch {
            candidates = []
            candidateLoadFailure = error.localizedDescription
            lastError = candidateLoadFailure
        }

        guard isCurrentConnectionAttempt(attemptID, deviceID: device.id) else { return false }

        if await tryTokenCandidates(
            candidates,
            for: device,
            attemptID: attemptID,
            presentFailureWarning: presentFailureWarning
        ) {
            return connectedDeviceID == device.id
        }

        if candidates.isEmpty && !device.requiresAuth {
            do {
                guard let hidmiDevice = knownDevicesByID[device.id] else {
                    throw HIDMIClientError.message(String(localized: "error.discovery_no_offer"))
                }
                let connection = try await worker.connect(
                    device: hidmiDevice,
                    token: "",
                    timeout: timeout,
                    establishedIOTimeout: establishedIOTimeout
                )
                completeConnection(connection: connection, tokenID: nil, attemptID: attemptID)
                return connectedDeviceID == device.id
            } catch {
                guard isCurrentConnectionAttempt(attemptID, deviceID: device.id) else { return false }
                guard isAuthenticationFailure(error) else {
                    handleConnectionFailure(error, device: device, clearSelection: false, presentWarning: presentFailureWarning)
                    return false
                }
            }
        }

        guard isCurrentConnectionAttempt(attemptID, deviceID: device.id) else { return false }
        guard allowTokenPrompt else {
            setFailure(String(localized: "error.auto_reconnect_requires_saved_token"), clearSelection: false)
            return false
        }
        guard let promptResult = await tokenPrompt.requestToken(for: device) else {
            guard isCurrentConnectionAttempt(attemptID, deviceID: device.id) else { return false }
            if let candidateLoadFailure {
                setFailure(candidateLoadFailure, clearSelection: false)
            } else {
                setStatus(.disconnected)
            }
            return false
        }

        do {
            guard isCurrentConnectionAttempt(attemptID, deviceID: device.id) else { return false }
            guard let hidmiDevice = knownDevicesByID[device.id] else {
                throw HIDMIClientError.message(String(localized: "error.discovery_no_offer"))
            }
            let connection = try await worker.connect(
                device: hidmiDevice,
                token: promptResult.token,
                timeout: timeout,
                establishedIOTimeout: establishedIOTimeout
            )
            guard isCurrentConnectionAttempt(attemptID, deviceID: device.id) else { return false }
            var savedTokenID: UUID?
            if promptResult.remember {
                let saved = try tokenStore.saveToken(promptResult.token)
                savedTokenID = saved.id
            }
            completeConnection(connection: connection, tokenID: savedTokenID, attemptID: attemptID)
            return connectedDeviceID == device.id
        } catch {
            guard isCurrentConnectionAttempt(attemptID, deviceID: device.id) else { return false }
            handleConnectionFailure(error, device: device, clearSelection: false, presentWarning: presentFailureWarning)
            return false
        }
    }

    private func tryTokenCandidates(
        _ candidates: [HIDMITokenCandidate],
        for device: HIDMIDiscoveredDevice,
        attemptID: Int,
        presentFailureWarning: Bool
    ) async -> Bool {
        for candidate in candidates {
            if Task.isCancelled { return true }
            guard isCurrentConnectionAttempt(attemptID, deviceID: device.id) else { return true }
            do {
                guard let hidmiDevice = knownDevicesByID[device.id] else {
                    throw HIDMIClientError.message(String(localized: "error.discovery_no_offer"))
                }
                let connection = try await worker.connect(
                    device: hidmiDevice,
                    token: candidate.value,
                    timeout: timeout,
                    establishedIOTimeout: establishedIOTimeout
                )
                completeConnection(connection: connection, tokenID: candidate.id, attemptID: attemptID)
                return true
            } catch {
                guard isCurrentConnectionAttempt(attemptID, deviceID: device.id) else { return true }
                if isAuthenticationFailure(error) {
                    continue
                }
                handleConnectionFailure(error, device: device, clearSelection: false, presentWarning: presentFailureWarning)
                return true
            }
        }
        return false
    }

    private func completeConnection(connection: HIDMIWorkerConnection, tokenID: UUID?, attemptID: Int) {
        let device = connection.device
        let discovered = HIDMIDiscoveredDevice(device: device, lastSeen: now())
        guard isCurrentConnectionAttempt(attemptID, deviceID: discovered.id) else { return }
        mergeDiscoveredDevices([device], seenAt: now())
        selectedDeviceID = discovered.id
        connectedDeviceID = discovered.id
        endpointConnectionFailuresByDeviceID[discovered.id] = nil
        activeConnectionGeneration = connection.generation
        activeMouseWriter = connection.mouseWriter
        activeKeyboardWriter = connection.keyboardWriter
        updateInputCapabilities()
        if let tokenID {
            tokenStore.recordSuccessfulUse(tokenID: tokenID, deviceID: device.deviceID)
        }
        recordSuccessfulConnectionOperation()
        setStatus(.connected(device.summary))
    }

    private func setStatus(_ next: Status) {
        status = next
        if case .failed(let message) = next {
            lastError = message
            stopKeepalive()
            usesAbsolutePointer = false
            activeConnectionGeneration = nil
            activeMouseWriter = nil
            activeKeyboardWriter = nil
        } else {
            lastError = nil
        }
        if case .connected = next {
            startKeepalive()
        } else if case .disconnected = next {
            stopKeepalive()
            usesAbsolutePointer = false
            connectedDeviceID = nil
            activeConnectionGeneration = nil
            activeMouseWriter = nil
            activeKeyboardWriter = nil
        }
    }

    private func setFailure(_ message: String, clearSelection: Bool) {
        if clearSelection {
            selectedDeviceID = nil
        }
        connectedDeviceID = nil
        activeConnectionGeneration = nil
        activeMouseWriter = nil
        activeKeyboardWriter = nil
        setStatus(.failed(message))
    }

    private func handleConnectionFailure(
        _ error: Error,
        device: HIDMIDiscoveredDevice,
        clearSelection: Bool,
        presentWarning: Bool
    ) {
        let message = connectionMessage(for: error, operation: .connect)
        endpointConnectionFailuresByDeviceID[device.id] = message
        setFailure(message, clearSelection: clearSelection)
        let kind = connectionFailureKind(for: error)
        if kind == .busy && presentWarning {
            scheduleAutomaticReconnect(to: device)
        } else if presentWarning, shouldPresentWarning(deviceID: device.id, kind: kind, operation: .connect) {
            warningPresenter.showConnectionFailure(device: device, message: message)
        }
    }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        let interval = keepaliveInterval
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, self.isConnected, let generation = self.activeConnectionGeneration else { continue }
                do {
                    try await self.worker.ping(generation: generation)
                    guard self.isActiveConnectionGeneration(generation) else { continue }
                    self.recordSuccessfulConnectionOperation()
                } catch {
                    guard self.isActiveConnectionGeneration(generation) else { continue }
                    let didDisconnect = self.handleConnectionOperationFailure(error, operation: .keepalive)
                    if didDisconnect {
                        return
                    }
                }
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    @discardableResult
    private func handleConnectionOperationFailure(_ error: Error, operation: HIDMIConnectionOperation) -> Bool {
        let kind = connectionFailureKind(for: error)
        if kind == .timeout {
            keepaliveFailureCount += 1
            if keepaliveFailureCount < keepaliveFailureLimit {
                lastError = String(
                    format: String(localized: "hidmi.connection.unstable"),
                    operation.localizedTitle,
                    keepaliveFailureCount,
                    keepaliveFailureLimit
                )
                return false
            }
        }
        let message = connectionMessage(for: error, operation: operation)
        handleConnectionLost(message)
        return true
    }

    private func recordSuccessfulConnectionOperation() {
        keepaliveFailureCount = 0
        if isConnected, lastError != nil {
            lastError = nil
        }
    }

    private func handleConnectionLost(_ message: String) {
        let hadConnection = connectedDeviceID != nil
        let lostDevice = connectedDeviceID.flatMap { id in
            discoveredDevices.first { $0.id == id }
        }
        connectedDeviceID = nil
        activeConnectionGeneration = nil
        activeMouseWriter = nil
        activeKeyboardWriter = nil
        usesAbsolutePointer = false
        stopKeepalive()
        if hadConnection {
            onConnectionLost?()
        }
        setStatus(.failed(message))
        if hadConnection {
            if let lostDevice {
                endpointConnectionFailuresByDeviceID[lostDevice.id] = message
            }
            let keyDeviceID = lostDevice?.id ?? "unknown"
            if shouldPresentWarning(deviceID: keyDeviceID, kind: connectionFailureKind(forMessage: message), operation: .keepalive) {
                warningPresenter.showConnectionLost(device: lostDevice, message: message)
            }
            if let lostDevice {
                scheduleAutomaticReconnect(to: lostDevice)
            }
        }
    }

    private func scheduleAutomaticReconnect(to device: HIDMIDiscoveredDevice) {
        guard !reconnectDelays.isEmpty else { return }
        reconnectTask?.cancel()
        let delays = reconnectDelays
        reconnectTask = Task { [weak self] in
            var attemptIndex = 0
            while !Task.isCancelled {
                let delay = delays[min(attemptIndex, delays.count - 1)]
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard let self else { return }
                guard self.connectedDeviceID == nil else { return }
                let currentDevice = self.discoveredDevices.first(where: { $0.id == device.id }) ?? device
                self.connectionAttemptID += 1
                let attemptID = self.connectionAttemptID
                self.selectedDeviceID = currentDevice.id
                self.setStatus(.connecting(currentDevice.summary))
                self.lastError = String(format: String(localized: "hidmi.status.reconnecting_device"), currentDevice.summary)
                let connected = await self.connectToDevice(
                    currentDevice,
                    attemptID: attemptID,
                    disconnectExistingSession: false,
                    allowTokenPrompt: false,
                    presentFailureWarning: false
                )
                if connected {
                    return
                }
                attemptIndex += 1
            }
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func updateInputCapabilities() {
        guard let connectedDeviceID,
              let device = discoveredDevices.first(where: { $0.id == connectedDeviceID }) else {
            usesAbsolutePointer = false
            return
        }
        usesAbsolutePointer = device.supportsAbsolutePointer
    }

    private func isCurrentConnectionAttempt(_ attemptID: Int, deviceID: HIDMIDiscoveredDevice.ID) -> Bool {
        connectionAttemptID == attemptID && selectedDeviceID == deviceID && !Task.isCancelled
    }

    private func isActiveConnectionGeneration(_ generation: UInt64) -> Bool {
        activeConnectionGeneration == generation && connectedDeviceID != nil && !Task.isCancelled
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        if let clientError = error as? HIDMIClientError {
            return clientError.isAuthenticationFailure
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("authentication failed")
            || error.localizedDescription.localizedCaseInsensitiveContains("requires a token")
            || error.localizedDescription.localizedCaseInsensitiveContains("requires a hidmi kvm token")
            || error.localizedDescription.localizedCaseInsensitiveContains("HELLO_REJECTED")
    }

    private func connectionFailureKind(for error: Error) -> HIDMIConnectionFailureKind {
        if let clientError = error as? HIDMIClientError {
            return clientError.connectionFailureKind
        }
        let description = error.localizedDescription.lowercased()
        if description.contains("temporarily unavailable") || description.contains("timed out") || description.contains("timeout") {
            return .timeout
        }
        if description.contains("busy") {
            return .busy
        }
        if description.contains("closed") || description.contains("reset") || description.contains("not connected") {
            return .peerClosed
        }
        if description.contains("authentication") || description.contains("token") {
            return .authentication
        }
        if description.contains("hid") {
            return .hidFailure
        }
        return .network
    }

    private func connectionFailureKind(forMessage message: String) -> HIDMIConnectionFailureKind {
        connectionFailureKind(for: HIDMIClientError.message(message))
    }

    private func shouldPresentWarning(
        deviceID: String,
        kind: HIDMIConnectionFailureKind,
        operation: HIDMIConnectionOperation
    ) -> Bool {
        let key = "\(deviceID):\(kind):\(operation.localizedTitle)"
        let date = now()
        if let previous = lastWarningDateByKey[key],
           date.timeIntervalSince(previous) < 30 {
            return false
        }
        lastWarningDateByKey[key] = date
        return true
    }

    private func connectionMessage(for error: Error, operation: HIDMIConnectionOperation) -> String {
        let detail: String
        if let clientError = error as? HIDMIClientError {
            detail = clientError.userFacingConnectionDescription
        } else {
            detail = error.localizedDescription
        }
        return String(
            format: String(localized: "hidmi.connection.operation_failed"),
            operation.localizedTitle,
            detail
        )
    }
}

private actor HIDMIWorker: HIDMIWorkerProtocol {
    private var session: HIDMISession?
    private var sessionGeneration: UInt64 = 0

    func discoverBroadcast(timeout: TimeInterval) async throws -> [HIDMIDevice] {
        try HIDMIClient.discoverBroadcast(
            udpPort: HIDMIClient.defaultUDPPort,
            timeout: timeout
        )
    }

    func connect(device: HIDMIDevice, token: String, timeout: TimeInterval, establishedIOTimeout: TimeInterval) async throws -> HIDMIWorkerConnection {
        session?.close(releaseAll: true)
        session = nil
        sessionGeneration &+= 1
        let connectionGeneration = sessionGeneration

        let connectedSession = try HIDMIClient.connect(
            device: device,
            token: token,
            timeout: timeout,
            establishedIOTimeout: establishedIOTimeout
        )
        let capabilities = connectedSession.serverCapabilities.isEmpty ? device.capabilities : connectedSession.serverCapabilities
        let connectedDevice = device.withCapabilities(capabilities)
        session = connectedSession
        return HIDMIWorkerConnection(
            device: connectedDevice,
            generation: connectionGeneration,
            mouseWriter: connectedSession.mouseWriter,
            keyboardWriter: connectedSession.keyboardWriter
        )
    }


    private func isAcceptRequiredFailure(_ error: Error) -> Bool {
        guard let clientError = error as? HIDMIClientError else { return false }
        return clientError.isAcceptRequiredFailure
    }

    func disconnect() async {
        sessionGeneration &+= 1
        session?.close(releaseAll: true)
        session = nil
    }

    func releaseAll(generation: UInt64) async throws {
        guard let session = currentSession(for: generation) else { return }
        try session.sendReleaseAllBestEffort(timeout: 0.3)
    }

    func releaseAllBestEffort(generation: UInt64, timeout: TimeInterval) async {
        do {
            try currentSession(for: generation)?.sendReleaseAllBestEffort(timeout: timeout)
        } catch {
            // This path is used while menus, previews, or app shutdown are changing state.
            // It must not surface an error or block user interaction.
        }
    }

    func shutdownBestEffort(timeout: TimeInterval) async {
        if let session {
            try? session.sendReleaseAllBestEffort(timeout: timeout)
            session.close(releaseAll: false)
        }
        sessionGeneration &+= 1
        session = nil
    }

    func ping(generation: UInt64) async throws {
        guard let session = currentSession(for: generation) else { return }
        try session.sendHeartbeat()
    }

    func sendReports(_ reports: [HIDMISampledInputReport], generation: UInt64) async throws {
        guard currentSession(for: generation) != nil else { return }
        for sampledReport in reports {
            switch sampledReport.report {
            case .keyboard(let modifiers, let keys):
                try sendKeyboardReport(modifiers: modifiers, keys: keys, generation: generation)
            case .mouse, .absoluteMouse:
                try sendMouseReport(sampledReport, generation: generation)
            }
        }
    }

    func sendCtrlAltDel(generation: UInt64) async throws {
        guard let session = currentSession(for: generation) else { return }
        try session.sendKeyboardSpecial(.keyboardSpecialCtrlAltDel)
    }

    private func currentSession(for generation: UInt64) -> HIDMISession? {
        guard generation == sessionGeneration else { return nil }
        return session
    }

    private func sendKeyboardReport(modifiers: Int, keys: [Int], generation: UInt64) throws {
        guard let session = currentSession(for: generation) else { return }
        try session.sendKeyboardState(modifiers: modifiers, keys: keys)
    }

    private func sendMouseReport(_ report: HIDMISampledInputReport, generation: UInt64) throws {
        guard let session = currentSession(for: generation) else { return }
        try session.sendMouseReport(report)
    }
}
