@preconcurrency import AVFoundation
import Combine
import CoreMedia
import Foundation

struct VideoDimensions: Equatable, Sendable {
    let width: Int32
    let height: Int32

    var pixelCount: Int64 {
        Int64(width) * Int64(height)
    }

    var cgSize: CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}

struct CaptureFormat: Identifiable, Equatable, Sendable {
    let id: String
    let index: Int
    let dimensions: VideoDimensions
    let maxFrameRate: Double
    let mediaSubType: FourCharCode

    var resolutionTitle: String {
        "\(dimensions.width)x\(dimensions.height)"
    }

    var frameRateMillis: Int {
        Int((maxFrameRate * 1_000).rounded())
    }

    var frameRateTitle: String {
        let fps = maxFrameRate.rounded(.toNearestOrAwayFromZero)
        let fpsText = abs(maxFrameRate - fps) < 0.01
            ? String(Int(fps))
            : String(format: "%.2f", maxFrameRate)

        return "\(fpsText) fps"
    }

    var colorFormatTitle: String {
        fourCCString(mediaSubType)
    }

    var menuTitle: String {
        "\(resolutionTitle) @ \(frameRateTitle) \(colorFormatTitle)"
    }
}

struct CaptureFormatSignature: Codable, Equatable, Sendable {
    let width: Int32
    let height: Int32
    let frameRateMillis: Int
    let mediaSubType: FourCharCode

    init(width: Int32, height: Int32, maxFrameRate: Double, mediaSubType: FourCharCode) {
        self.width = width
        self.height = height
        frameRateMillis = Int((maxFrameRate * 1_000).rounded())
        self.mediaSubType = mediaSubType
    }

    init(format: CaptureFormat) {
        self.init(
            width: format.dimensions.width,
            height: format.dimensions.height,
            maxFrameRate: format.maxFrameRate,
            mediaSubType: format.mediaSubType
        )
    }

    init(avFormat format: AVCaptureDevice.Format) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let maxFrameRate = format.videoSupportedFrameRateRanges
            .map(\.maxFrameRate)
            .max() ?? 0
        self.init(
            width: dimensions.width,
            height: dimensions.height,
            maxFrameRate: maxFrameRate,
            mediaSubType: CMFormatDescriptionGetMediaSubType(format.formatDescription)
        )
    }

    func matches(_ format: CaptureFormat) -> Bool {
        width == format.dimensions.width
            && height == format.dimensions.height
            && frameRateMillis == Int((format.maxFrameRate * 1_000).rounded())
            && mediaSubType == format.mediaSubType
    }
}

enum CaptureFormatPreference: Codable, Equatable, Sendable {
    case automatic
    case explicit(CaptureFormatSignature)

    private enum CodingKeys: String, CodingKey {
        case kind
        case signature
    }

    private enum Kind: String, Codable {
        case automatic
        case explicit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .automatic:
            self = .automatic
        case .explicit:
            self = .explicit(try container.decode(CaptureFormatSignature.self, forKey: .signature))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode(Kind.automatic, forKey: .kind)
        case .explicit(let signature):
            try container.encode(Kind.explicit, forKey: .kind)
            try container.encode(signature, forKey: .signature)
        }
    }
}

enum CaptureFormatSelection: Equatable, Sendable {
    case automatic
    case explicit(CaptureFormat.ID)
}

enum CaptureFormatFallbackPolicy {
    static func matches(
        targetSignature: CaptureFormatSignature?,
        activeFormatSignature: CaptureFormatSignature?,
        descriptor: CaptureFrameDescriptor
    ) -> Bool {
        guard let targetSignature else {
            return true
        }

        guard targetSignature.width == descriptor.dimensions.width,
              targetSignature.height == descriptor.dimensions.height else {
            return false
        }

        return activeFormatSignature == targetSignature
    }

    static func fallbackSelection(
        stableDimensions: VideoDimensions?,
        previousSelection: CaptureFormatSelection,
        formats: [CaptureFormat]
    ) -> CaptureFormatSelection {
        if let stableDimensions,
           let current = formats.first(where: { $0.dimensions == stableDimensions }) {
            return .explicit(current.id)
        }

        return previousSelection
    }
}

protocol CaptureFormatPreferenceStoring {
    func preference(for deviceID: String) -> CaptureFormatPreference?
    func setPreference(_ preference: CaptureFormatPreference, for deviceID: String)
}

final class UserDefaultsCaptureFormatPreferenceStore: CaptureFormatPreferenceStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "CaptureFormatPreferences.v1") {
        self.defaults = defaults
        self.key = key
    }

    func preference(for deviceID: String) -> CaptureFormatPreference? {
        preferences()[deviceID]
    }

    func setPreference(_ preference: CaptureFormatPreference, for deviceID: String) {
        var storedPreferences = preferences()
        storedPreferences[deviceID] = preference

        guard let data = try? JSONEncoder().encode(storedPreferences) else { return }
        defaults.set(data, forKey: key)
    }

    private func preferences() -> [String: CaptureFormatPreference] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: CaptureFormatPreference].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

struct CaptureDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let modelID: String
    let device: AVCaptureDevice

    static func == (lhs: CaptureDevice, rhs: CaptureDevice) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class CaptureDeviceStore: ObservableObject {
    @Published private(set) var devices: [CaptureDevice] = []
    @Published private(set) var selectedDeviceID: CaptureDevice.ID?
    @Published private(set) var usesAutomaticFormat = true
    @Published private(set) var selectedFormatID: CaptureFormat.ID?
    @Published private(set) var currentFormats: [CaptureFormat] = []

    var onDevicesChanged: (() -> Void)?

    private let notificationObservers = NotificationObservers()
    private let formatPreferenceStore: CaptureFormatPreferenceStoring
    private var isMonitoring = false

    init(formatPreferenceStore: CaptureFormatPreferenceStoring = UserDefaultsCaptureFormatPreferenceStore()) {
        self.formatPreferenceStore = formatPreferenceStore
    }

    var selectedDevice: CaptureDevice? {
        guard let selectedDeviceID else { return nil }
        return devices.first { $0.id == selectedDeviceID }
    }

    var currentFormatSelection: CaptureFormatSelection {
        if !usesAutomaticFormat, let selectedFormatID {
            return .explicit(selectedFormatID)
        }
        return .automatic
    }

    var automaticFormat: CaptureFormat? {
        currentFormats.first
    }

    func format(withID id: CaptureFormat.ID) -> CaptureFormat? {
        currentFormats.first { $0.id == id }
    }

    func formatMatching(dimensions: VideoDimensions) -> CaptureFormat? {
        currentFormats.first { $0.dimensions == dimensions }
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let center = NotificationCenter.default
        let queue = OperationQueue.main

        notificationObservers.append(
            center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: queue) { [weak self] _ in
                Task { @MainActor in
                    self?.onDevicesChanged?()
                }
            }
        )

        notificationObservers.append(
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: queue) { [weak self] _ in
                Task { @MainActor in
                    self?.onDevicesChanged?()
                }
            }
        )
    }

    func refreshDevices(selectFirstIfNeeded: Bool = false) {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )

        let refreshedDevices = discovery.devices
            .filter(Self.shouldIncludeVideoDevice)
            .map { device in
                CaptureDevice(
                    id: device.uniqueID,
                    name: device.localizedName,
                    modelID: device.modelID,
                    device: device
                )
            }
            .sorted { lhs, rhs in
                if lhs.defaultSortPriority != rhs.defaultSortPriority {
                    return lhs.defaultSortPriority < rhs.defaultSortPriority
                }

                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        let previousSelection = selectedDeviceID
        devices = refreshedDevices

        if let previousSelection,
           refreshedDevices.contains(where: { $0.id == previousSelection }) {
            selectedDeviceID = previousSelection
            reloadCurrentFormats()
            applyStoredFormatPreference()
        } else if selectFirstIfNeeded {
            selectedDeviceID = refreshedDevices.first?.id
            reloadCurrentFormats()
            applyStoredFormatPreference()
        } else {
            selectedDeviceID = nil
            applyAutomaticFormat()
            currentFormats = []
        }
    }

    func selectDevice(_ id: CaptureDevice.ID) {
        guard devices.contains(where: { $0.id == id }) else { return }
        guard selectedDeviceID != id else { return }
        selectedDeviceID = id
        reloadCurrentFormats()
        applyStoredFormatPreference()
    }

    func selectAutomaticFormat(persist: Bool = true) {
        applyAutomaticFormat()
        if persist, let selectedDeviceID {
            formatPreferenceStore.setPreference(.automatic, for: selectedDeviceID)
        }
    }

    func selectFormat(_ id: CaptureFormat.ID, persist: Bool = true) {
        guard let format = currentFormats.first(where: { $0.id == id }) else { return }
        usesAutomaticFormat = false
        selectedFormatID = id
        if persist, let selectedDeviceID {
            formatPreferenceStore.setPreference(.explicit(CaptureFormatSignature(format: format)), for: selectedDeviceID)
        }
    }

    @discardableResult
    func applyFormatSelection(_ selection: CaptureFormatSelection, persist: Bool) -> CaptureFormatSelection {
        switch selection {
        case .automatic:
            selectAutomaticFormat(persist: persist)
            return .automatic
        case .explicit(let id):
            guard currentFormats.contains(where: { $0.id == id }) else {
                selectAutomaticFormat(persist: persist)
                return .automatic
            }
            selectFormat(id, persist: persist)
            return .explicit(id)
        }
    }

    func saveCurrentFormatPreference() {
        guard let selectedDeviceID else { return }

        switch currentFormatSelection {
        case .automatic:
            formatPreferenceStore.setPreference(.automatic, for: selectedDeviceID)
        case .explicit(let id):
            guard let format = format(withID: id) else {
                formatPreferenceStore.setPreference(.automatic, for: selectedDeviceID)
                return
            }
            formatPreferenceStore.setPreference(.explicit(CaptureFormatSignature(format: format)), for: selectedDeviceID)
        }
    }

    nonisolated static func resolvedFormatSelection(
        preference: CaptureFormatPreference?,
        formats: [CaptureFormat]
    ) -> CaptureFormatSelection {
        guard case .explicit(let signature) = preference,
              let format = formats.first(where: { signature.matches($0) }) else {
            return .automatic
        }
        return .explicit(format.id)
    }

    nonisolated static func formats(for device: AVCaptureDevice) -> [CaptureFormat] {
        device.formats.enumerated().compactMap { index, format in
            let description = format.formatDescription
            guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video else {
                return nil
            }

            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            guard dimensions.width > 0, dimensions.height > 0 else {
                return nil
            }

            let maxFrameRate = format.videoSupportedFrameRateRanges
                .map(\.maxFrameRate)
                .max() ?? 0

            guard maxFrameRate > 0 else {
                return nil
            }

            return CaptureFormat(
                id: "\(device.uniqueID)#\(index)",
                index: index,
                dimensions: VideoDimensions(width: dimensions.width, height: dimensions.height),
                maxFrameRate: maxFrameRate,
                mediaSubType: CMFormatDescriptionGetMediaSubType(description)
            )
        }
        .sorted { lhs, rhs in
            if lhs.dimensions.pixelCount != rhs.dimensions.pixelCount {
                return lhs.dimensions.pixelCount > rhs.dimensions.pixelCount
            }
            if lhs.maxFrameRate != rhs.maxFrameRate {
                return lhs.maxFrameRate > rhs.maxFrameRate
            }
            return lhs.menuTitle.localizedStandardCompare(rhs.menuTitle) == .orderedAscending
        }
    }


    nonisolated static func shouldExcludeVideoDeviceIdentity(
        name: String,
        modelID: String,
        uniqueID: String,
        isContinuityCamera: Bool
    ) -> Bool {
        if isContinuityCamera {
            return true
        }

        let identity = [name, modelID, uniqueID].joined(separator: " ")
        return identity.localizedCaseInsensitiveContains("iPhone")
            || identity.localizedCaseInsensitiveContains("Continuity Camera")
    }

    nonisolated private static func shouldIncludeVideoDevice(_ device: AVCaptureDevice) -> Bool {
        shouldExcludeVideoDeviceIdentity(
            name: device.localizedName,
            modelID: device.modelID,
            uniqueID: device.uniqueID,
            isContinuityCamera: device.isContinuityCamera || device.deviceType == .continuityCamera
        ) == false
    }

    private func reloadCurrentFormats() {
        guard let selectedDevice else {
            currentFormats = []
            return
        }
        currentFormats = Self.formats(for: selectedDevice.device)
    }

    private func applyStoredFormatPreference() {
        guard let selectedDeviceID else {
            applyAutomaticFormat()
            return
        }

        switch Self.resolvedFormatSelection(
            preference: formatPreferenceStore.preference(for: selectedDeviceID),
            formats: currentFormats
        ) {
        case .automatic:
            applyAutomaticFormat()
        case .explicit(let id):
            usesAutomaticFormat = false
            selectedFormatID = id
        }
    }

    private func applyAutomaticFormat() {
        usesAutomaticFormat = true
        selectedFormatID = nil
    }
}

private extension CaptureDevice {
    var defaultSortPriority: Int {
        if modelID.localizedCaseInsensitiveContains("UVC Camera") {
            return 0
        }

        return 1
    }
}

final class NotificationObservers: @unchecked Sendable {
    private var observers: [NSObjectProtocol] = []

    func append(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

func fourCCString(_ code: FourCharCode) -> String {
    let scalarValues = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff)
    ]

    let string = String(bytes: scalarValues, encoding: .macOSRoman) ?? ""
    return string.trimmingCharacters(in: .whitespacesAndNewlines)
}
