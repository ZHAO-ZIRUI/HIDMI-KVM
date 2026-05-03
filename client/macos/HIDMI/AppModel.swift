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

enum StatusBarDetailMode: String, CaseIterable, Equatable {
    case iconOnly
    case detailed
}

enum StatusBarVisibility: String, CaseIterable, Equatable {
    case hidden
    case windowOnly
    case fullScreenOnly
    case always

    func isVisible(isFullScreen: Bool) -> Bool {
        switch self {
        case .hidden:
            return false
        case .windowOnly:
            return !isFullScreen
        case .fullScreenOnly:
            return isFullScreen
        case .always:
            return true
        }
    }
}

enum StatusBarSignal: Equatable {
    case red
    case yellow
    case green
    case blinkingRed
}

struct HIDMIStatusBarItem: Equatable {
    let signal: StatusBarSignal
    let symbolName: String
    let title: String
    let detail: String?
}

struct HIDMIStatusBarSnapshot: Equatable {
    let capture: HIDMIStatusBarItem
    let kvm: HIDMIStatusBarItem
}

struct AppMenuCaptureDeviceItem: Identifiable, Equatable {
    let id: CaptureDevice.ID
    let title: String
    let isSelected: Bool
}

struct AppMenuCaptureFormatItem: Identifiable, Equatable {
    let id: CaptureFormat.ID
    let title: String
    let dimensions: VideoDimensions
    let frameRateMillis: Int
    let mediaSubType: FourCharCode
    let resolutionTitle: String
    let frameRateTitle: String
    let colorFormatTitle: String
    let isSelected: Bool
}

struct AppMenuInputDeviceItem: Identifiable, Equatable {
    let id: HIDMIDiscoveredDevice.ID
    let title: String
    let marker: HIDMIMenuSelectionMarker
    let actionTitle: String
    let isActionEnabled: Bool
    let details: [HIDMIMenuDeviceDetail]
}

enum StatusSelectorKVMConnectionState: Equatable {
    case available
    case connecting
    case connected
    case failed(String)
    case unavailable(String)
}

struct StatusSelectorKVMDeviceItem: Identifiable, Equatable {
    let id: HIDMIDiscoveredDevice.ID
    let title: String
    let marker: HIDMIMenuSelectionMarker
    let actionTitle: String
    let isActionEnabled: Bool
    let details: [HIDMIMenuDeviceDetail]
    let symbolName: String
    let connectionState: StatusSelectorKVMConnectionState
}

struct StatusSelectorSnapshot: Equatable {
    let statusBar: HIDMIStatusBarSnapshot
    let statusBarDetailMode: StatusBarDetailMode
    let captureDevices: [AppMenuCaptureDeviceItem]
    let isCaptureDeviceOptionsEnabled: Bool
    let usesAutomaticCaptureFormat: Bool
    let captureFormats: [AppMenuCaptureFormatItem]
    let kvmDevices: [StatusSelectorKVMDeviceItem]
    let isHIDMIDiscovering: Bool
    let isHIDMIConnecting: Bool
    let connectingHIDMIDeviceID: HIDMIDiscoveredDevice.ID?
    let kvmEndpointErrors: [HIDMIDiscoveredDevice.ID: String]
    let isHIDMIConnected: Bool

    static var empty: StatusSelectorSnapshot {
        StatusSelectorSnapshot(
            statusBar: HIDMIStatusBarSnapshot(
                capture: HIDMIStatusBarItem(
                    signal: .red,
                    symbolName: "video",
                    title: String(localized: "status.capture.unavailable"),
                    detail: nil
                ),
                kvm: HIDMIStatusBarItem(
                    signal: .red,
                    symbolName: "command",
                    title: String(localized: "status.kvm.not_found"),
                    detail: nil
                )
            ),
            statusBarDetailMode: .detailed,
            captureDevices: [],
            isCaptureDeviceOptionsEnabled: false,
            usesAutomaticCaptureFormat: true,
            captureFormats: [],
            kvmDevices: [],
            isHIDMIDiscovering: false,
            isHIDMIConnecting: false,
            connectingHIDMIDeviceID: nil,
            kvmEndpointErrors: [:],
            isHIDMIConnected: false
        )
    }
}

struct StatusSelectorCaptureResolutionOption: Identifiable, Equatable {
    let id: String
    let dimensions: VideoDimensions
    let title: String
}

struct StatusSelectorCaptureFrameRateOption: Identifiable, Equatable {
    let id: String
    let frameRateMillis: Int
    let title: String
}

struct StatusSelectorCaptureColorFormatOption: Identifiable, Equatable {
    let id: String
    let mediaSubType: FourCharCode
    let title: String
}

enum StatusSelectorCaptureFormatChoices {
    static func effectiveFormat(in snapshot: StatusSelectorSnapshot) -> AppMenuCaptureFormatItem? {
        snapshot.captureFormats.first(where: \.isSelected) ?? snapshot.captureFormats.first
    }

    static func resolutionOptions(in formats: [AppMenuCaptureFormatItem]) -> [StatusSelectorCaptureResolutionOption] {
        var seen = Set<String>()
        return formats.compactMap { format in
            let id = "\(format.dimensions.width)x\(format.dimensions.height)"
            guard seen.insert(id).inserted else { return nil }
            return StatusSelectorCaptureResolutionOption(
                id: id,
                dimensions: format.dimensions,
                title: format.resolutionTitle
            )
        }
    }

    static func frameRateOptions(
        in formats: [AppMenuCaptureFormatItem],
        resolution: VideoDimensions?
    ) -> [StatusSelectorCaptureFrameRateOption] {
        var seen = Set<Int>()
        return formats
            .filter { format in
                guard let resolution else { return true }
                return format.dimensions == resolution
            }
            .compactMap { format in
                guard seen.insert(format.frameRateMillis).inserted else { return nil }
                return StatusSelectorCaptureFrameRateOption(
                    id: "\(format.frameRateMillis)",
                    frameRateMillis: format.frameRateMillis,
                    title: format.frameRateTitle
                )
            }
    }

    static func colorFormatOptions(
        in formats: [AppMenuCaptureFormatItem],
        resolution: VideoDimensions?,
        frameRateMillis: Int?
    ) -> [StatusSelectorCaptureColorFormatOption] {
        var seen = Set<FourCharCode>()
        return formats
            .filter { format in
                if let resolution, format.dimensions != resolution {
                    return false
                }
                if let frameRateMillis, format.frameRateMillis != frameRateMillis {
                    return false
                }
                return true
            }
            .compactMap { format in
                guard seen.insert(format.mediaSubType).inserted else { return nil }
                return StatusSelectorCaptureColorFormatOption(
                    id: "\(format.mediaSubType)",
                    mediaSubType: format.mediaSubType,
                    title: format.colorFormatTitle
                )
            }
    }

    static func formatID(
        selectingResolution dimensions: VideoDimensions,
        in snapshot: StatusSelectorSnapshot
    ) -> CaptureFormat.ID? {
        let current = effectiveFormat(in: snapshot)
        let candidates = snapshot.captureFormats.filter { $0.dimensions == dimensions }
        return bestFormatID(
            from: candidates,
            preferredFrameRateMillis: current?.frameRateMillis,
            preferredMediaSubType: current?.mediaSubType
        )
    }

    static func formatID(
        selectingFrameRateMillis frameRateMillis: Int,
        in snapshot: StatusSelectorSnapshot
    ) -> CaptureFormat.ID? {
        let current = effectiveFormat(in: snapshot)
        let resolutionCandidates = snapshot.captureFormats.filter { format in
            guard let dimensions = current?.dimensions else { return true }
            return format.dimensions == dimensions
        }
        let candidates = resolutionCandidates.filter { $0.frameRateMillis == frameRateMillis }
        let fallbackCandidates = snapshot.captureFormats.filter { $0.frameRateMillis == frameRateMillis }
        return bestFormatID(
            from: candidates.isEmpty ? fallbackCandidates : candidates,
            preferredFrameRateMillis: frameRateMillis,
            preferredMediaSubType: current?.mediaSubType
        )
    }

    static func formatID(
        selectingColorFormat mediaSubType: FourCharCode,
        in snapshot: StatusSelectorSnapshot
    ) -> CaptureFormat.ID? {
        let current = effectiveFormat(in: snapshot)
        let exactScope = snapshot.captureFormats.filter { format in
            if let dimensions = current?.dimensions, format.dimensions != dimensions {
                return false
            }
            if let frameRateMillis = current?.frameRateMillis, format.frameRateMillis != frameRateMillis {
                return false
            }
            return format.mediaSubType == mediaSubType
        }
        let resolutionScope = snapshot.captureFormats.filter { format in
            guard let dimensions = current?.dimensions else { return false }
            return format.dimensions == dimensions && format.mediaSubType == mediaSubType
        }
        let fallbackScope = snapshot.captureFormats.filter { $0.mediaSubType == mediaSubType }
        return bestFormatID(
            from: exactScope.isEmpty ? (resolutionScope.isEmpty ? fallbackScope : resolutionScope) : exactScope,
            preferredFrameRateMillis: current?.frameRateMillis,
            preferredMediaSubType: mediaSubType
        )
    }

    private static func bestFormatID(
        from candidates: [AppMenuCaptureFormatItem],
        preferredFrameRateMillis: Int?,
        preferredMediaSubType: FourCharCode?
    ) -> CaptureFormat.ID? {
        guard !candidates.isEmpty else { return nil }
        if let preferredFrameRateMillis,
           let preferredMediaSubType,
           let exact = candidates.first(where: {
               $0.frameRateMillis == preferredFrameRateMillis && $0.mediaSubType == preferredMediaSubType
           }) {
            return exact.id
        }
        if let preferredFrameRateMillis,
           let frameRateMatch = candidates.first(where: { $0.frameRateMillis == preferredFrameRateMillis }) {
            return frameRateMatch.id
        }
        if let preferredMediaSubType,
           let colorMatch = candidates.first(where: { $0.mediaSubType == preferredMediaSubType }) {
            return colorMatch.id
        }
        return candidates.first?.id
    }
}

struct AppMenuSnapshot: Equatable {
    let statusBarDetailMode: StatusBarDetailMode
    let statusBarVisibility: StatusBarVisibility
    let canShowOriginalInput: Bool
    let isOriginalInputMode: Bool
    let isFitToWindowMode: Bool
    let captureDevices: [AppMenuCaptureDeviceItem]
    let isCaptureDeviceOptionsEnabled: Bool
    let usesAutomaticCaptureFormat: Bool
    let captureFormats: [AppMenuCaptureFormatItem]
    let inputDevices: [AppMenuInputDeviceItem]
    let isHIDMIDiscovering: Bool
    let isHIDMIConnected: Bool

    static let empty = AppMenuSnapshot(
        statusBarDetailMode: .detailed,
        statusBarVisibility: .always,
        canShowOriginalInput: false,
        isOriginalInputMode: false,
        isFitToWindowMode: true,
        captureDevices: [],
        isCaptureDeviceOptionsEnabled: false,
        usesAutomaticCaptureFormat: true,
        captureFormats: [],
        inputDevices: [],
        isHIDMIDiscovering: false,
        isHIDMIConnected: false
    )
}

@MainActor
final class AppMenuState {
    private(set) var appliedSnapshot: AppMenuSnapshot
    private(set) var pendingSnapshot: AppMenuSnapshot

    init(snapshot: AppMenuSnapshot = .empty) {
        appliedSnapshot = snapshot
        pendingSnapshot = snapshot
    }

    var snapshot: AppMenuSnapshot {
        appliedSnapshot
    }

    func stage(_ nextSnapshot: AppMenuSnapshot) {
        pendingSnapshot = nextSnapshot
    }

    func applyPendingSnapshot() {
        guard appliedSnapshot != pendingSnapshot else { return }
        appliedSnapshot = pendingSnapshot
    }

    func replaceImmediately(_ nextSnapshot: AppMenuSnapshot) {
        pendingSnapshot = nextSnapshot
        appliedSnapshot = nextSnapshot
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
    private let userDefaults: UserDefaults
    private let startsVideoInputSetup: Bool
    private let frameStabilizationInterval: TimeInterval
    private let formatSwitchConfirmationInterval: TimeInterval
    private let captureReconfigurationDebounceInterval: TimeInterval
    private let cameraPermissionRequestTimeoutInterval: TimeInterval
    let hidmi: HIDMIController
    let menuState = AppMenuState()
    private var cancellables = Set<AnyCancellable>()
    private var windowStateCancellables = Set<AnyCancellable>()
    private weak var observedWindow: NSWindow?
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
    private var selectorInteractionDepth = 0
    private var hasDeferredObjectWillChangeDuringMenuTracking = false
    private var hasDeferredMenuSnapshotApplyDuringTracking = false

    private var stateStorage: ViewerState = .idle
    private var previewModeStorage: PreviewMode = .fit
    private var inputSizeStorage: CGSize?
    private var tokenUnlockErrorStorage: String?
    private var frameReportGenerationStorage: UInt64 = 0
    private var isMainWindowFullScreenStorage = false
    private var statusBarDetailModeStorage: StatusBarDetailMode
    private var statusBarVisibilityStorage: StatusBarVisibility

    private var state: ViewerState {
        get { stateStorage }
        set {
            guard stateStorage != newValue else { return }
            emitObjectWillChangeRespectingMenuTracking()
            stateStorage = newValue
            stageMenuSnapshot()
        }
    }

    private var previewMode: PreviewMode {
        get { previewModeStorage }
        set {
            guard previewModeStorage != newValue else { return }
            emitObjectWillChangeRespectingMenuTracking()
            previewModeStorage = newValue
            stageMenuSnapshot()
        }
    }

    private(set) var inputSize: CGSize? {
        get { inputSizeStorage }
        set {
            guard inputSizeStorage != newValue else { return }
            emitObjectWillChangeRespectingMenuTracking()
            inputSizeStorage = newValue
            stageMenuSnapshot()
        }
    }

    private(set) var tokenUnlockError: String? {
        get { tokenUnlockErrorStorage }
        set {
            guard tokenUnlockErrorStorage != newValue else { return }
            emitObjectWillChangeRespectingMenuTracking()
            tokenUnlockErrorStorage = newValue
        }
    }

    private(set) var frameReportGeneration: UInt64 {
        get { frameReportGenerationStorage }
        set {
            guard frameReportGenerationStorage != newValue else { return }
            emitObjectWillChangeRespectingMenuTracking()
            frameReportGenerationStorage = newValue
        }
    }

    private(set) var isMainWindowFullScreen: Bool {
        get { isMainWindowFullScreenStorage }
        set {
            guard isMainWindowFullScreenStorage != newValue else { return }
            emitObjectWillChangeRespectingMenuTracking()
            isMainWindowFullScreenStorage = newValue
        }
    }

    private(set) var statusBarDetailMode: StatusBarDetailMode {
        get { statusBarDetailModeStorage }
        set {
            guard statusBarDetailModeStorage != newValue else { return }
            emitObjectWillChangeRespectingMenuTracking()
            statusBarDetailModeStorage = newValue
            stageMenuSnapshot()
        }
    }

    private(set) var statusBarVisibility: StatusBarVisibility {
        get { statusBarVisibilityStorage }
        set {
            guard statusBarVisibilityStorage != newValue else { return }
            emitObjectWillChangeRespectingMenuTracking()
            statusBarVisibilityStorage = newValue
            stageMenuSnapshot()
        }
    }
    private(set) var isRemoteInputSuspendedByMenu = false

    private static let statusBarDetailModeDefaultsKey = "StatusBarDetailMode"
    private static let statusBarVisibilityDefaultsKey = "StatusBarVisibility"

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

    var previewTopReservedHeight: CGFloat {
        PreviewLayout.topReservedHeight(isFullScreen: isMainWindowFullScreen)
    }

    var isStatusBarVisible: Bool {
        statusBarVisibility.isVisible(isFullScreen: isMainWindowFullScreen)
    }

    var statusBarSnapshot: HIDMIStatusBarSnapshot {
        HIDMIStatusBarSnapshot(
            capture: Self.captureStatusBarItem(
                state: state,
                hasCaptureDevices: !devices.isEmpty,
                selectedDeviceName: deviceStore.selectedDevice?.name,
                formatDescription: selectedCaptureFormatDescription,
                inputSize: inputSize
            ),
            kvm: kvmStatusBarItem()
        )
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
        cameraPermissionRequestTimeoutInterval: TimeInterval = 5.0,
        userDefaults: UserDefaults = .standard
    ) {
        self.tokenStore = tokenStore
        self.authenticator = authenticator
        self.hidmi = hidmi ?? HIDMIController(tokenStore: tokenStore)
        self.tokenManagementWindowController = tokenManagementWindowController ?? TokenManagementWindowController(tokenStore: tokenStore)
        self.cameraPermissionManager = cameraPermissionManager
        self.userDefaults = userDefaults
        self.startsVideoInputSetup = startsVideoInputSetup
        self.frameStabilizationInterval = frameStabilizationInterval
        self.formatSwitchConfirmationInterval = formatSwitchConfirmationInterval
        self.captureReconfigurationDebounceInterval = captureReconfigurationDebounceInterval
        self.cameraPermissionRequestTimeoutInterval = cameraPermissionRequestTimeoutInterval
        statusBarDetailModeStorage = Self.loadStatusBarDetailMode(from: userDefaults)
        statusBarVisibilityStorage = Self.loadStatusBarVisibility(from: userDefaults)
        deviceStore.objectWillChange
            .sink { [weak self] _ in
                self?.emitObjectWillChangeRespectingMenuTracking()
                self?.scheduleMenuSnapshotUpdate()
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

        self.hidmi.objectWillChange
            .sink { [weak self] _ in
                self?.emitObjectWillChangeRespectingMenuTracking()
                self?.scheduleMenuSnapshotUpdate()
            }
            .store(in: &cancellables)

        self.hidmi.onConnectionLost = { [weak self] in
            self?.resetRemoteInputLocally()
        }

        installCaptureSessionObservers()
        replaceMenuSnapshotImmediately()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
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
        observeWindowStateIfNeeded(window)
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

    func refreshCaptureMenuDevices() {
        refreshDevices()
        applyCurrentMenuSnapshotWhenSafe()
    }

    func refreshCaptureSelectorDevices(
        completion: (@MainActor @Sendable (StatusSelectorSnapshot) -> Void)? = nil
    ) {
        refreshDevices()
        completion?(makeStatusSelectorSnapshot())
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

    func setStatusBarDetailMode(_ mode: StatusBarDetailMode) {
        guard statusBarDetailMode != mode else { return }
        statusBarDetailMode = mode
        userDefaults.set(mode.rawValue, forKey: Self.statusBarDetailModeDefaultsKey)
    }

    func setStatusBarVisibility(_ visibility: StatusBarVisibility) {
        guard statusBarVisibility != visibility else { return }
        statusBarVisibility = visibility
        userDefaults.set(visibility.rawValue, forKey: Self.statusBarVisibilityDefaultsKey)
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

    func refreshHIDMIDevices(completion: (@MainActor @Sendable () -> Void)? = nil) {
        hidmi.startDiscovery()
        hidmi.refreshDiscoveredDevices(source: .manual, completion: completion)
    }

    func refreshHIDMIMenuDevices() {
        refreshHIDMIDevices { [weak self] in
            self?.applyCurrentMenuSnapshotWhenSafe()
        }
    }

    func refreshHIDMISelectorDevices(
        completion: (@MainActor @Sendable (StatusSelectorSnapshot) -> Void)? = nil
    ) {
        refreshHIDMIDevices { [weak self] in
            guard let self else { return }
            completion?(self.makeStatusSelectorSnapshot())
        }
    }

    func connectHIDMI(_ id: HIDMIDiscoveredDevice.ID, presentFailureWarning: Bool = false) {
        remoteInput = RemoteInputMapper()
        hidmi.connect(to: id, presentFailureWarning: presentFailureWarning)
    }

    func disconnectHIDMI() {
        releaseRemoteInput()
        hidmi.disconnect()
    }

    func cancelHIDMIConnectionAttempt() {
        hidmi.cancelConnectionAttempt()
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

    func beginMenuTracking(suspendsRemoteInput: Bool = true) {
        menuTrackingDepth += 1
        guard suspendsRemoteInput, !isRemoteInputSuspendedByMenu else { return }
        resetRemoteInputLocally()
        hidmi.releaseAllBestEffort(timeout: 0.3)
        isRemoteInputSuspendedByMenu = true
    }

    func endMenuTracking() {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
        guard menuTrackingDepth == 0 else { return }
        let shouldApplyDeferredMenuSnapshot = hasDeferredMenuSnapshotApplyDuringTracking
        hasDeferredMenuSnapshotApplyDuringTracking = false
        let shouldEmitDeferredObjectWillChange = hasDeferredObjectWillChangeDuringMenuTracking
        hasDeferredObjectWillChangeDuringMenuTracking = false
        if selectorInteractionDepth == 0 {
            isRemoteInputSuspendedByMenu = false
        }
        if shouldApplyDeferredMenuSnapshot {
            DispatchQueue.main.async { [weak self] in
                self?.applyPendingMenuSnapshotWhenSafe()
            }
        }
        if shouldEmitDeferredObjectWillChange {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    func beginSelectorInteraction() {
        selectorInteractionDepth += 1
        guard !isRemoteInputSuspendedByMenu else { return }
        resetRemoteInputLocally()
        hidmi.releaseAllBestEffort(timeout: 0.3)
        isRemoteInputSuspendedByMenu = true
    }

    func endSelectorInteraction() {
        selectorInteractionDepth = max(0, selectorInteractionDepth - 1)
        guard selectorInteractionDepth == 0, menuTrackingDepth == 0 else { return }
        isRemoteInputSuspendedByMenu = false
    }

    func stageCurrentMenuSnapshot() {
        menuState.stage(makeMenuSnapshot())
    }

    func applyPendingMenuSnapshotWhenSafe() {
        guard menuTrackingDepth == 0 else {
            hasDeferredMenuSnapshotApplyDuringTracking = true
            return
        }
        menuState.applyPendingSnapshot()
    }

    func applyCurrentMenuSnapshotWhenSafe() {
        let snapshot = makeMenuSnapshot()
        guard menuTrackingDepth == 0 else {
            menuState.stage(snapshot)
            hasDeferredMenuSnapshotApplyDuringTracking = true
            return
        }
        menuState.replaceImmediately(snapshot)
    }

    func applyPendingMenuSnapshot() {
        applyPendingMenuSnapshotWhenSafe()
    }

    func applyCurrentMenuSnapshot() {
        applyCurrentMenuSnapshotWhenSafe()
    }

    func makeStatusSelectorSnapshot() -> StatusSelectorSnapshot {
        let connectingDeviceID = hidmi.connectingDeviceID
        let isConnecting = connectingDeviceID != nil
        let endpointErrors = hidmi.endpointConnectionFailuresByDeviceID

        return StatusSelectorSnapshot(
            statusBar: statusBarSnapshot,
            statusBarDetailMode: statusBarDetailMode,
            captureDevices: devices.map { device in
                AppMenuCaptureDeviceItem(
                    id: device.id,
                    title: device.name,
                    isSelected: selectedDeviceID == device.id
                )
            },
            isCaptureDeviceOptionsEnabled: selectedDeviceID != nil,
            usesAutomaticCaptureFormat: usesAutomaticFormat,
            captureFormats: currentFormats.map { format in
                AppMenuCaptureFormatItem(
                    id: format.id,
                    title: format.menuTitle,
                    dimensions: format.dimensions,
                    frameRateMillis: format.frameRateMillis,
                    mediaSubType: format.mediaSubType,
                    resolutionTitle: format.resolutionTitle,
                    frameRateTitle: format.frameRateTitle,
                    colorFormatTitle: format.colorFormatTitle,
                    isSelected: !usesAutomaticFormat && selectedFormatID == format.id
                )
            },
            kvmDevices: hidmi.menuDeviceStates.map { state in
                let connectionState = kvmSelectorConnectionState(
                    for: state,
                    connectingDeviceID: connectingDeviceID,
                    endpointErrors: endpointErrors
                )
                return StatusSelectorKVMDeviceItem(
                    id: state.id,
                    title: state.device.menuTitle,
                    marker: state.marker,
                    actionTitle: kvmActionTitle(for: connectionState),
                    isActionEnabled: kvmIsActionEnabled(for: connectionState, device: state.device),
                    details: state.menuDetails,
                    symbolName: transportSymbolName(for: state.device),
                    connectionState: connectionState
                )
            },
            isHIDMIDiscovering: hidmi.isDiscovering,
            isHIDMIConnecting: isConnecting,
            connectingHIDMIDeviceID: connectingDeviceID,
            kvmEndpointErrors: endpointErrors,
            isHIDMIConnected: hidmi.isConnected
        )
    }

    private func emitObjectWillChangeRespectingMenuTracking() {
        guard menuTrackingDepth == 0 else {
            hasDeferredObjectWillChangeDuringMenuTracking = true
            return
        }
        objectWillChange.send()
    }

    private func scheduleMenuSnapshotUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.stageMenuSnapshot()
        }
    }

    private func stageMenuSnapshot() {
        menuState.stage(makeMenuSnapshot())
    }

    private func replaceMenuSnapshotImmediately() {
        menuState.replaceImmediately(makeMenuSnapshot())
    }

    private func makeMenuSnapshot() -> AppMenuSnapshot {
        let isConnecting = hidmi.connectingDeviceID != nil

        return AppMenuSnapshot(
            statusBarDetailMode: statusBarDetailMode,
            statusBarVisibility: statusBarVisibility,
            canShowOriginalInput: inputSize != nil,
            isOriginalInputMode: isOriginalInputMode,
            isFitToWindowMode: isFitToWindowMode,
            captureDevices: devices.map { device in
                AppMenuCaptureDeviceItem(
                    id: device.id,
                    title: device.name,
                    isSelected: selectedDeviceID == device.id
                )
            },
            isCaptureDeviceOptionsEnabled: selectedDeviceID != nil,
            usesAutomaticCaptureFormat: usesAutomaticFormat,
            captureFormats: currentFormats.map { format in
                AppMenuCaptureFormatItem(
                    id: format.id,
                    title: format.menuTitle,
                    dimensions: format.dimensions,
                    frameRateMillis: format.frameRateMillis,
                    mediaSubType: format.mediaSubType,
                    resolutionTitle: format.resolutionTitle,
                    frameRateTitle: format.frameRateTitle,
                    colorFormatTitle: format.colorFormatTitle,
                    isSelected: !usesAutomaticFormat && selectedFormatID == format.id
                )
            },
            inputDevices: hidmi.menuDeviceStates.map { state in
                let actionTitle = state.marker == .connected
                    ? String(localized: "hid.device.disconnect_this_device")
                    : String(localized: "hid.device.connect_this_device")
                return AppMenuInputDeviceItem(
                    id: state.id,
                    title: state.device.menuTitle,
                    marker: state.marker,
                    actionTitle: actionTitle,
                    isActionEnabled: state.marker == .connected || (!isConnecting && state.device.isConnectable),
                    details: state.menuDetails
                )
            },
            isHIDMIDiscovering: hidmi.isDiscovering,
            isHIDMIConnected: hidmi.isConnected
        )
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

    static func captureStatusBarItem(
        state: ViewerState,
        hasCaptureDevices: Bool,
        selectedDeviceName: String?,
        formatDescription: String?,
        inputSize: CGSize?
    ) -> HIDMIStatusBarItem {
        guard hasCaptureDevices else {
            return HIDMIStatusBarItem(
                signal: .red,
                symbolName: "video",
                title: String(localized: "status.capture.unavailable"),
                detail: nil
            )
        }

        switch state {
        case .running:
            let detail = captureStatusBarDetail(
                deviceName: selectedDeviceName,
                formatDescription: formatDescription,
                inputSize: inputSize
            )
            return HIDMIStatusBarItem(
                signal: .green,
                symbolName: "video",
                title: String(localized: "status.capture.showing"),
                detail: detail
            )
        case .configuring, .requestingPermission:
            return HIDMIStatusBarItem(
                signal: .yellow,
                symbolName: "video",
                title: String(localized: "status.capture.configuring"),
                detail: selectedDeviceName.map {
                    String(format: String(localized: "status.capture.detail_device_only"), $0)
                }
            )
        case .idle:
            return HIDMIStatusBarItem(
                signal: .yellow,
                symbolName: "video",
                title: String(localized: "status.capture.choose"),
                detail: nil
            )
        case .permissionDenied, .permissionRestricted, .noDevice, .failed:
            return HIDMIStatusBarItem(
                signal: .red,
                symbolName: "video",
                title: String(localized: "status.capture.unavailable"),
                detail: nil
            )
        }
    }

    private var selectedCaptureFormatDescription: String? {
        if !usesAutomaticFormat,
           let selectedFormatID,
           let format = deviceStore.format(withID: selectedFormatID) {
            return format.menuTitle
        }

        if let inputSize,
           let matchingFormat = deviceStore.formatMatching(
            dimensions: VideoDimensions(
                width: Int32(inputSize.width.rounded()),
                height: Int32(inputSize.height.rounded())
            )
           ) {
            return matchingFormat.menuTitle
        }

        if let automaticFormat = deviceStore.automaticFormat {
            return automaticFormat.menuTitle
        }

        if let inputSize {
            return String(
                format: String(localized: "status.capture.dimensions"),
                Int(inputSize.width.rounded()),
                Int(inputSize.height.rounded())
            )
        }

        return nil
    }

    private static func captureStatusBarDetail(
        deviceName: String?,
        formatDescription: String?,
        inputSize: CGSize?
    ) -> String? {
        let resolvedFormat = formatDescription ?? inputSize.map {
            String(
                format: String(localized: "status.capture.dimensions"),
                Int($0.width.rounded()),
                Int($0.height.rounded())
            )
        }
        guard let deviceName else { return resolvedFormat }
        guard let resolvedFormat else {
            return String(format: String(localized: "status.capture.detail_device_only"), deviceName)
        }
        return String(format: String(localized: "status.capture.detail"), deviceName, resolvedFormat)
    }

    private func kvmStatusBarItem() -> HIDMIStatusBarItem {
        let device = preferredHIDMIStatusDevice()
        if case .failed = hidmi.status {
            return HIDMIStatusBarItem(
                signal: .blinkingRed,
                symbolName: Self.kvmDefaultSymbolName,
                title: String(localized: "status.kvm.failed"),
                detail: device.map(kvmStatusBarDetail)
            )
        }

        if hidmi.connectedDeviceID != nil {
            return HIDMIStatusBarItem(
                signal: .green,
                symbolName: transportSymbolName(for: device),
                title: String(localized: "status.kvm.connected"),
                detail: device.map(kvmStatusBarDetail)
            )
        }

        if !hidmi.discoveredDevices.isEmpty {
            return HIDMIStatusBarItem(
                signal: .yellow,
                symbolName: Self.kvmDefaultSymbolName,
                title: String(localized: "status.kvm.available"),
                detail: device.map(kvmStatusBarDetail)
            )
        }

        return HIDMIStatusBarItem(
            signal: .red,
            symbolName: Self.kvmDefaultSymbolName,
            title: String(localized: "status.kvm.not_found"),
            detail: nil
        )
    }

    private func preferredHIDMIStatusDevice() -> HIDMIDiscoveredDevice? {
        if let connectedDeviceID = hidmi.connectedDeviceID,
           let device = hidmi.discoveredDevices.first(where: { $0.id == connectedDeviceID }) {
            return device
        }
        if let selectedDeviceID = hidmi.selectedDeviceID,
           let device = hidmi.discoveredDevices.first(where: { $0.id == selectedDeviceID }) {
            return device
        }
        return hidmi.discoveredDevices.first
    }

    private static let kvmDefaultSymbolName = "command"

    private func transportSymbolName(for device: HIDMIDiscoveredDevice?) -> String {
        switch device?.transport {
        case .wlan:
            return "wifi"
        case .ethernet, .usb, nil:
            return "cable.connector"
        }
    }

    private func kvmSelectorConnectionState(
        for state: HIDMIMenuDeviceState,
        connectingDeviceID: HIDMIDiscoveredDevice.ID?,
        endpointErrors: [HIDMIDiscoveredDevice.ID: String]
    ) -> StatusSelectorKVMConnectionState {
        if state.marker == .connected {
            return .connected
        }
        if connectingDeviceID == state.id {
            return .connecting
        }
        guard state.device.isConnectable else {
            return .unavailable(state.device.availability.userFacingConnectionDescription)
        }
        if let error = endpointErrors[state.id] {
            return .failed(error)
        }
        return .available
    }

    private func kvmActionTitle(for state: StatusSelectorKVMConnectionState) -> String {
        switch state {
        case .connected:
            return String(localized: "hid.device.disconnect_this_device")
        case .connecting:
            return String(localized: "hid.device.cancel_connection")
        case .failed:
            return String(localized: "hid.device.retry_connection")
        case .available, .unavailable:
            return String(localized: "hid.device.connect_this_device")
        }
    }

    private func kvmIsActionEnabled(
        for state: StatusSelectorKVMConnectionState,
        device: HIDMIDiscoveredDevice
    ) -> Bool {
        switch state {
        case .connected, .connecting:
            return true
        case .available, .failed:
            return device.isConnectable
        case .unavailable:
            return false
        }
    }

    private func kvmStatusBarDetail(for device: HIDMIDiscoveredDevice) -> String {
        String(
            format: String(localized: "status.kvm.detail"),
            device.displayName,
            device.connectionAddressSummary
        )
    }

    private static func loadStatusBarDetailMode(from defaults: UserDefaults) -> StatusBarDetailMode {
        guard let value = defaults.string(forKey: statusBarDetailModeDefaultsKey),
              let mode = StatusBarDetailMode(rawValue: value) else {
            return .detailed
        }
        return mode
    }

    private static func loadStatusBarVisibility(from defaults: UserDefaults) -> StatusBarVisibility {
        guard let value = defaults.string(forKey: statusBarVisibilityDefaultsKey),
              let visibility = StatusBarVisibility(rawValue: value) else {
            return .always
        }
        return visibility
    }

    private func resetRemoteInputLocally() {
        LocalCursorState.shared.setHidden(false)
        _ = remoteInput.reset()
    }

    private func observeWindowStateIfNeeded(_ window: NSWindow) {
        guard observedWindow !== window else {
            updateMainWindowFullScreenState(from: window)
            return
        }

        observedWindow = window
        windowStateCancellables.removeAll()
        updateMainWindowFullScreenState(from: window)

        NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification, object: window)
            .sink { [weak self, weak window] _ in
                guard let window else { return }
                self?.updateMainWindowFullScreenState(from: window)
            }
            .store(in: &windowStateCancellables)

        NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification, object: window)
            .sink { [weak self, weak window] _ in
                guard let window else { return }
                self?.updateMainWindowFullScreenState(from: window)
            }
            .store(in: &windowStateCancellables)
    }

    private func updateMainWindowFullScreenState(from window: NSWindow) {
        let nextValue = window.styleMask.contains(.fullScreen)
        guard isMainWindowFullScreen != nextValue else { return }
        isMainWindowFullScreen = nextValue
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
