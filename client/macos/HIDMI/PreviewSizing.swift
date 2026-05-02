import Foundation
import CoreGraphics

enum PreviewMode: Equatable, Sendable {
    case fit
    case scaled(CGFloat)
}

enum PreviewLayout {
    static let nonFullScreenTopReservedHeight: CGFloat = 32

    static func topReservedHeight(isFullScreen: Bool) -> CGFloat {
        isFullScreen ? 0 : nonFullScreenTopReservedHeight
    }
}

enum PreviewSizing {
    static func frameSize(
        mode: PreviewMode,
        inputSize: CGSize?,
        availableSize: CGSize,
        backingScaleFactor: CGFloat
    ) -> CGSize {
        let scaleFactor = max(backingScaleFactor, 1)
        let availableSize = pixelAligned(
            CGSize(
                width: max(availableSize.width, 1),
                height: max(availableSize.height, 1)
            ),
            backingScaleFactor: scaleFactor
        )
        switch mode {
        case .fit:
            guard let inputSize,
                  inputSize.width > 0,
                  inputSize.height > 0 else {
                return availableSize
            }
            return aspectFitSize(
                sourceSize: inputSize,
                destinationSize: availableSize,
                backingScaleFactor: scaleFactor
            )
        case .scaled(let scale):
            guard let inputSize,
                  inputSize.width > 0,
                  inputSize.height > 0 else {
                return availableSize
            }
            let requestedSize = CGSize(
                width: max((inputSize.width / scaleFactor) * scale, 1),
                height: max((inputSize.height / scaleFactor) * scale, 1)
            )
            let fitScale = min(
                1,
                availableSize.width / requestedSize.width,
                availableSize.height / requestedSize.height
            )
            return pixelAligned(
                CGSize(width: requestedSize.width * fitScale, height: requestedSize.height * fitScale),
                backingScaleFactor: scaleFactor
            )
        }
    }

    static func aspectFitSize(
        sourceSize: CGSize,
        destinationSize: CGSize,
        backingScaleFactor: CGFloat
    ) -> CGSize {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              destinationSize.width > 0,
              destinationSize.height > 0 else {
            return pixelAligned(destinationSize, backingScaleFactor: backingScaleFactor)
        }

        let scale = min(destinationSize.width / sourceSize.width, destinationSize.height / sourceSize.height)
        return pixelAligned(
            CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale),
            backingScaleFactor: backingScaleFactor
        )
    }

    static func pixelAligned(_ size: CGSize, backingScaleFactor: CGFloat) -> CGSize {
        let scaleFactor = max(backingScaleFactor, 1)
        return CGSize(
            width: max((size.width * scaleFactor).rounded(.down) / scaleFactor, 1),
            height: max((size.height * scaleFactor).rounded(.down) / scaleFactor, 1)
        )
    }
}

enum PreviewRenderGeometry {
    static func drawableSize(boundsSize: CGSize, backingScaleFactor: CGFloat) -> CGSize {
        let scaleFactor = max(backingScaleFactor, 1)
        return CGSize(
            width: max((boundsSize.width * scaleFactor).rounded(.down), 1),
            height: max((boundsSize.height * scaleFactor).rounded(.down), 1)
        )
    }

    static func aspectFitRect(sourceSize: CGSize, destinationSize: CGSize) -> CGRect {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              destinationSize.width > 0,
              destinationSize.height > 0 else {
            return CGRect(origin: .zero, size: destinationSize)
        }

        let scale = min(destinationSize.width / sourceSize.width, destinationSize.height / sourceSize.height)
        let width = max((sourceSize.width * scale).rounded(.down), 1)
        let height = max((sourceSize.height * scale).rounded(.down), 1)
        return CGRect(
            x: ((destinationSize.width - width) / 2).rounded(.down),
            y: ((destinationSize.height - height) / 2).rounded(.down),
            width: width,
            height: height
        )
    }
}

enum WindowResizePlanning {
    static func originalInputContentSize(
        inputSize: CGSize,
        backingScaleFactor: CGFloat,
        visibleFrame: CGRect,
        topReservedHeight: CGFloat
    ) -> CGSize {
        let scaleFactor = max(backingScaleFactor, 1)
        let topReservedHeight = max(topReservedHeight, 0)
        let requestedSize = CGSize(
            width: inputSize.width / scaleFactor,
            height: inputSize.height / scaleFactor
        )
        let availableVideoHeight = max(visibleFrame.height - topReservedHeight, 1)
        let fitScale = min(
            1,
            visibleFrame.width / max(requestedSize.width, 1),
            availableVideoHeight / max(requestedSize.height, 1)
        )
        let videoSize = PreviewSizing.pixelAligned(
            CGSize(
                width: requestedSize.width * fitScale,
                height: requestedSize.height * fitScale
            ),
            backingScaleFactor: scaleFactor
        )
        return CGSize(width: videoSize.width, height: videoSize.height + topReservedHeight)
    }

    static func framePreservingTopLeft(
        oldFrame: CGRect,
        proposedFrameSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let topLeft = CGPoint(x: oldFrame.minX, y: oldFrame.maxY)
        var frame = CGRect(
            x: topLeft.x,
            y: topLeft.y - proposedFrameSize.height,
            width: proposedFrameSize.width,
            height: proposedFrameSize.height
        )

        if frame.maxX > visibleFrame.maxX {
            frame.origin.x = visibleFrame.maxX - frame.width
        }
        if frame.minX < visibleFrame.minX {
            frame.origin.x = visibleFrame.minX
        }
        if frame.minY < visibleFrame.minY {
            frame.origin.y = visibleFrame.minY
        }
        if frame.maxY > visibleFrame.maxY {
            frame.origin.y = visibleFrame.maxY - frame.height
        }
        return frame
    }
}
