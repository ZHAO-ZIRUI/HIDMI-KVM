import AVFoundation
import AppKit
import Combine
import SwiftUI

enum CameraPermissionStatus: Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted
    case unknown
}

protocol CameraPermissionManaging {
    func authorizationStatus() -> CameraPermissionStatus
    func requestAccess(completion: @escaping @Sendable (Bool) -> Void)
    func openCameraPrivacySettings()
}

enum CaptureStreamChangeKind: Equatable {
    case formatDescription
    case sessionFailure
}

enum CaptureStreamChangePolicy {
    static func requiresSessionReconfiguration(_ kind: CaptureStreamChangeKind) -> Bool {
        switch kind {
        case .formatDescription:
            false
        case .sessionFailure:
            true
        }
    }
}

final class SystemCameraPermissionManager: CameraPermissionManaging {
    func authorizationStatus() -> CameraPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }

    func requestAccess(completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
    }

    func openCameraPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        ]

        for value in urls {
            guard let url = URL(string: value) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

private final class AppMenuTrackingDelegate: NSObject, NSMenuDelegate {
    weak var model: AppModel?
    weak var previous: NSMenuDelegate?

    func menuWillOpen(_ menu: NSMenu) {
        previous?.menuWillOpen?(menu)
        Task { @MainActor [weak self] in
            self?.model?.installMenuTrackingDelegatesNow()
            self?.model?.beginMenuTracking()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        previous?.menuDidClose?(menu)
        Task { @MainActor [weak self] in
            self?.model?.endMenuTracking()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        previous?.menuNeedsUpdate?(menu)
    }

    func numberOfItems(in menu: NSMenu) -> Int {
        previous?.numberOfItems?(in: menu) ?? menu.numberOfItems
    }

    func menu(_ menu: NSMenu, update item: NSMenuItem, at index: Int, shouldCancel: Bool) -> Bool {
        previous?.menu?(menu, update: item, at: index, shouldCancel: shouldCancel) ?? true
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum ViewerState: Equatable {
        case idle
        case requestingPermission
        case permissionDenied
        case permissionRestricted
        case noDevice
        case configuring
        case running
        case failed(String)
    }

    private struct PendingCaptureFormatSwitch {
        let deviceID: CaptureDevice.ID
        let selection: CaptureFormatSelection
        let targetSignature: CaptureFormatSignature?
        let previousSelection: CaptureFormatSelection
        var configurationGeneration: UInt64?
        var minimumConfirmationSequence: UInt64?
        var activeFormatSignature: CaptureFormatSignature?
        var isConfirmationTimerScheduled = false

        func matches(_ observation: CaptureFrameObservation) -> Bool {
            guard let minimumConfirmationSequence,
                  observation.sequence > minimumConfirmationSequence else {
                return false
            }
            return CaptureFormatFallbackPolicy.matches(
                targetSignature: targetSignature,
                activeFormatSignature: activeFormatSignature,
                descriptor: observation.descriptor
            )
        }
    }

    private enum CaptureConfigurationState: Equatable {
        case idle
        case configuring(UInt64)
        case waitingForFrames(UInt64)
        case running(UInt64)
        case recovering(UInt64)

        var generation: UInt64? {
            switch self {
            case .idle:
                nil
            case .configuring(let generation),
                 .waitingForFrames(let generation),
                 .running(let generation),
                 .recovering(let generation):
                generation
            }
        }

        var isBusy: Bool {
            switch self {
            case .configuring, .waitingForFrames, .recovering:
                true
            case .idle, .running:
                false
            }
        }
    }

    private let deviceStore = CaptureDeviceStore()
    private let sessionController = CaptureSessionController()
    private let windowController = WindowController()
    private let tokenStore: HIDMITokenStoreProtocol
    private let authenticator: DeviceOwnerAuthenticating
    private let tokenManagementWindowController: TokenManagementWindowController
    private let cameraPermissionManager: CameraPermissionManaging
    private let startsVideoInputSetup: Bool
    private let frameStabilizationInterval: TimeInterval
    private let formatSwitchConfirmationInterval: TimeInterval
    private let captureReconfigurationDebounceInterval: TimeInterval
    private let cameraPermissionRequestTimeoutInterval: TimeInterval
    let hidmi: HIDMIController
    private var cancellables = Set<AnyCancellable>()
    private var menuTrackingDelegates = [ObjectIdentifier: AppMenuTrackingDelegate]()
    private var remoteInput = RemoteInputMapper()
    private var didStart = false
    private var nextConfigurationGeneration: UInt64 = 0
    private var captureConfigurationState: CaptureConfigurationState = .idle
    private var stableFrameObservation: CaptureFrameObservation?
    private var lastObservedFrameSequence: UInt64 = 0
    private var pendingFrameDescriptorWorkItem: DispatchWorkItem?
    private var pendingFormatSwitch: PendingCaptureFormatSwitch?
    private var pendingFormatTimeoutWorkItem: DispatchWorkItem?
    private var captureReconfigurationWorkItem: DispatchWorkItem?
    private var pendingCameraPermissionWorkItem: DispatchWorkItem?
    private var cameraPermissionRequestGeneration: UInt64 = 0
    private var isCaptureRecoveryDirty = false
    private var menuTrackingDepth = 0
    private var hasDeferredObjectWillChangeDuringMenuTracking = false

    @Published private var state: ViewerState = .idle
    @Published private var previewMode: PreviewMode = .fit
    @Published private(set) var inputSize: CGSize?
    @Published private(set) var tokenUnlockError: String?
    @Published private(set) var frameReportGeneration: UInt64 = 0
    @Published private(set) var isRemoteInputSuspendedByMenu = false

    static func makeForCurrentEnvironment() -> AppModel {
        #if DEBUG
        if HIDMIUITestSupport.isEnabled {
            return HIDMIUITestSupport.makeModel()
        }
        #endif
        return AppModel()
    }

    var session: AVCaptureSession {
        sessionController.session
    }

    var videoOutput: AVCaptureVideoDataOutput {
        sessionController.videoOutput
    }

    var devices: [CaptureDevice] {
        deviceStore.devices
    }

    var selectedDeviceID: CaptureDevice.ID? {
        deviceStore.selectedDeviceID
    }

    var usesAutomaticFormat: Bool {
        deviceStore.usesAutomaticFormat
    }

    var selectedFormatID: CaptureFormat.ID? {
        deviceStore.selectedFormatID
    }

    var currentFormats: [CaptureFormat] {
        deviceStore.currentFormats
    }

    var isFitToWindowMode: Bool {
        previewMode == .fit
    }

    var isOriginalInputMode: Bool {
        guard case .scaled(let scale) = previewMode else { return false }
        return abs(scale - 1.0) < 0.0001
    }

    var overlayMessage: String? {
        switch state {
        case .idle:
            String(localized: "overlay.preparing_input")
        case .requestingPermission:
            String(localized: "overlay.requesting_permission")
        case .permissionDenied:
            String(localized: "overlay.permission_denied")
        case .permissionRestricted:
            String(localized: "overlay.permission_restricted")
        case .noDevice:
            String(localized: "overlay.no_device")
        case .configuring:
            String(localized: "overlay.configuring_input")
        case .running:
            nil
        case .failed(let message):
            message
        }
    }

    var showsCameraPermissionSettingsAction: Bool {
        state == .permissionDenied
    }

    init(
        tokenStore: HIDMITokenStoreProtocol = LocalHIDMITokenStore(),
        authenticator: DeviceOwnerAuthenticating = LocalDeviceOwnerAuthenticator(),
        hidmi: HIDMIController? = nil,
        tokenManagementWindowController: TokenManagementWindowController? = nil,
        cameraPermissionManager: CameraPermissionManaging = SystemCameraPermissionManager(),
        startsVideoInputSetup: Bool = true,
        frameStabilizationInterval: TimeInterval = 0.25,
        formatSwitchConfirmationInterval: TimeInterval = 1.0,
        captureReconfigurationDebounceInterval: TimeInterval = 0.3,
        cameraPermissionRequestTimeoutInterval: TimeInterval = 5.0
    ) {
        self.tokenStore = tokenStore
        self.authenticator = authenticator
        self.hidmi = hidmi ?? HIDMIController(tokenStore: tokenStore)
        self.tokenManagementWindowController = tokenManagementWindowController ?? TokenManagementWindowController(tokenStore: tokenStore)
        self.cameraPermissionManager = cameraPermissionManager
        self.startsVideoInputSetup = startsVideoInputSetup
        self.frameStabilizationInterval = frameStabilizationInterval
        self.formatSwitchConfirmationInterval = formatSwitchConfirmationInterval
        self.captureReconfigurationDebounceInterval = captureReconfigurationDebounceInterval
        self.cameraPermissionRequestTimeoutInterval = cameraPermissionRequestTimeoutInterval
        deviceStore.objectWillChange
            .sink { [weak self] _ in
                self?.emitObjectWillChangeRespectingMenuTracking()
            }
            .store(in: &cancellables)

        deviceStore.onDevicesChanged = { [weak self] in
            self?.refreshDevices()
        }

        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                self?.releaseRemoteInput()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in
                self?.beginMenuTracking()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in
                self?.endMenuTracking()
            }
            .store(in: &cancellables)

        self.hidmi.objectWillChange
            .sink { [weak self] _ in
                self?.emitObjectWillChangeRespectingMenuTracking()
            }
            .store(in: &cancellables)

        self.hidmi.onConnectionLost = { [weak self] in
            self?.resetRemoteInputLocally()
        }

        installCaptureSessionObservers()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        installMenuTrackingDelegates()
        tokenStore.migrateLegacyTokensIfNeeded()
        hidmi.startDiscovery()
        guard startsVideoInputSetup else {
            state = .running
            return
        }

        state = .idle
        checkCameraPermissionAtStartup()
    }

    func attach(window: NSWindow) {
        windowController.attach(window)
        installMenuTrackingDelegates()
    }

    func refreshDevices() {
        deviceStore.refreshDevices(selectFirstIfNeeded: false)
        guard selectedDeviceID != nil else {
            stopPreview()
            state = devices.isEmpty ? .noDevice : .idle
            return
        }

        switch cameraPermissionManager.authorizationStatus() {
        case .authorized:
            configureSelectedDevice()
        case .notDetermined:
            stopPreview()
            state = devices.isEmpty ? .noDevice : .idle
        case .denied:
            stopPreview()
            state = .permissionDenied
        case .restricted:
            stopPreview()
            state = .permissionRestricted
        case .unknown:
            stopPreview()
            state = .failed(String(localized: "overlay.unknown_permission"))
        }
    }

    func selectDevice(_ id: CaptureDevice.ID) {
        guard devices.contains(where: { $0.id == id }) else { return }
        cancelPendingFormatSwitch()
        deviceStore.selectDevice(id)
        resetFrameObservationState(clearInputSize: true)
        beginPendingFormatSwitchForCurrentSelection(previousSelection: .automatic)
        requestCameraAccessIfNeeded()
    }

    func selectAutomaticFormat() {
        guard selectedDeviceID != nil else { return }
        beginPendingFormatSwitch(
            selection: .automatic,
            targetSignature: deviceStore.automaticFormat.map(CaptureFormatSignature.init(format:)),
            previousSelection: deviceStore.currentFormatSelection
        )
        deviceStore.selectAutomaticFormat(persist: false)
        requestCameraAccessIfNeeded()
    }

    func selectFormat(_ id: CaptureFormat.ID) {
        guard selectedDeviceID != nil,
              let format = deviceStore.format(withID: id) else { return }
        beginPendingFormatSwitch(
            selection: .explicit(id),
            targetSignature: CaptureFormatSignature(format: format),
            previousSelection: deviceStore.currentFormatSelection
        )
        deviceStore.selectFormat(id, persist: false)
        requestCameraAccessIfNeeded()
    }

    func fitToWindow() {
        previewMode = .fit
    }

    func zoomIn() {
        let next = currentScale * 1.25
        previewMode = .scaled(min(next, 8.0))
    }

    func zoomOut() {
        let next = currentScale / 1.25
        previewMode = .scaled(max(next, 0.125))
    }

    func showOriginalInput() {
        guard let inputSize else { return }
        previewMode = .scaled(1.0)
        windowController.resizeToOriginalInput(inputSize: inputSize)
    }

    func restoreInputSize() {
        showOriginalInput()
    }

    func updateActualVideoFrame(_ descriptor: CaptureFrameDescriptor) {
        let observation = CaptureFrameObservation(
            descriptor: descriptor,
            sequence: lastObservedFrameSequence + 1,
            reportGeneration: frameReportGeneration
        )
        updateActualVideoFrame(observation)
    }

    func updateActualVideoFrame(_ observation: CaptureFrameObservation) {
        let descriptor = observation.descriptor
        let size = descriptor.cgSize
        guard size.width > 0, size.height > 0 else { return }
        lastObservedFrameSequence = max(lastObservedFrameSequence, observation.sequence)

        if stableFrameObservation == nil {
            applyStableFrameObservation(observation)
            return
        }

        if descriptor == stableFrameObservation?.descriptor {
            pendingFrameDescriptorWorkItem?.cancel()
            pendingFrameDescriptorWorkItem = nil
            stableFrameObservation = observation
            confirmPendingFormatSwitchIfNeeded(with: observation)
            return
        }

        pendingFrameDescriptorWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.applyStableFrameObservation(observation)
            }
        }
        pendingFrameDescriptorWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + frameStabilizationInterval, execute: workItem)
    }

    func openCameraPrivacySettings() {
        cameraPermissionManager.openCameraPrivacySettings()
    }

    func startHIDMIDiscovery() {
        hidmi.startDiscovery()
    }

    func refreshHIDMIDevices() {
        hidmi.startDiscovery()
        hidmi.refreshDiscoveredDevices(source: .manual)
    }

    func connectHIDMI(_ id: HIDMIDiscoveredDevice.ID) {
        remoteInput = RemoteInputMapper()
        hidmi.connect(to: id)
    }

    func disconnectHIDMI() {
        releaseRemoteInput()
        hidmi.disconnect()
    }

    func releaseRemoteInput() {
        resetRemoteInputLocally()
        hidmi.releaseAll()
    }

    func prepareForTermination(timeout: TimeInterval = 0.5) {
        resetRemoteInputLocally()
        hidmi.prepareForTermination(timeout: timeout)
    }

    func sendCtrlAltDel() {
        hidmi.sendCtrlAltDel()
    }

    func beginMenuTracking() {
        menuTrackingDepth += 1
        guard !isRemoteInputSuspendedByMenu else { return }
        resetRemoteInputLocally()
        hidmi.releaseAllBestEffort(timeout: 0.3)
        isRemoteInputSuspendedByMenu = true
    }

    func endMenuTracking() {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
        guard menuTrackingDepth == 0 else { return }
        hasDeferredObjectWillChangeDuringMenuTracking = false
        isRemoteInputSuspendedByMenu = false
    }

    private func installMenuTrackingDelegates() {
        DispatchQueue.main.async { [weak self] in
            self?.installMenuTrackingDelegatesNow()
        }
    }

    fileprivate func installMenuTrackingDelegatesNow() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items where shouldTrackTopLevelMenu(item) {
            installMenuTrackingDelegate(in: item.submenu)
        }
    }

    private func shouldTrackTopLevelMenu(_ item: NSMenuItem) -> Bool {
        let trackedTitles: Set<String> = [
            String(localized: "menu.hid"),
            String(localized: "menu.view"),
            "HID",
            "Input",
            "输入",
            "View",
            "显示"
        ]
        return trackedTitles.contains(item.title)
    }

    private func installMenuTrackingDelegate(in menu: NSMenu?) {
        guard let menu else { return }
        let identifier = ObjectIdentifier(menu)
        if let existing = menu.delegate as? AppMenuTrackingDelegate {
            existing.model = self
        } else if menuTrackingDelegates[identifier] == nil {
            let delegate = AppMenuTrackingDelegate()
            delegate.model = self
            delegate.previous = menu.delegate
            menuTrackingDelegates[identifier] = delegate
            menu.delegate = delegate
        }
        for item in menu.items {
            installMenuTrackingDelegate(in: item.submenu)
        }
    }

    private func emitObjectWillChangeRespectingMenuTracking() {
        guard menuTrackingDepth == 0 else {
            hasDeferredObjectWillChangeDuringMenuTracking = true
            return
        }
        objectWillChange.send()
    }

    func showTokenManagement() {
        Task { @MainActor in
            if !tokenManagementWindowController.isVisible {
                let reason = String(localized: "token.auth.reason")
                guard let authenticationContext = await authenticator.authenticate(reason: reason) else {
                    tokenUnlockError = String(localized: "token.unlock.cancelled")
                    return
                }
                do {
                    try tokenStore.unlockSavedTokens(context: authenticationContext)
                    tokenUnlockError = nil
                } catch {
                    tokenUnlockError = error.localizedDescription
                    return
                }
            }
            tokenManagementWindowController.show()
        }
    }

    func handleRemoteInput(_ event: RemoteInputEvent) -> Bool {
        let sampleMonoUs = HIDMIMonotonic.microseconds()
        HIDMIInputTrace.log(
            "event_received",
            fields: [
                "connected": "\(hidmi.isConnected)",
                "event": event.traceName,
                "menu_suspended": "\(isRemoteInputSuspendedByMenu)",
                "sample_mono_us": "\(sampleMonoUs)"
            ]
        )
        guard hidmi.isConnected, !isRemoteInputSuspendedByMenu else {
            HIDMIInputTrace.log(
                "input_guard_drop",
                fields: [
                    "connected": "\(hidmi.isConnected)",
                    "event": event.traceName,
                    "menu_suspended": "\(isRemoteInputSuspendedByMenu)",
                    "reason": hidmi.isConnected ? "menu_suspended" : "not_connected",
                    "sample_mono_us": "\(sampleMonoUs)"
                ]
            )
            return false
        }

        let reports = remoteInput.map(event, preferAbsolute: hidmi.usesAbsolutePointer)
        guard !reports.isEmpty else {
            HIDMIInputTrace.log(
                "mapped_empty",
                fields: [
                    "event": event.traceName,
                    "prefer_absolute": "\(hidmi.usesAbsolutePointer)",
                    "reason": event.mappedEmptyReason(preferAbsolute: hidmi.usesAbsolutePointer),
                    "sample_mono_us": "\(sampleMonoUs)"
                ]
            )
            return false
        }
        let source: HIDMIInputReportSource
        if case .mouseMoved = event {
            source = .pointerMove
        } else {
            source = .reliable
        }
        hidmi.sendReports(reports, source: source, sampleMonoUs: sampleMonoUs)
        return true
    }

    func previewFrameSize(in availableSize: CGSize) -> CGSize {
        PreviewSizing.frameSize(
            mode: previewMode,
            inputSize: inputSize,
            availableSize: availableSize,
            backingScaleFactor: windowController.backingScaleFactor
        )
    }

    private var currentScale: CGFloat {
        if case .scaled(let scale) = previewMode {
            scale
        } else {
            1.0
        }
    }

    private func resetRemoteInputLocally() {
        LocalCursorState.shared.setHidden(false)
        _ = remoteInput.reset()
    }

    private func resetFrameObservationState(clearInputSize: Bool) {
        pendingFrameDescriptorWorkItem?.cancel()
        pendingFrameDescriptorWorkItem = nil
        stableFrameObservation = nil
        lastObservedFrameSequence = 0
        frameReportGeneration += 1
        if clearInputSize {
            inputSize = nil
        }
    }

    private func checkCameraPermissionAtStartup() {
        switch cameraPermissionManager.authorizationStatus() {
        case .authorized:
            startVideoDeviceMonitoring()
        case .notDetermined:
            requestCameraAccess { [weak self] in
                self?.startVideoDeviceMonitoring()
            }
        case .denied:
            stopPreview()
            state = .permissionDenied
        case .restricted:
            stopPreview()
            state = .permissionRestricted
        case .unknown:
            stopPreview()
            state = .failed(String(localized: "overlay.unknown_permission"))
        }
    }

    private func startVideoDeviceMonitoring() {
        deviceStore.startMonitoring()
        deviceStore.refreshDevices(selectFirstIfNeeded: false)
    }

    private func requestCameraAccessIfNeeded() {
        switch cameraPermissionManager.authorizationStatus() {
        case .authorized:
            deviceStore.startMonitoring()
            configureSelectedDevice()
        case .notDetermined:
            requestCameraAccess { [weak self] in
                self?.deviceStore.startMonitoring()
                self?.configureSelectedDevice()
            }
        case .denied:
            stopPreview()
            state = .permissionDenied
        case .restricted:
            stopPreview()
            state = .permissionRestricted
        case .unknown:
            stopPreview()
            state = .failed(String(localized: "overlay.unknown_permission"))
        }
    }

    private func requestCameraAccess(onGranted: @escaping @MainActor () -> Void) {
        state = .requestingPermission
        cameraPermissionRequestGeneration += 1
        let generation = cameraPermissionRequestGeneration
        pendingCameraPermissionWorkItem?.cancel()

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.cameraPermissionRequestGeneration == generation else { return }
            switch self.cameraPermissionManager.authorizationStatus() {
            case .authorized:
                onGranted()
            case .restricted:
                self.stopPreview()
                self.state = .permissionRestricted
            case .unknown:
                self.stopPreview()
                self.state = .failed(String(localized: "overlay.unknown_permission"))
            case .notDetermined, .denied:
                self.stopPreview()
                self.state = .permissionDenied
            }
        }
        pendingCameraPermissionWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + cameraPermissionRequestTimeoutInterval, execute: timeout)

        cameraPermissionManager.requestAccess { [weak self] granted in
            Task { @MainActor in
                guard let self, self.cameraPermissionRequestGeneration == generation else { return }
                self.pendingCameraPermissionWorkItem?.cancel()
                self.pendingCameraPermissionWorkItem = nil
                if granted {
                    onGranted()
                } else {
                    self.stopPreview()
                    self.state = .permissionDenied
                }
            }
        }
    }

    private func applyStableFrameObservation(_ observation: CaptureFrameObservation) {
        stableFrameObservation = observation
        let size = observation.descriptor.cgSize
        if inputSize != size {
            inputSize = size
        }
        confirmPendingFormatSwitchIfNeeded(with: observation)
    }

    private func beginPendingFormatSwitch(
        selection: CaptureFormatSelection,
        targetSignature: CaptureFormatSignature?,
        previousSelection: CaptureFormatSelection
    ) {
        pendingFormatTimeoutWorkItem?.cancel()
        pendingFormatTimeoutWorkItem = nil

        guard let selectedDeviceID else { return }
        pendingFormatSwitch = PendingCaptureFormatSwitch(
            deviceID: selectedDeviceID,
            selection: selection,
            targetSignature: targetSignature,
            previousSelection: previousSelection
        )
    }

    private func beginPendingFormatSwitchForCurrentSelection(previousSelection: CaptureFormatSelection) {
        guard selectedDeviceID != nil else { return }
        let selection = deviceStore.currentFormatSelection
        beginPendingFormatSwitch(
            selection: selection,
            targetSignature: targetSignature(for: selection),
            previousSelection: previousSelection
        )
    }

    private func targetSignature(for selection: CaptureFormatSelection) -> CaptureFormatSignature? {
        switch selection {
        case .automatic:
            deviceStore.automaticFormat.map(CaptureFormatSignature.init(format:))
        case .explicit(let id):
            deviceStore.format(withID: id).map(CaptureFormatSignature.init(format:))
        }
    }

    private func activatePendingFormatSwitchIfNeeded(
        generation: UInt64,
        activeFormatSignature: CaptureFormatSignature?
    ) {
        guard var pending = pendingFormatSwitch,
              !pending.isConfirmationTimerScheduled,
              pending.deviceID == selectedDeviceID,
              pending.configurationGeneration == generation else {
            return
        }

        pending.isConfirmationTimerScheduled = true
        pending.minimumConfirmationSequence = lastObservedFrameSequence
        pending.activeFormatSignature = activeFormatSignature
        pendingFormatSwitch = pending

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.handlePendingFormatSwitchTimeout(generation: generation)
            }
        }
        pendingFormatTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + formatSwitchConfirmationInterval, execute: workItem)
    }

    private func confirmPendingFormatSwitchIfNeeded(with observation: CaptureFrameObservation) {
        guard let pending = pendingFormatSwitch,
              pending.deviceID == selectedDeviceID,
              pending.matches(observation) else {
            return
        }

        pendingFormatTimeoutWorkItem?.cancel()
        pendingFormatTimeoutWorkItem = nil
        let applied = deviceStore.applyFormatSelection(pending.selection, persist: true)
        pendingFormatSwitch = nil
        if let generation = pending.configurationGeneration {
            captureConfigurationState = .running(generation)
        }
        runDeferredRecoveryIfNeeded()
        NSLog(
            "HIDMI capture format confirmed: selection=%@ actual=%dx%d applied=%@",
            String(describing: pending.selection),
            observation.descriptor.dimensions.width,
            observation.descriptor.dimensions.height,
            String(describing: applied)
        )
    }

    private func handlePendingFormatSwitchTimeout(generation: UInt64) {
        guard let pending = pendingFormatSwitch,
              pending.deviceID == selectedDeviceID,
              pending.configurationGeneration == generation else {
            return
        }

        let fallback = CaptureFormatFallbackPolicy.fallbackSelection(
            stableDimensions: stableFrameObservation?.descriptor.dimensions,
            previousSelection: pending.previousSelection,
            formats: currentFormats
        )
        rollbackPendingFormatSwitch(reason: "timeout", fallback: fallback)
    }

    private func rollbackPendingFormatSwitch(reason: String, fallback: CaptureFormatSelection? = nil) {
        guard let pending = pendingFormatSwitch else { return }

        pendingFormatTimeoutWorkItem?.cancel()
        pendingFormatTimeoutWorkItem = nil
        pendingFormatSwitch = nil

        let fallbackSelection = fallback ?? CaptureFormatFallbackPolicy.fallbackSelection(
            stableDimensions: stableFrameObservation?.descriptor.dimensions,
            previousSelection: pending.previousSelection,
            formats: currentFormats
        )
        let applied = deviceStore.applyFormatSelection(fallbackSelection, persist: true)
        NSLog(
            "HIDMI capture format rollback: target=%@ reason=%@ fallback=%@ timeout=%.2fs",
            String(describing: pending.selection),
            reason,
            String(describing: applied),
            formatSwitchConfirmationInterval
        )
        configureSelectedDevice()
    }

    private func cancelPendingFormatSwitch() {
        pendingFormatTimeoutWorkItem?.cancel()
        pendingFormatTimeoutWorkItem = nil
        pendingFormatSwitch = nil
    }

    private func makeCaptureConfigurationGeneration() -> UInt64 {
        nextConfigurationGeneration += 1
        return nextConfigurationGeneration
    }

    private func installCaptureSessionObservers() {
        let center = NotificationCenter.default

        center.publisher(for: AVCaptureSession.runtimeErrorNotification, object: sessionController.session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.handleCaptureStreamChange(
                    reason: "runtime error \(error?.localizedDescription ?? "unknown")",
                    kind: .sessionFailure
                )
            }
            .store(in: &cancellables)

        center.publisher(for: AVCaptureSession.wasInterruptedNotification, object: sessionController.session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleCaptureStreamChange(reason: "session interrupted", kind: .sessionFailure)
            }
            .store(in: &cancellables)

        center.publisher(for: AVCaptureSession.interruptionEndedNotification, object: sessionController.session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleCaptureStreamChange(reason: "session interruption ended", kind: .sessionFailure)
            }
            .store(in: &cancellables)

        center.publisher(for: AVCaptureInput.Port.formatDescriptionDidChangeNotification, object: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let port = notification.object as? AVCaptureInput.Port,
                      self.sessionController.owns(port: port) else {
                    return
                }
                self.handleCaptureStreamChange(reason: "input format description changed", kind: .formatDescription)
            }
            .store(in: &cancellables)
    }

    private func handleCaptureStreamChange(reason: String, kind: CaptureStreamChangeKind) {
        guard startsVideoInputSetup,
              cameraPermissionManager.authorizationStatus() == .authorized,
              selectedDeviceID != nil else {
            return
        }

        NSLog("HIDMI capture stream changed: %@", reason)
        guard CaptureStreamChangePolicy.requiresSessionReconfiguration(kind) else {
            return
        }

        if captureConfigurationState.isBusy {
            NSLog("HIDMI capture recovery skipped while configuration is already in progress")
            return
        }
        scheduleCaptureRecovery()
    }

    private func scheduleCaptureRecovery() {
        captureReconfigurationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.captureReconfigurationWorkItem = nil
                self.isCaptureRecoveryDirty = false
                let generation = self.makeCaptureConfigurationGeneration()
                self.captureConfigurationState = .recovering(generation)
                self.configureSelectedDevice(generation: generation)
            }
        }
        captureReconfigurationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + captureReconfigurationDebounceInterval, execute: workItem)
    }

    private func configureSelectedDevice() {
        configureSelectedDevice(generation: makeCaptureConfigurationGeneration())
    }

    private func configureSelectedDevice(generation: UInt64) {
        guard cameraPermissionManager.authorizationStatus() == .authorized else {
            return
        }

        guard let device = deviceStore.selectedDevice else {
            stopPreview()
            state = .noDevice
            return
        }

        state = .configuring
        captureConfigurationState = .configuring(generation)
        if var pending = pendingFormatSwitch, pending.deviceID == selectedDeviceID {
            pending.configurationGeneration = generation
            pendingFormatSwitch = pending
        }

        let selectedFormatID = deviceStore.usesAutomaticFormat ? nil : deviceStore.selectedFormatID
        sessionController.configure(
            device: device.device,
            formatID: selectedFormatID,
            preferAutomaticFormat: deviceStore.usesAutomaticFormat
        ) { [weak self] result in
            guard let self else { return }
            guard self.captureConfigurationState.generation == generation else {
                return
            }

            if let errorMessage = result.errorMessage {
                self.resetRemoteInputLocally()
                self.hidmi.releaseAllBestEffort(timeout: 0.3)
                if self.pendingFormatSwitch != nil {
                    self.rollbackPendingFormatSwitch(reason: errorMessage)
                } else {
                    self.inputSize = nil
                    self.state = .failed(errorMessage)
                    self.captureConfigurationState = .idle
                }
                return
            }

            if let dimensions = result.dimensions {
                self.inputSize = dimensions.cgSize
            } else {
                self.inputSize = nil
            }

            self.state = .running
            self.frameReportGeneration += 1
            if self.pendingFormatSwitch != nil {
                self.captureConfigurationState = .waitingForFrames(generation)
                self.activatePendingFormatSwitchIfNeeded(
                    generation: generation,
                    activeFormatSignature: result.activeFormatSignature
                )
            } else {
                self.captureConfigurationState = .running(generation)
                self.runDeferredRecoveryIfNeeded()
            }
        }
    }

    private func runDeferredRecoveryIfNeeded() {
        guard isCaptureRecoveryDirty else { return }
        isCaptureRecoveryDirty = false
        scheduleCaptureRecovery()
    }

    private func stopPreview() {
        resetRemoteInputLocally()
        hidmi.releaseAllBestEffort(timeout: 0.3)
        sessionController.stop()
        pendingFrameDescriptorWorkItem?.cancel()
        pendingFrameDescriptorWorkItem = nil
        pendingFormatTimeoutWorkItem?.cancel()
        pendingFormatTimeoutWorkItem = nil
        captureReconfigurationWorkItem?.cancel()
        captureReconfigurationWorkItem = nil
        pendingFormatSwitch = nil
        stableFrameObservation = nil
        captureConfigurationState = .idle
        isCaptureRecoveryDirty = false
        inputSize = nil
    }
}
