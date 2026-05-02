import AppKit
import SwiftUI

final class HIDMIApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        model?.prepareForTermination(timeout: 0.5)
    }
}

@main
struct HIDMIApp: App {
    @NSApplicationDelegateAdaptor(HIDMIApplicationDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        let appModel = AppModel.makeForCurrentEnvironment()
        _model = StateObject(wrappedValue: appModel)
        appDelegate.model = appModel
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .background(WindowAccessor { window in
                    model.attach(window: window)
                })
                .onAppear {
                    model.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            HIDMIViewCommands(model: model)
            HIDMIInputCommands(model: model)
        }
    }
}

struct HIDMIViewCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            if model.devices.isEmpty {
                Button(String(localized: "device.none")) {}
                    .disabled(true)
            } else {
                ForEach(model.devices) { device in
                    Toggle(device.name, isOn: videoDeviceSelection(device.id))
                }
            }

            Divider()

            Menu(String(localized: "format.device_options")) {
                Toggle(String(localized: "format.auto_best"), isOn: automaticFormatSelection)

                Divider()

                ForEach(model.currentFormats) { format in
                    Toggle(format.menuTitle, isOn: formatSelection(format.id))
                }
            }
            .disabled(model.selectedDeviceID == nil)

            Button(String(localized: "device.refresh")) {
                model.refreshDevices()
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Toggle(String(localized: "view.original_input"), isOn: originalInputMode)
                .disabled(model.inputSize == nil)
                .keyboardShortcut("0", modifiers: .command)

            Toggle(String(localized: "view.fit_to_window"), isOn: fitToWindowMode)
                .keyboardShortcut("9", modifiers: .command)

            Button(String(localized: "view.zoom_in")) {
                model.zoomIn()
            }
            .keyboardShortcut("+", modifiers: .command)

            Button(String(localized: "view.zoom_out")) {
                model.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)
        }
    }

    private func videoDeviceSelection(_ id: CaptureDevice.ID) -> Binding<Bool> {
        Binding(
            get: { model.selectedDeviceID == id },
            set: { isSelected in
                if isSelected {
                    model.selectDevice(id)
                }
            }
        )
    }

    private var automaticFormatSelection: Binding<Bool> {
        Binding(
            get: { model.usesAutomaticFormat },
            set: { isSelected in
                if isSelected {
                    model.selectAutomaticFormat()
                }
            }
        )
    }

    private func formatSelection(_ id: CaptureFormat.ID) -> Binding<Bool> {
        Binding(
            get: { !model.usesAutomaticFormat && model.selectedFormatID == id },
            set: { isSelected in
                if isSelected {
                    model.selectFormat(id)
                }
            }
        )
    }

    private var originalInputMode: Binding<Bool> {
        Binding(
            get: { model.isOriginalInputMode },
            set: { enabled in
                if enabled {
                    model.showOriginalInput()
                }
            }
        )
    }

    private var fitToWindowMode: Binding<Bool> {
        Binding(
            get: { model.isFitToWindowMode },
            set: { enabled in
                if enabled {
                    model.fitToWindow()
                }
            }
        )
    }
}

struct HIDMIInputCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu(String(localized: "menu.hid")) {
            let deviceStates = model.hidmi.menuDeviceStates
            if deviceStates.isEmpty {
                Button(String(localized: "hid.device.none")) {}
                    .disabled(true)
            } else {
                ForEach(deviceStates) { state in
                    Menu(state.device.menuTitle) {
                        Button(actionTitle(for: state)) {
                            if state.marker == .connected {
                                model.disconnectHIDMI()
                            } else {
                                model.connectHIDMI(state.id)
                            }
                        }
                        .disabled(state.marker != .connected && (isConnecting || !state.device.isConnectable))

                        Divider()

                        ForEach(state.menuDetails) { detail in
                            Button(detail.title) {}
                                .disabled(true)
                        }
                    }
                }
            }

            Divider()

            Button(String(localized: "hid.refresh_devices")) {
                model.refreshHIDMIDevices()
            }
            .disabled(model.hidmi.isDiscovering)

            Divider()

            Button(String(localized: "hid.release_all")) {
                model.releaseRemoteInput()
            }
            .disabled(!model.hidmi.isConnected)

            Button(String(localized: "hid.send_ctrl_alt_del")) {
                model.sendCtrlAltDel()
            }
            .disabled(!model.hidmi.isConnected)

            Divider()

            Button(String(localized: "token.management")) {
                model.showTokenManagement()
            }
        }
    }

    private var isConnecting: Bool {
        if case .connecting = model.hidmi.status {
            return true
        }
        return false
    }

    private func actionTitle(for state: HIDMIMenuDeviceState) -> String {
        state.marker == .connected
            ? String(localized: "hid.device.disconnect_this_device")
            : String(localized: "hid.device.connect_this_device")
    }
}
