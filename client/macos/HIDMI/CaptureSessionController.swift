@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

struct CaptureFrameDescriptor: Equatable, Sendable {
    let dimensions: VideoDimensions
    let pixelFormat: FourCharCode

    var cgSize: CGSize {
        dimensions.cgSize
    }

    var pixelFormatName: String {
        let name = fourCCString(pixelFormat)
        return name.isEmpty ? String(format: "0x%08X", pixelFormat) : name
    }
}

struct CaptureFrameObservation: Equatable, Sendable {
    let descriptor: CaptureFrameDescriptor
    let sequence: UInt64
    let reportGeneration: UInt64
}

struct CaptureSessionResult: Sendable {
    let dimensions: VideoDimensions?
    let activeFormatSignature: CaptureFormatSignature?
    let errorMessage: String?
}

final class CaptureSessionController: @unchecked Sendable {
    let session = AVCaptureSession()
    let videoOutput = AVCaptureVideoDataOutput()

    private let sessionQueue = DispatchQueue(label: "io.github.zhao-zirui.hidmi.capture-session")
    private let portSnapshotLock = NSLock()
    private var ownedPortIDs = Set<ObjectIdentifier>()

    func configure(
        device: AVCaptureDevice,
        formatID: CaptureFormat.ID?,
        preferAutomaticFormat: Bool,
        completion: @escaping @MainActor (CaptureSessionResult) -> Void
    ) {
        sessionQueue.async { [session, videoOutput] in
            do {
                let configuration = try Self.configureSession(
                    session,
                    videoOutput: videoOutput,
                    device: device,
                    formatID: formatID,
                    preferAutomaticFormat: preferAutomaticFormat
                )
                self.updateOwnedPorts(from: session)

                if !session.isRunning {
                    session.startRunning()
                }

                Task { @MainActor in
                    completion(CaptureSessionResult(
                        dimensions: configuration.dimensions,
                        activeFormatSignature: configuration.activeFormatSignature,
                        errorMessage: nil
                    ))
                }
            } catch {
                if session.isRunning {
                    session.stopRunning()
                }
                self.clearOwnedPorts()

                Task { @MainActor in
                    completion(CaptureSessionResult(
                        dimensions: nil,
                        activeFormatSignature: nil,
                        errorMessage: error.localizedDescription
                    ))
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }

            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            for output in session.outputs {
                session.removeOutput(output)
            }
            session.commitConfiguration()
            self.clearOwnedPorts()
        }
    }

    func owns(port: AVCaptureInput.Port) -> Bool {
        portSnapshotLock.lock()
        defer { portSnapshotLock.unlock() }
        return ownedPortIDs.contains(ObjectIdentifier(port))
    }

    private func updateOwnedPorts(from session: AVCaptureSession) {
        let portIDs = Set(session.inputs.flatMap(\.ports).map(ObjectIdentifier.init))
        portSnapshotLock.lock()
        ownedPortIDs = portIDs
        portSnapshotLock.unlock()
    }

    private func clearOwnedPorts() {
        portSnapshotLock.lock()
        ownedPortIDs = []
        portSnapshotLock.unlock()
    }

    private struct CaptureSessionConfiguration {
        let dimensions: VideoDimensions?
        let activeFormatSignature: CaptureFormatSignature?
    }

    private static func configureSession(
        _ session: AVCaptureSession,
        videoOutput: AVCaptureVideoDataOutput,
        device: AVCaptureDevice,
        formatID: CaptureFormat.ID?,
        preferAutomaticFormat: Bool
    ) throws -> CaptureSessionConfiguration {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        let format = selectedFormat(
            for: device,
            formatID: formatID,
            preferAutomaticFormat: preferAutomaticFormat
        )
        let requestedDimensions = format.map {
            let dimensions = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return VideoDimensions(width: dimensions.width, height: dimensions.height)
        }
        try apply(format: format, to: device)

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureSessionError.cannotAddInput(device.localizedName)
        }

        session.addInput(input)

        let appliedPreset = CaptureSessionPresetPolicy.applyPreferredPreset(
            to: session,
            requestedDimensions: requestedDimensions
        )
        try apply(format: format, to: device)

        configureVideoOutput(videoOutput)
        guard session.canAddOutput(videoOutput) else {
            throw CaptureSessionError.cannotAddOutput(device.localizedName)
        }
        session.addOutput(videoOutput)

        let activeDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let mediaSubType = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
        NSLog(
            "HIDMI capture configured: device=%@ selectedFormat=%@ active=%dx%d %@ sessionPreset=%@",
            device.localizedName,
            formatID ?? "automatic",
            activeDimensions.width,
            activeDimensions.height,
            fourCCString(mediaSubType),
            appliedPreset?.rawValue ?? "unchanged"
        )
        return CaptureSessionConfiguration(
            dimensions: VideoDimensions(width: activeDimensions.width, height: activeDimensions.height),
            activeFormatSignature: CaptureFormatSignature(avFormat: device.activeFormat)
        )
    }

    private static func selectedFormat(
        for device: AVCaptureDevice,
        formatID: CaptureFormat.ID?,
        preferAutomaticFormat: Bool
    ) -> AVCaptureDevice.Format? {
        let formats = CaptureDeviceStore.formats(for: device)

        if !preferAutomaticFormat,
           let formatID,
           let selected = formats.first(where: { $0.id == formatID }),
           device.formats.indices.contains(selected.index) {
            return device.formats[selected.index]
        }

        guard let automatic = formats.first,
              device.formats.indices.contains(automatic.index) else {
            return nil
        }

        return device.formats[automatic.index]
    }

    private static func apply(format: AVCaptureDevice.Format?, to device: AVCaptureDevice) throws {
        guard let format else { return }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.activeFormat = format

        if let preferredRange = format.videoSupportedFrameRateRanges.max(by: { lhs, rhs in
            lhs.maxFrameRate < rhs.maxFrameRate
        }) {
            let duration = preferredRange.minFrameDuration
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
    }

    private static func configureVideoOutput(_ output: AVCaptureVideoDataOutput) {
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = CaptureVideoOutputSettings.macOSDefaultVideoSettings()
    }
}

enum CaptureSessionPresetPolicy {
    static func preferredPresets(for dimensions: VideoDimensions?) -> [AVCaptureSession.Preset] {
        guard let dimensions else {
            return [.high]
        }

        if dimensions.width >= 3840 || dimensions.height >= 2160 {
            return [.hd4K3840x2160, .high]
        }
        if dimensions.width >= 1920 || dimensions.height >= 1080 {
            return [.hd1920x1080, .high]
        }
        if dimensions.width >= 1280 || dimensions.height >= 720 {
            return [.hd1280x720, .high]
        }
        if dimensions.width >= 640 || dimensions.height >= 480 {
            return [.vga640x480, .high]
        }
        return [.high]
    }

    static func applyPreferredPreset(
        to session: AVCaptureSession,
        requestedDimensions: VideoDimensions?
    ) -> AVCaptureSession.Preset? {
        for preset in preferredPresets(for: requestedDimensions) {
            if session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
                return preset
            }
        }

        NSLog("HIDMI capture warning: AVCaptureSession cannot use a resolution-specific preset")
        return nil
    }
}

enum CaptureVideoOutputSettings {
    static let preferredPixelFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_32BGRA
    ]

    static func videoSettings(supportedPixelFormats: [OSType]) -> [String: Any]? {
        guard let selected = preferredPixelFormats.first(where: { supportedPixelFormats.contains($0) }) else {
            return nil
        }
        return [kCVPixelBufferPixelFormatTypeKey as String: selected]
    }

    static func macOSDefaultVideoSettings() -> [String: Any]? {
        nil
    }
}

enum CaptureSessionError: LocalizedError {
    case cannotAddInput(String)
    case cannotAddOutput(String)

    var errorDescription: String? {
        switch self {
        case .cannotAddInput(let name):
            String(format: String(localized: "error.cannot_add_input_format"), name)
        case .cannotAddOutput(let name):
            String(format: String(localized: "error.cannot_add_output_format"), name)
        }
    }
}
