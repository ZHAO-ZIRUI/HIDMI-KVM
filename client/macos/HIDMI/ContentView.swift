import SwiftUI

private enum StatusSelectorKind: Equatable {
    case capture
    case kvm
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var activeSelector: StatusSelectorKind?
    @State private var selectorSnapshot = StatusSelectorSnapshot.empty
    @State private var selectorActionRefreshTask: Task<Void, Never>?
    @State private var isDrawerOpen = false
    @State private var drawerHandlePosition: CGFloat = 0.5
    @State private var drawerDragStartPosition: CGFloat?

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
                let topBlankHeight = topReservedHeight + max((videoAvailableSize.height - frameSize.height) / 2, 0)
                let usesTopStatusBar = !model.isMainWindowFullScreen
                    || topBlankHeight >= PreviewLayout.nonFullScreenTopReservedHeight

                ZStack {
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

                    if usesTopStatusBar {
                        topStatusSelectors
                        topSelectorPanel
                    } else {
                        statusDrawer(safeAreaInsets: proxy.safeAreaInsets)
                    }
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
        .onExitCommand {
            closeActiveSelector()
        }
        .onDisappear {
            closeActiveSelector()
        }
        .onChange(of: model.isMainWindowFullScreen) { _, isFullScreen in
            closeActiveSelector()
            if !isFullScreen {
                isDrawerOpen = false
            }
        }
    }

    private var topStatusSelectors: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let trailingInset: CGFloat = 12
                let leadingReserve = min(CGFloat(96), max(proxy.size.width - 180, 0))
                let maxStatusWidth = max(proxy.size.width - leadingReserve - trailingInset * 2, 120)

                HStack(spacing: 0) {
                    Spacer(minLength: leadingReserve)
                    StatusSelectorBar(
                        snapshot: model.statusBarSnapshot,
                        detailMode: model.statusBarDetailMode,
                        activeSelector: activeSelector,
                        isFloating: false,
                        onToggle: toggleSelector
                    )
                    .frame(maxWidth: maxStatusWidth, alignment: .trailing)
                    .clipped()
                }
                .padding(.trailing, trailingInset)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
            }
            .frame(height: PreviewLayout.nonFullScreenTopReservedHeight)

            Spacer()
        }
    }

    @ViewBuilder
    private var topSelectorPanel: some View {
        if let activeSelector {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: PreviewLayout.nonFullScreenTopReservedHeight)
                    .allowsHitTesting(false)
                Color.black.opacity(0.001)
                    .onTapGesture {
                        closeActiveSelector()
                    }
            }
            .ignoresSafeArea()

            GeometryReader { proxy in
                let panelWidth = min(CGFloat(340), max(proxy.size.width - 24, 280))

                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        StatusSelectorPanel(
                            kind: activeSelector,
                            snapshot: selectorSnapshot,
                            onClose: closeActiveSelector,
                            onRefreshCapture: refreshCaptureSelector,
                            onSelectCaptureDevice: selectCaptureDevice,
                            onSelectAutomaticFormat: selectAutomaticFormat,
                            onSelectFormat: selectFormat,
                            onRefreshKVM: refreshKVMSelector,
                            onToggleKVMDevice: toggleKVMDevice,
                            onReleaseAll: releaseAll,
                            onSendCtrlAltDel: sendCtrlAltDel
                        )
                        .frame(width: panelWidth)
                        .padding(.trailing, 12)
                        .padding(.top, PreviewLayout.nonFullScreenTopReservedHeight + 6)
                    }
                    Spacer()
                }
            }
        }
    }

    private func statusDrawer(safeAreaInsets: EdgeInsets) -> some View {
        GeometryReader { proxy in
            let placement = StatusDrawerPlacement(
                containerSize: proxy.size,
                safeAreaInsets: safeAreaInsets,
                position: drawerHandlePosition,
                isOpen: isDrawerOpen
            )

            HStack(alignment: .center, spacing: 0) {
                drawerHandle(centerRange: placement.centerRange)

                if isDrawerOpen {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 8) {
                            StatusSelectorBar(
                                snapshot: model.statusBarSnapshot,
                                detailMode: .detailed,
                                activeSelector: activeSelector,
                                isFloating: true,
                                layout: .vertical,
                                onToggle: toggleSelector
                            )

                            if let activeSelector {
                                StatusSelectorPanel(
                                    kind: activeSelector,
                                    snapshot: selectorSnapshot,
                                    onClose: closeActiveSelector,
                                    onRefreshCapture: refreshCaptureSelector,
                                    onSelectCaptureDevice: selectCaptureDevice,
                                    onSelectAutomaticFormat: selectAutomaticFormat,
                                    onSelectFormat: selectFormat,
                                    onRefreshKVM: refreshKVMSelector,
                                    onToggleKVMDevice: toggleKVMDevice,
                                    onReleaseAll: releaseAll,
                                    onSendCtrlAltDel: sendCtrlAltDel
                                )
                            }
                        }
                        .padding(8)
                    }
                    .frame(width: StatusDrawerPlacement.drawerWidth, height: placement.height, alignment: .top)
                    .background(Color.black.opacity(0.82), in: .rect(cornerRadius: 8))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: placement.width, height: placement.height, alignment: .topTrailing)
            .position(x: placement.centerX, y: placement.centerY)
        }
    }

    private func drawerHandle(centerRange: CGFloat) -> some View {
        Image(systemName: isDrawerOpen ? "chevron.right" : "chevron.left")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: StatusDrawerPlacement.handleWidth, height: StatusDrawerPlacement.handleHeight)
            .background(Color.black.opacity(0.78), in: .rect(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture {
                if isDrawerOpen {
                    closeActiveSelector()
                }
                withAnimation(.easeInOut(duration: 0.18)) {
                    isDrawerOpen.toggle()
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        updateDrawerHandlePosition(translation: value.translation.height, centerRange: centerRange)
                    }
                    .onEnded { _ in
                        drawerDragStartPosition = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(
                Text(isDrawerOpen ? String(localized: "selector.drawer.close") : String(localized: "selector.drawer.open"))
            )
            .accessibilityAddTraits(.isButton)
    }

    private func toggleSelector(_ kind: StatusSelectorKind) {
        if activeSelector == kind {
            closeActiveSelector()
            return
        }

        selectorSnapshot = model.makeStatusSelectorSnapshot()
        if activeSelector == nil {
            model.beginSelectorInteraction()
        }
        activeSelector = kind
        if model.isMainWindowFullScreen {
            isDrawerOpen = true
        }
    }

    private func closeActiveSelector() {
        guard activeSelector != nil else { return }
        selectorActionRefreshTask?.cancel()
        selectorActionRefreshTask = nil
        activeSelector = nil
        model.endSelectorInteraction()
    }

    private func refreshCaptureSelector() {
        model.refreshCaptureSelectorDevices { snapshot in
            selectorSnapshot = snapshot
        }
    }

    private func selectCaptureDevice(_ id: CaptureDevice.ID) {
        model.selectDevice(id)
        selectorSnapshot = model.makeStatusSelectorSnapshot()
    }

    private func selectAutomaticFormat() {
        model.selectAutomaticFormat()
        selectorSnapshot = model.makeStatusSelectorSnapshot()
    }

    private func selectFormat(_ id: CaptureFormat.ID) {
        model.selectFormat(id)
        selectorSnapshot = model.makeStatusSelectorSnapshot()
    }

    private func refreshKVMSelector() {
        model.refreshHIDMISelectorDevices { snapshot in
            selectorSnapshot = snapshot
        }
    }

    private func toggleKVMDevice(_ item: StatusSelectorKVMDeviceItem) {
        switch item.connectionState {
        case .connected:
            model.disconnectHIDMI()
        case .connecting:
            model.cancelHIDMIConnectionAttempt()
        case .available, .failed, .unavailable:
            model.connectHIDMI(item.id)
        }
        selectorSnapshot = model.makeStatusSelectorSnapshot()
        refreshSelectorSnapshotAfterUserAction(for: .kvm)
    }

    private func releaseAll() {
        model.releaseRemoteInput()
        selectorSnapshot = model.makeStatusSelectorSnapshot()
        refreshSelectorSnapshotAfterUserAction(for: .kvm)
    }

    private func sendCtrlAltDel() {
        model.sendCtrlAltDel()
        selectorSnapshot = model.makeStatusSelectorSnapshot()
        refreshSelectorSnapshotAfterUserAction(for: .kvm)
    }

    private func updateDrawerHandlePosition(translation: CGFloat, centerRange: CGFloat) {
        let startPosition = drawerDragStartPosition ?? drawerHandlePosition
        drawerDragStartPosition = startPosition
        guard centerRange > 1 else { return }
        drawerHandlePosition = min(max(startPosition + translation / centerRange, 0), 1)
    }

    private func refreshSelectorSnapshotAfterUserAction(for kind: StatusSelectorKind) {
        selectorActionRefreshTask?.cancel()
        selectorActionRefreshTask = Task { @MainActor in
            let refreshIntervals = kind == .kvm
                ? [150, 200, 300, 500, 700, 1_000, 1_500, 2_000, 3_000]
                : [150, 500, 1_000]
            for delay in refreshIntervals {
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled, activeSelector == kind else { return }
                let latestSnapshot = model.makeStatusSelectorSnapshot()
                selectorSnapshot = kind == .kvm
                    ? selectorSnapshot.mergingKVMStatePreservingRows(from: latestSnapshot)
                    : latestSnapshot
                if kind == .kvm, !latestSnapshot.isHIDMIConnecting {
                    return
                }
            }
        }
    }
}

extension StatusSelectorSnapshot {
    func mergingKVMStatePreservingRows(from latest: StatusSelectorSnapshot) -> StatusSelectorSnapshot {
        let latestDevices = Dictionary(uniqueKeysWithValues: latest.kvmDevices.map { ($0.id, $0) })
        return StatusSelectorSnapshot(
            statusBar: latest.statusBar,
            statusBarDetailMode: latest.statusBarDetailMode,
            captureDevices: captureDevices,
            isCaptureDeviceOptionsEnabled: isCaptureDeviceOptionsEnabled,
            usesAutomaticCaptureFormat: usesAutomaticCaptureFormat,
            captureFormats: captureFormats,
            kvmDevices: kvmDevices.map { latestDevices[$0.id] ?? $0 },
            isHIDMIDiscovering: latest.isHIDMIDiscovering,
            isHIDMIConnecting: latest.isHIDMIConnecting,
            connectingHIDMIDeviceID: latest.connectingHIDMIDeviceID,
            kvmEndpointErrors: latest.kvmEndpointErrors,
            isHIDMIConnected: latest.isHIDMIConnected
        )
    }
}

struct StatusDrawerPlacement: Equatable {
    static let handleWidth: CGFloat = 28
    static let handleHeight: CGFloat = 76
    static let drawerWidth: CGFloat = 320
    static let maxOpenHeight: CGFloat = 480

    let width: CGFloat
    let height: CGFloat
    let centerX: CGFloat
    let centerY: CGFloat
    let centerRange: CGFloat

    init(containerSize: CGSize, safeAreaInsets: EdgeInsets, position: CGFloat, isOpen: Bool) {
        let topInset = max(56, safeAreaInsets.top + 24)
        let bottomInset = max(48, safeAreaInsets.bottom + 32)
        let availableHeight = max(containerSize.height - topInset - bottomInset, Self.handleHeight)
        let openHeight = min(Self.maxOpenHeight, availableHeight)
        let resolvedHeight = isOpen ? openHeight : Self.handleHeight
        let minCenterY = topInset + resolvedHeight / 2
        let maxCenterY = max(minCenterY, containerSize.height - bottomInset - resolvedHeight / 2)
        let clampedPosition = min(max(position, 0), 1)
        let resolvedWidth = isOpen ? Self.handleWidth + Self.drawerWidth : Self.handleWidth

        width = resolvedWidth
        height = resolvedHeight
        centerRange = maxCenterY - minCenterY
        centerX = containerSize.width - resolvedWidth / 2
        centerY = minCenterY + centerRange * clampedPosition
    }
}

private enum StatusSelectorBarLayout {
    case horizontal
    case vertical
}

private struct StatusSelectorBar: View {
    let snapshot: HIDMIStatusBarSnapshot
    let detailMode: StatusBarDetailMode
    let activeSelector: StatusSelectorKind?
    let isFloating: Bool
    var layout: StatusSelectorBarLayout = .horizontal
    let onToggle: (StatusSelectorKind) -> Void

    var body: some View {
        content
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, detailMode == .detailed ? 6 : 5)
        .padding(.vertical, layout == .vertical ? 5 : 0)
        .frame(height: layout == .vertical ? nil : 24)
        .frame(maxWidth: layout == .vertical ? .infinity : nil, alignment: .leading)
        .background(isFloating ? Color.black.opacity(0.72) : Color.black.opacity(0.35), in: .rect(cornerRadius: 6))
    }

    @ViewBuilder
    private var content: some View {
        if layout == .vertical {
            VStack(spacing: 5) {
                StatusSelectorButton(
                    kind: .capture,
                    item: snapshot.capture,
                    detailMode: detailMode,
                    isActive: activeSelector == .capture,
                    fillsWidth: true,
                    action: onToggle
                )

                Divider()
                    .overlay(Color.white.opacity(0.18))

                StatusSelectorButton(
                    kind: .kvm,
                    item: snapshot.kvm,
                    detailMode: detailMode,
                    isActive: activeSelector == .kvm,
                    fillsWidth: true,
                    action: onToggle
                )
            }
        } else {
            HStack(spacing: detailMode == .detailed ? 8 : 6) {
                StatusSelectorButton(
                    kind: .capture,
                    item: snapshot.capture,
                    detailMode: detailMode,
                    isActive: activeSelector == .capture,
                    action: onToggle
                )

                Divider()
                    .frame(height: 14)
                    .overlay(Color.white.opacity(0.18))

                StatusSelectorButton(
                    kind: .kvm,
                    item: snapshot.kvm,
                    detailMode: detailMode,
                    isActive: activeSelector == .kvm,
                    action: onToggle
                )
            }
        }
    }
}

private struct StatusSelectorButton: View {
    let kind: StatusSelectorKind
    let item: HIDMIStatusBarItem
    let detailMode: StatusBarDetailMode
    let isActive: Bool
    var fillsWidth = false
    let action: (StatusSelectorKind) -> Void

    var body: some View {
        Button {
            action(kind)
        } label: {
            HStack(spacing: 6) {
                HIDMIStatusDot(signal: item.signal)
                Image(systemName: item.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)

                if detailMode == .detailed {
                    Text(item.detail ?? item.title)
                        .truncationMode(.middle)
                        .frame(minWidth: 0)
                        .frame(maxWidth: fillsWidth ? .infinity : 260, alignment: .leading)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.72)
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            .frame(minWidth: 0)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .background(isActive ? Color.white.opacity(0.18) : Color.clear, in: .rect(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.detail ?? item.title))
    }
}

private struct StatusSelectorPanel: View {
    let kind: StatusSelectorKind
    let snapshot: StatusSelectorSnapshot
    let onClose: () -> Void
    let onRefreshCapture: () -> Void
    let onSelectCaptureDevice: (CaptureDevice.ID) -> Void
    let onSelectAutomaticFormat: () -> Void
    let onSelectFormat: (CaptureFormat.ID) -> Void
    let onRefreshKVM: () -> Void
    let onToggleKVMDevice: (StatusSelectorKVMDeviceItem) -> Void
    let onReleaseAll: () -> Void
    let onSendCtrlAltDel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                let item = kind == .capture ? snapshot.statusBar.capture : snapshot.statusBar.kvm
                HIDMIStatusDot(signal: item.signal)
                Image(systemName: item.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(kind == .capture ? String(localized: "selector.capture.title") : String(localized: "selector.kvm.title"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "selector.close")))
            }

            if kind == .capture {
                CaptureSelectorPanelContent(
                    snapshot: snapshot,
                    onRefresh: onRefreshCapture,
                    onSelectDevice: onSelectCaptureDevice,
                    onSelectAutomaticFormat: onSelectAutomaticFormat,
                    onSelectFormat: onSelectFormat
                )
            } else {
                KVMSelectorPanelContent(
                    snapshot: snapshot,
                    onRefresh: onRefreshKVM,
                    onToggleDevice: onToggleKVMDevice,
                    onReleaseAll: onReleaseAll,
                    onSendCtrlAltDel: onSendCtrlAltDel
                )
            }
        }
        .padding(12)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.84), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
    }
}

private enum CaptureFormatDropdownKind: Equatable {
    case resolution
    case frameRate
    case colorFormat
}

private struct CaptureSelectorPanelContent: View {
    let snapshot: StatusSelectorSnapshot
    let onRefresh: () -> Void
    let onSelectDevice: (CaptureDevice.ID) -> Void
    let onSelectAutomaticFormat: () -> Void
    let onSelectFormat: (CaptureFormat.ID) -> Void
    @State private var expandedFormatDropdown: CaptureFormatDropdownKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusSelectorSection(title: String(localized: "selector.capture.devices")) {
                if snapshot.captureDevices.isEmpty {
                    StatusSelectorEmptyRow(text: String(localized: "device.none"))
                } else {
                    ForEach(snapshot.captureDevices) { device in
                        StatusSelectorRow(
                            title: device.title,
                            subtitle: nil,
                            symbolName: "video",
                            isSelected: device.isSelected,
                            isEnabled: true
                        ) {
                            onSelectDevice(device.id)
                        }
                    }
                }
            }

            StatusSelectorSection(title: String(localized: "selector.capture.formats")) {
                captureFormatControls
            }

            StatusSelectorFooterButton(
                title: String(localized: "device.refresh"),
                symbolName: "arrow.clockwise",
                isEnabled: true,
                action: onRefresh
            )
        }
    }

    @ViewBuilder
    private var captureFormatControls: some View {
        let effectiveFormat = StatusSelectorCaptureFormatChoices.effectiveFormat(in: snapshot)

        StatusSelectorRow(
            title: String(localized: "format.auto_best"),
            subtitle: effectiveFormat?.title,
            symbolName: "wand.and.stars",
            isSelected: snapshot.usesAutomaticCaptureFormat,
            isEnabled: snapshot.isCaptureDeviceOptionsEnabled
        ) {
            expandedFormatDropdown = nil
            onSelectAutomaticFormat()
        }

        if snapshot.captureFormats.isEmpty {
            StatusSelectorEmptyRow(text: String(localized: "format.none"))
        } else {
            CaptureFormatDropdown(
                title: String(localized: "format.resolution"),
                value: effectiveFormat?.resolutionTitle,
                symbolName: "rectangle.inset.filled",
                isExpanded: expandedFormatDropdown == .resolution,
                isEnabled: snapshot.isCaptureDeviceOptionsEnabled
            ) {
                toggleFormatDropdown(.resolution)
            } content: {
                ForEach(StatusSelectorCaptureFormatChoices.resolutionOptions(in: snapshot.captureFormats)) { option in
                    StatusSelectorRow(
                        title: option.title,
                        subtitle: nil,
                        symbolName: "rectangle.inset.filled",
                        isSelected: !snapshot.usesAutomaticCaptureFormat && effectiveFormat?.dimensions == option.dimensions,
                        isEnabled: snapshot.isCaptureDeviceOptionsEnabled
                    ) {
                        guard let id = StatusSelectorCaptureFormatChoices.formatID(
                            selectingResolution: option.dimensions,
                            in: snapshot
                        ) else { return }
                        expandedFormatDropdown = nil
                        onSelectFormat(id)
                    }
                }
            }

            CaptureFormatDropdown(
                title: String(localized: "format.refresh_rate"),
                value: effectiveFormat?.frameRateTitle,
                symbolName: "speedometer",
                isExpanded: expandedFormatDropdown == .frameRate,
                isEnabled: snapshot.isCaptureDeviceOptionsEnabled
            ) {
                toggleFormatDropdown(.frameRate)
            } content: {
                ForEach(StatusSelectorCaptureFormatChoices.frameRateOptions(
                    in: snapshot.captureFormats,
                    resolution: effectiveFormat?.dimensions
                )) { option in
                    StatusSelectorRow(
                        title: option.title,
                        subtitle: nil,
                        symbolName: "speedometer",
                        isSelected: !snapshot.usesAutomaticCaptureFormat && effectiveFormat?.frameRateMillis == option.frameRateMillis,
                        isEnabled: snapshot.isCaptureDeviceOptionsEnabled
                    ) {
                        guard let id = StatusSelectorCaptureFormatChoices.formatID(
                            selectingFrameRateMillis: option.frameRateMillis,
                            in: snapshot
                        ) else { return }
                        expandedFormatDropdown = nil
                        onSelectFormat(id)
                    }
                }
            }

            CaptureFormatDropdown(
                title: String(localized: "format.color_format"),
                value: effectiveFormat?.colorFormatTitle,
                symbolName: "camera.filters",
                isExpanded: expandedFormatDropdown == .colorFormat,
                isEnabled: snapshot.isCaptureDeviceOptionsEnabled
            ) {
                toggleFormatDropdown(.colorFormat)
            } content: {
                ForEach(StatusSelectorCaptureFormatChoices.colorFormatOptions(
                    in: snapshot.captureFormats,
                    resolution: effectiveFormat?.dimensions,
                    frameRateMillis: effectiveFormat?.frameRateMillis
                )) { option in
                    StatusSelectorRow(
                        title: option.title,
                        subtitle: nil,
                        symbolName: "camera.filters",
                        isSelected: !snapshot.usesAutomaticCaptureFormat && effectiveFormat?.mediaSubType == option.mediaSubType,
                        isEnabled: snapshot.isCaptureDeviceOptionsEnabled
                    ) {
                        guard let id = StatusSelectorCaptureFormatChoices.formatID(
                            selectingColorFormat: option.mediaSubType,
                            in: snapshot
                        ) else { return }
                        expandedFormatDropdown = nil
                        onSelectFormat(id)
                    }
                }
            }
        }
    }

    private func toggleFormatDropdown(_ kind: CaptureFormatDropdownKind) {
        guard snapshot.isCaptureDeviceOptionsEnabled else { return }
        expandedFormatDropdown = expandedFormatDropdown == kind ? nil : kind
    }
}

private struct KVMSelectorPanelContent: View {
    let snapshot: StatusSelectorSnapshot
    let onRefresh: () -> Void
    let onToggleDevice: (StatusSelectorKVMDeviceItem) -> Void
    let onReleaseAll: () -> Void
    let onSendCtrlAltDel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusSelectorSection(title: String(localized: "selector.kvm.devices")) {
                if snapshot.kvmDevices.isEmpty {
                    StatusSelectorEmptyRow(text: String(localized: "hid.device.none"))
                } else {
                    ForEach(snapshot.kvmDevices) { device in
                        StatusSelectorRow(
                            title: device.title,
                            subtitle: subtitle(for: device),
                            symbolName: device.symbolName,
                            isSelected: device.connectionState == .connected,
                            isEnabled: device.isActionEnabled
                        ) {
                            onToggleDevice(device)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                StatusSelectorFooterButton(
                    title: String(localized: "hid.refresh_devices"),
                    symbolName: "arrow.clockwise",
                    isEnabled: true,
                    action: onRefresh
                )

                StatusSelectorFooterButton(
                    title: String(localized: "hid.release_all"),
                    symbolName: "keyboard.badge.ellipsis",
                    isEnabled: snapshot.isHIDMIConnected,
                    action: onReleaseAll
                )
            }

            StatusSelectorFooterButton(
                title: String(localized: "hid.send_ctrl_alt_del"),
                symbolName: "command",
                isEnabled: snapshot.isHIDMIConnected,
                action: onSendCtrlAltDel
            )
        }
    }

    private func subtitle(for device: StatusSelectorKVMDeviceItem) -> String {
        let detail = device.details.map(\.title).joined(separator: " · ")
        switch device.connectionState {
        case .available:
            return detail
        case .connected:
            return joinedStatus(String(localized: "selector.kvm.connected"), detail: detail)
        case .connecting:
            return joinedStatus(String(localized: "selector.kvm.connecting"), detail: detail)
        case .failed(let message):
            return joinedStatus(message, detail: detail)
        case .unavailable(let message):
            return joinedStatus(message, detail: detail)
        }
    }

    private func joinedStatus(_ status: String, detail: String) -> String {
        guard !detail.isEmpty else { return status }
        return "\(status) · \(detail)"
    }
}

private struct CaptureFormatDropdown<Content: View>: View {
    let title: String
    let value: String?
    let symbolName: String
    let isExpanded: Bool
    let isEnabled: Bool
    let action: () -> Void
    let content: Content

    init(
        title: String,
        value: String?,
        symbolName: String,
        isExpanded: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.value = value
        self.symbolName = symbolName
        self.isExpanded = isExpanded
        self.isEnabled = isEnabled
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 3) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 16)
                        .symbolRenderingMode(.hierarchical)
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(value ?? "-")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(Color.white.opacity(0.09), in: .rect(cornerRadius: 6))
                .opacity(isEnabled ? 1 : 0.42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)

            if isExpanded {
                VStack(spacing: 3) {
                    content
                }
                .padding(.leading, 10)
            }
        }
    }
}

private struct StatusSelectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            VStack(spacing: 3) {
                content
            }
        }
    }
}

private struct StatusSelectorRow: View {
    let title: String
    let subtitle: String?
    let symbolName: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, subtitle == nil ? 6 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.white.opacity(0.16) : Color.white.opacity(0.07), in: .rect(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct StatusSelectorEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.58))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 6))
    }
}

private struct StatusSelectorFooterButton: View {
    let title: String
    let symbolName: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(Color.white.opacity(0.11), in: .rect(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.42)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct HIDMIStatusDot: View {
    let signal: StatusBarSignal
    @State private var isDimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(signal == .blinkingRed && isDimmed ? 0.25 : 1)
            .onAppear {
                guard signal == .blinkingRed else { return }
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                    isDimmed = true
                }
            }
            .onChange(of: signal) { _, nextSignal in
                isDimmed = false
                guard nextSignal == .blinkingRed else { return }
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                    isDimmed = true
                }
            }
    }

    private var color: Color {
        switch signal {
        case .red, .blinkingRed:
            return .red
        case .yellow:
            return .yellow
        case .green:
            return .green
        }
    }
}
