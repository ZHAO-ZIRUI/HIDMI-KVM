@preconcurrency import AVFoundation
import AppKit
import CoreImage
import MetalKit
import SwiftUI

struct VideoPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    let videoOutput: AVCaptureVideoDataOutput
    let frameReportGeneration: UInt64
    let inputSize: CGSize?
    let isAbsolutePointerActive: Bool
    let isRemoteInputEnabled: Bool
    let actualFrameHandler: (CaptureFrameObservation) -> Void
    let inputHandler: (RemoteInputEvent) -> Bool

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.captureSession = session
        view.videoOutput = videoOutput
        view.frameReportGeneration = frameReportGeneration
        view.inputSize = inputSize
        view.isAbsolutePointerActive = isAbsolutePointerActive
        view.isRemoteInputEnabled = isRemoteInputEnabled
        view.actualFrameHandler = actualFrameHandler
        view.inputHandler = inputHandler
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {
        nsView.captureSession = session
        nsView.videoOutput = videoOutput
        nsView.frameReportGeneration = frameReportGeneration
        nsView.inputSize = inputSize
        nsView.isAbsolutePointerActive = isAbsolutePointerActive
        nsView.isRemoteInputEnabled = isRemoteInputEnabled
        nsView.actualFrameHandler = actualFrameHandler
        nsView.inputHandler = inputHandler
        nsView.restoreRuntimeBindings()
    }
}

final class PreviewHostView: NSView {
    var inputHandler: ((RemoteInputEvent) -> Bool)?
    var actualFrameHandler: ((CaptureFrameObservation) -> Void)?
    var inputSize: CGSize?
    var captureSession: AVCaptureSession? {
        didSet {
            guard oldValue !== captureSession else { return }
            previewLayer?.session = captureSession
        }
    }
    var frameReportGeneration: UInt64 = 0 {
        didSet {
            frameOutputDelegate.reportGeneration = frameReportGeneration
        }
    }
    var isAbsolutePointerActive = false {
        didSet {
            if !isAbsolutePointerActive {
                LocalCursorState.shared.setHidden(false)
            }
        }
    }
    var isRemoteInputEnabled = true {
        didSet {
            if isRemoteInputEnabled {
                if !oldValue {
                    requestRemoteInputFocusIfPossible()
                }
            } else {
                LocalCursorState.shared.setHidden(false)
                if window?.firstResponder === self {
                    window?.makeFirstResponder(nil)
                }
            }
        }
    }
    var videoOutput: AVCaptureVideoDataOutput? {
        didSet {
            guard oldValue !== videoOutput else { return }
            oldValue?.setSampleBufferDelegate(nil, queue: nil)
            configureFrameOutput()
        }
    }

    private let frameQueue = DispatchQueue(label: "io.github.zhao-zirui.hidmi.video-frames")
    private let frameOutputDelegate: VideoFrameOutputDelegate
    private let metalRenderer: MetalVideoRenderer?
    private let metalView: MTKView?
    private var lastLoggedFrameDescriptor: CaptureFrameDescriptor?

    private var previewLayer: AVCaptureVideoPreviewLayer? {
        layer as? AVCaptureVideoPreviewLayer
    }

    var usesMetalBackendForTesting: Bool {
        metalView != nil
    }

    var usesPreviewLayerBackendForTesting: Bool {
        previewLayer != nil
    }

    override var acceptsFirstResponder: Bool {
        isRemoteInputEnabled
    }

    override init(frame frameRect: NSRect) {
        let metalDevice = MTLCreateSystemDefaultDevice()
        if let metalDevice, let renderer = MetalVideoRenderer(device: metalDevice) {
            let view = MTKView(frame: .zero, device: metalDevice)
            view.framebufferOnly = false
            view.isPaused = false
            view.enableSetNeedsDisplay = false
            view.autoResizeDrawable = false
            view.preferredFramesPerSecond = 60
            view.clearColor = MTLClearColorMake(0, 0, 0, 1)
            view.colorPixelFormat = .bgra8Unorm
            view.delegate = renderer
            renderer.view = view
            metalRenderer = renderer
            metalView = view
            frameOutputDelegate = VideoFrameOutputDelegate(renderer: renderer)
        } else {
            metalRenderer = nil
            metalView = nil
            frameOutputDelegate = VideoFrameOutputDelegate(renderer: nil)
        }

        super.init(frame: frameRect)
        setUpView()
    }

    required init?(coder: NSCoder) {
        let metalDevice = MTLCreateSystemDefaultDevice()
        if let metalDevice, let renderer = MetalVideoRenderer(device: metalDevice) {
            let view = MTKView(frame: .zero, device: metalDevice)
            view.framebufferOnly = false
            view.isPaused = false
            view.enableSetNeedsDisplay = false
            view.autoResizeDrawable = false
            view.preferredFramesPerSecond = 60
            view.clearColor = MTLClearColorMake(0, 0, 0, 1)
            view.colorPixelFormat = .bgra8Unorm
            view.delegate = renderer
            renderer.view = view
            metalRenderer = renderer
            metalView = view
            frameOutputDelegate = VideoFrameOutputDelegate(renderer: renderer)
        } else {
            metalRenderer = nil
            metalView = nil
            frameOutputDelegate = VideoFrameOutputDelegate(renderer: nil)
        }

        super.init(coder: coder)
        setUpView()
    }

    deinit {
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        Task { @MainActor in
            LocalCursorState.shared.setHidden(false)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        } else {
            window?.acceptsMouseMovedEvents = true
            restoreRuntimeBindings()
            DispatchQueue.main.async { [weak self] in
                self?.requestRemoteInputFocusIfPossible()
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updatePreviewLayerScale()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            LocalCursorState.shared.setHidden(false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        metalView?.frame = bounds
        updatePreviewLayerScale()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self))
    }

    override func mouseDown(with event: NSEvent) {
        guard isRemoteInputEnabled else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let absolute = absolutePointerPosition(for: event)
        updateLocalCursor(isInsideVideo: absolute != nil)
        if inputHandler?(.mouseDown(event, button: 1, absolute: absolute)) != true {
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isRemoteInputEnabled else {
            super.mouseUp(with: event)
            return
        }
        let absolute = absolutePointerPosition(for: event)
        updateLocalCursor(isInsideVideo: absolute != nil)
        if inputHandler?(.mouseUp(event, button: 1, absolute: absolute)) != true {
            super.mouseUp(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isRemoteInputEnabled else {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let absolute = absolutePointerPosition(for: event)
        updateLocalCursor(isInsideVideo: absolute != nil)
        if inputHandler?(.mouseDown(event, button: 2, absolute: absolute)) != true {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isRemoteInputEnabled else {
            super.rightMouseUp(with: event)
            return
        }
        let absolute = absolutePointerPosition(for: event)
        updateLocalCursor(isInsideVideo: absolute != nil)
        if inputHandler?(.mouseUp(event, button: 2, absolute: absolute)) != true {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard isRemoteInputEnabled else {
            super.otherMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let absolute = absolutePointerPosition(for: event)
        updateLocalCursor(isInsideVideo: absolute != nil)
        if inputHandler?(.mouseDown(event, button: 4, absolute: absolute)) != true {
            super.otherMouseDown(with: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard isRemoteInputEnabled else {
            super.otherMouseUp(with: event)
            return
        }
        let absolute = absolutePointerPosition(for: event)
        updateLocalCursor(isInsideVideo: absolute != nil)
        if inputHandler?(.mouseUp(event, button: 4, absolute: absolute)) != true {
            super.otherMouseUp(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard isRemoteInputEnabled else {
            super.mouseMoved(with: event)
            return
        }
        let absolute = absolutePointerPosition(for: event)
        updateLocalCursor(isInsideVideo: absolute != nil)
        if inputHandler?(.mouseMoved(event, scale: remoteMovementScale(), absolute: absolute)) != true {
            super.mouseMoved(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isRemoteInputEnabled else {
            super.mouseDragged(with: event)
            return
        }
        let absolute = absolutePointerPosition(for: event)
        updateLocalCursor(isInsideVideo: absolute != nil)
        _ = inputHandler?(.mouseMoved(event, scale: remoteMovementScale(), absolute: absolute))
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard isRemoteInputEnabled else {
            super.rightMouseDragged(with: event)
            return
        }
        let absolute = absolutePointerPosition(for: event)
        updateLocalCursor(isInsideVideo: absolute != nil)
        _ = inputHandler?(.mouseMoved(event, scale: remoteMovementScale(), absolute: absolute))
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard isRemoteInputEnabled else {
            super.otherMouseDragged(with: event)
            return
        }
        let absolute = absolutePointerPosition(for: event)
        updateLocalCursor(isInsideVideo: absolute != nil)
        _ = inputHandler?(.mouseMoved(event, scale: remoteMovementScale(), absolute: absolute))
    }

    override func mouseExited(with event: NSEvent) {
        LocalCursorState.shared.setHidden(false)
        super.mouseExited(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isRemoteInputEnabled else {
            super.scrollWheel(with: event)
            return
        }
        if inputHandler?(.scrollWheel(event)) != true {
            super.scrollWheel(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRemoteInputEnabled else {
            super.keyDown(with: event)
            return
        }
        if inputHandler?(.keyDown(event)) != true {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard isRemoteInputEnabled else {
            super.keyUp(with: event)
            return
        }
        if inputHandler?(.keyUp(event)) != true {
            super.keyUp(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRemoteInputEnabled else {
            super.flagsChanged(with: event)
            return
        }
        if inputHandler?(.flagsChanged(event)) != true {
            super.flagsChanged(with: event)
        }
    }

    func requestRemoteInputFocusIfPossible() {
        guard isRemoteInputEnabled, window != nil else { return }
        window?.makeFirstResponder(self)
    }

    func restoreRuntimeBindings() {
        configureFrameOutput()
        metalView?.isPaused = false
        metalView?.enableSetNeedsDisplay = false
        updatePreviewLayerScale()
        requestRemoteInputFocusIfPossible()
    }

    private func setUpView() {
        wantsLayer = true
        if metalView == nil {
            let layer = AVCaptureVideoPreviewLayer()
            layer.session = captureSession
            layer.backgroundColor = NSColor.black.cgColor
            layer.videoGravity = .resizeAspect
            layer.needsDisplayOnBoundsChange = true
            self.layer = layer
        } else {
            let layer = CALayer()
            layer.backgroundColor = NSColor.black.cgColor
            self.layer = layer
        }
        postsFrameChangedNotifications = false

        if let metalView {
            metalView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(metalView)
            NSLayoutConstraint.activate([
                metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
                metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
                metalView.topAnchor.constraint(equalTo: topAnchor),
                metalView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        } else {
            NSLog("HIDMI video warning: Metal is unavailable; falling back to AVCaptureVideoPreviewLayer")
        }

        frameOutputDelegate.onFrameObservation = { [weak self] observation in
            self?.handleFrameObservation(observation)
        }
        frameOutputDelegate.reportGeneration = frameReportGeneration
        updatePreviewLayerScale()
    }

    private func configureFrameOutput() {
        videoOutput?.setSampleBufferDelegate(frameOutputDelegate, queue: frameQueue)
    }

    private func handleFrameObservation(_ observation: CaptureFrameObservation) {
        let descriptor = observation.descriptor
        if lastLoggedFrameDescriptor != descriptor {
            NSLog(
                "HIDMI video frame: %dx%d %@",
                descriptor.dimensions.width,
                descriptor.dimensions.height,
                descriptor.pixelFormatName
            )
            lastLoggedFrameDescriptor = descriptor
        }
        actualFrameHandler?(observation)
    }

    private func remoteMovementScale() -> CGSize {
        guard let inputSize,
              inputSize.width > 0,
              inputSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return CGSize(width: 1, height: 1)
        }

        let fitScale = min(bounds.width / inputSize.width, bounds.height / inputSize.height)
        guard fitScale > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let movementScale = 1 / fitScale
        return CGSize(width: movementScale, height: movementScale)
    }

    private func absolutePointerPosition(for event: NSEvent) -> RemoteAbsolutePointer? {
        let videoRect = displayedVideoRect()
        guard videoRect.width > 0, videoRect.height > 0 else {
            return nil
        }

        let localPoint = convert(event.locationInWindow, from: nil)
        guard videoRect.contains(localPoint) else {
            return nil
        }

        let normalizedX = (localPoint.x - videoRect.minX) / videoRect.width
        let normalizedY = 1 - ((localPoint.y - videoRect.minY) / videoRect.height)
        return RemoteAbsolutePointer(
            x: Self.absoluteCoordinate(normalizedX),
            y: Self.absoluteCoordinate(normalizedY)
        )
    }

    private func displayedVideoRect() -> CGRect {
        guard let inputSize,
              inputSize.width > 0,
              inputSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return bounds
        }

        let fitScale = min(bounds.width / inputSize.width, bounds.height / inputSize.height)
        let width = inputSize.width * fitScale
        let height = inputSize.height * fitScale
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func updateLocalCursor(isInsideVideo: Bool) {
        LocalCursorState.shared.setHidden(
            isRemoteInputEnabled && isAbsolutePointerActive && isInsideVideo && window?.isKeyWindow == true
        )
    }

    private func updatePreviewLayerScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        previewLayer?.contentsScale = scale
        metalView?.layer?.contentsScale = scale
        metalView?.drawableSize = PreviewRenderGeometry.drawableSize(
            boundsSize: bounds.size,
            backingScaleFactor: scale
        )
    }

    private static func absoluteCoordinate(_ normalized: CGFloat) -> Int {
        let clamped = min(max(normalized, 0), 1)
        return Int((clamped * 65_535).rounded())
    }
}

final class VideoFrameOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onFrameObservation: ((CaptureFrameObservation) -> Void)?
    var reportGeneration: UInt64 {
        get {
            generationLock.lock()
            defer { generationLock.unlock() }
            return _reportGeneration
        }
        set {
            generationLock.lock()
            _reportGeneration = newValue
            generationLock.unlock()
        }
    }

    private let renderer: MetalVideoRenderer?
    private let descriptorReporter = CaptureFrameDescriptorReporter()
    private let generationLock = NSLock()
    private var _reportGeneration: UInt64 = 0

    init(renderer: MetalVideoRenderer?) {
        self.renderer = renderer
        super.init()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let descriptor = CaptureFrameDescriptor(
            dimensions: VideoDimensions(
                width: Int32(CVPixelBufferGetWidth(pixelBuffer)),
                height: Int32(CVPixelBufferGetHeight(pixelBuffer))
            ),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer)
        )

        if let observation = descriptorReporter.observationIfNeeded(
            descriptor,
            reportGeneration: reportGeneration
        ) {
            renderer?.resetForStreamChange()
            DispatchQueue.main.async { [weak self] in
                self?.onFrameObservation?(observation)
            }
        }
        renderer?.enqueue(pixelBuffer: pixelBuffer)
    }
}

final class CaptureFrameDescriptorReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastDescriptor: CaptureFrameDescriptor?
    private var lastReportGeneration: UInt64?
    private var nextSequence: UInt64 = 0

    func observationIfNeeded(
        _ descriptor: CaptureFrameDescriptor,
        reportGeneration: UInt64
    ) -> CaptureFrameObservation? {
        lock.lock()
        defer { lock.unlock() }

        guard lastDescriptor != descriptor || lastReportGeneration != reportGeneration else {
            return nil
        }

        nextSequence += 1
        lastDescriptor = descriptor
        lastReportGeneration = reportGeneration
        return CaptureFrameObservation(
            descriptor: descriptor,
            sequence: nextSequence,
            reportGeneration: reportGeneration
        )
    }

    func reset() {
        lock.lock()
        lastDescriptor = nil
        lastReportGeneration = nil
        lock.unlock()
    }
}

final class MetalVideoRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    weak var view: MTKView?

    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var needsCacheClear = false

    init?(device: MTLDevice) {
        guard let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = commandQueue
        self.context = CIContext(mtlDevice: device)
        super.init()
    }

    func enqueue(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        latestPixelBuffer = pixelBuffer
        lock.unlock()
    }

    func resetForStreamChange() {
        lock.lock()
        latestPixelBuffer = nil
        needsCacheClear = true
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock()
        let pixelBuffer = latestPixelBuffer
        let shouldClearCaches = needsCacheClear
        needsCacheClear = false
        lock.unlock()

        if shouldClearCaches {
            context.clearCaches()
        }

        guard let pixelBuffer else {
            return
        }

        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let destinationSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let destinationBounds = CGRect(origin: .zero, size: destinationSize)
        let image = Self.renderImage(
            pixelBuffer: pixelBuffer,
            destinationSize: destinationSize
        )

        context.render(
            image,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: destinationBounds,
            colorSpace: colorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    static func renderImage(
        pixelBuffer: CVPixelBuffer,
        destinationSize: CGSize
    ) -> CIImage {
        renderImage(
            sourceImage: CIImage(cvPixelBuffer: pixelBuffer),
            destinationSize: destinationSize
        )
    }

    static func renderImage(
        sourceImage: CIImage,
        destinationSize: CGSize
    ) -> CIImage {
        let source = sourceImage
        let sourceExtent = source.extent
        let targetRect = PreviewRenderGeometry.aspectFitRect(
            sourceSize: sourceExtent.size,
            destinationSize: destinationSize
        )
        let normalized = source.transformed(
            by: CGAffineTransform(translationX: -sourceExtent.minX, y: -sourceExtent.minY)
        )
        let scaled = normalized.transformed(
            by: CGAffineTransform(
                scaleX: targetRect.width / max(sourceExtent.width, 1),
                y: targetRect.height / max(sourceExtent.height, 1)
            )
        )
        let fitted = scaled.transformed(
            by: CGAffineTransform(translationX: targetRect.minX, y: targetRect.minY)
        )
        let destinationBounds = CGRect(origin: .zero, size: destinationSize)
        let background = CIImage(color: .black).cropped(to: destinationBounds)
        return fitted.composited(over: background).cropped(to: destinationBounds)
    }
}

@MainActor
final class LocalCursorState {
    static let shared = LocalCursorState()

    private var isHidden = false

    private init() {}

    func setHidden(_ hidden: Bool) {
        if hidden == isHidden {
            return
        }
        if hidden {
            NSCursor.hide()
        } else {
            NSCursor.unhide()
        }
        isHidden = hidden
    }
}
