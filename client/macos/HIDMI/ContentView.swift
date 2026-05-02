import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            GeometryReader { proxy in
                let frameSize = model.previewFrameSize(in: proxy.size)

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
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .clipped()
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
