import Foundation
import CoreGraphics

enum PreviewMode: Equatable, Sendable {
    case fit
    case scaled(CGFloat)
}

enum PreviewSizing {
    static func frameSize(
        mode: PreviewMode,
        inputSize: CGSize?,
        availableSize: CGSize,
        backingScaleFactor: CGFloat
    ) -> CGSize {
        let scaleFactor = max(backingScaleFactor, 1)
        switch mode {
        case .fit:
            return pixelAligned(availableSize, backingScaleFactor: scaleFactor)
        case .scaled(let scale):
            guard let inputSize,
                  inputSize.width > 0,
                  inputSize.height > 0 else {
                return pixelAligned(availableSize, backingScaleFactor: scaleFactor)
            }
            return pixelAligned(
                CGSize(
                    width: max((inputSize.width / scaleFactor) * scale, 1),
                    height: max((inputSize.height / scaleFactor) * scale, 1)
                ),
                backingScaleFactor: scaleFactor
            )
        }
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
        visibleFrame: CGRect
    ) -> CGSize {
        let scaleFactor = max(backingScaleFactor, 1)
        let requestedSize = CGSize(
            width: inputSize.width / scaleFactor,
            height: inputSize.height / scaleFactor
        )
        let fitScale = min(
            1,
            visibleFrame.width / max(requestedSize.width, 1),
            visibleFrame.height / max(requestedSize.height, 1)
        )
        return PreviewSizing.pixelAligned(
            CGSize(
                width: requestedSize.width * fitScale,
                height: requestedSize.height * fitScale
            ),
            backingScaleFactor: scaleFactor
        )
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
