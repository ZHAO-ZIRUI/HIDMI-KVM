import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            GeometryReader { proxy in
                let topReservedHeight = model.previewTopReservedHeight
                let videoAvailableSize = CGSize(
                    width: proxy.size.width,
                    height: max(proxy.size.height - topReservedHeight, 1)
                )
                let frameSize = model.previewFrameSize(in: videoAvailableSize)

                VStack(spacing: 0) {
                    Color.black
                        .frame(height: topReservedHeight)

                    ZStack {
                        VideoPreviewView(
                            session: model.session,
                            videoOutput: model.videoOutput,
                            frameReportGeneration: model.frameReportGeneration,
                            inputSize: model.inputSize,
                            isAbsolutePointerActive: model.hidmi.isConnected && model.hidmi.usesAbsolutePointer,
                            isRemoteInputEnabled: model.hidmi.isConnected && !model.isRemoteInputSuspendedByMenu,
                            actualFrameHandler: model.updateActualVideoFrame,
                            inputHandler: model.handleRemoteInput
                        )
                        .frame(width: frameSize.width, height: frameSize.height)
                        .clipped()
                    }
                    .frame(width: videoAvailableSize.width, height: videoAvailableSize.height)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .ignoresSafeArea()

            if let message = model.overlayMessage {
                VStack(spacing: 10) {
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    if model.showsCameraPermissionSettingsAction {
                        Button(String(localized: "overlay.open_camera_settings")) {
                            model.openCameraPrivacySettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: .rect(cornerRadius: 8))
                .allowsHitTesting(model.showsCameraPermissionSettingsAction)
            }
        }
        .frame(minWidth: 480, minHeight: 270)
    }
}
