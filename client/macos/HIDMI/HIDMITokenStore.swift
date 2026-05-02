import AppKit
import Foundation
import LocalAuthentication
import SwiftUI

struct HIDMITokenMetadata: Identifiable, Codable, Equatable {
    let id: UUID
    var preview: String
    var createdAt: Date
    var lastUsedAt: Date?
}

struct HIDMITokenCandidate: Identifiable, Equatable {
    let id: UUID
    let preview: String
    let value: String
}

enum HIDMITokenStoreError: LocalizedError {
    case emptyToken
    case tokenNotFound
    case sessionLocked
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .emptyToken:
            String(localized: "token.error.empty")
        case .tokenNotFound:
            String(localized: "token.error.not_found")
        case .sessionLocked:
            String(localized: "token.error.session_locked")
        case .storage(let message):
            String(format: String(localized: "token.error.storage"), message)
        }
    }
}

final class HIDMIAuthenticationContext: @unchecked Sendable {
    let context: LAContext

    init(context: LAContext) {
        self.context = context
    }
}

protocol HIDMITokenStoreProtocol: AnyObject {
    var isSessionUnlocked: Bool { get }
    func migrateLegacyTokensIfNeeded()
    func metadata() -> [HIDMITokenMetadata]
    func unlockSavedTokens(context: HIDMIAuthenticationContext?) throws
    func candidates(preferredForDeviceID deviceID: String?) throws -> [HIDMITokenCandidate]
    func tokenValue(id: UUID) throws -> String
    @discardableResult
    func saveToken(_ token: String) throws -> HIDMITokenMetadata
    func deleteToken(id: UUID) throws
    func recordSuccessfulUse(tokenID: UUID, deviceID: String)
}

final class LocalHIDMITokenStore: HIDMITokenStoreProtocol {
    private struct PersistedToken: Codable, Equatable {
        var id: UUID
        var value: String
        var createdAt: Date
        var lastUsedAt: Date?

        var metadata: HIDMITokenMetadata {
            HIDMITokenMetadata(
                id: id,
                preview: LocalHIDMITokenStore.maskedPreview(for: value),
                createdAt: createdAt,
                lastUsedAt: lastUsedAt
            )
        }
    }

    private struct PersistedStore: Codable {
        var version: Int
        var tokens: [PersistedToken]
    }

    private let defaults: UserDefaults
    private let storeURL: URL
    private let preferredTokenKey = "HIDMIPreferredTokenByDevice"
    private let migrationKey = "HIDMITokenLocalStoreMigrationComplete"
    private var cachedTokens: [PersistedToken]?

    init(defaults: UserDefaults = .standard, storeURL: URL? = nil) {
        self.defaults = defaults
        self.storeURL = storeURL ?? Self.defaultStoreURL()
    }

    var isSessionUnlocked: Bool {
        true
    }

    func migrateLegacyTokensIfNeeded() {
        let candidates = legacyTokenCandidates()
        guard !defaults.bool(forKey: migrationKey) || ((try? loadTokens())?.isEmpty == true && !candidates.isEmpty) else { return }
        var didMigrateAllCandidates = true
        for token in candidates {
            do {
                _ = try saveToken(token)
            } catch {
                didMigrateAllCandidates = false
            }
        }
        if didMigrateAllCandidates {
            defaults.set(true, forKey: migrationKey)
        }
    }

    func metadata() -> [HIDMITokenMetadata] {
        ((try? loadTokens()) ?? []).map(\.metadata).sorted {
            ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
        }
    }

    func candidates(preferredForDeviceID deviceID: String?) throws -> [HIDMITokenCandidate] {
        let preferredTokenID = preferredTokenID(forDeviceID: deviceID)
        var records = try loadTokens()
        if let preferredTokenID,
           let preferredIndex = records.firstIndex(where: { $0.id == preferredTokenID }) {
            let preferred = records.remove(at: preferredIndex)
            records.insert(preferred, at: 0)
        }

        return records.map { record in
            HIDMITokenCandidate(id: record.id, preview: record.metadata.preview, value: record.value)
        }
    }

    func unlockSavedTokens(context: HIDMIAuthenticationContext?) throws {
        _ = try loadTokens()
    }

    @discardableResult
    func saveToken(_ token: String) throws -> HIDMITokenMetadata {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HIDMITokenStoreError.emptyToken }

        var records = try loadTokens()
        if let existing = records.first(where: { $0.value == trimmed }) {
            return existing.metadata
        }

        let record = PersistedToken(
            id: UUID(),
            value: trimmed,
            createdAt: Date(),
            lastUsedAt: nil
        )
        records.append(record)
        try saveTokens(records)
        return record.metadata
    }

    func deleteToken(id: UUID) throws {
        try saveTokens(try loadTokens().filter { $0.id != id })
        var preferred = preferredTokenMap()
        preferred = preferred.filter { $0.value != id.uuidString }
        savePreferredTokenMap(preferred)
    }

    func recordSuccessfulUse(tokenID: UUID, deviceID: String) {
        guard var records = try? loadTokens() else { return }
        if let index = records.firstIndex(where: { $0.id == tokenID }) {
            records[index].lastUsedAt = Date()
            try? saveTokens(records)
        }
        var preferred = preferredTokenMap()
        preferred[deviceID] = tokenID.uuidString
        savePreferredTokenMap(preferred)
    }

    func tokenValue(id: UUID) throws -> String {
        guard let token = try loadTokens().first(where: { $0.id == id }) else {
            throw HIDMITokenStoreError.tokenNotFound
        }
        return token.value
    }

    private func loadTokens() throws -> [PersistedToken] {
        if let cachedTokens {
            return cachedTokens
        }

        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            cachedTokens = []
            return []
        }

        do {
            let data = try Data(contentsOf: storeURL)
            let decoded = try JSONDecoder().decode(PersistedStore.self, from: data)
            cachedTokens = decoded.tokens
            return decoded.tokens
        } catch {
            throw HIDMITokenStoreError.storage(error.localizedDescription)
        }
    }

    private func saveTokens(_ records: [PersistedToken]) throws {
        do {
            try ensureStoreDirectory()
            let payload = PersistedStore(version: 1, tokens: records)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: storeURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
            cachedTokens = records
        } catch {
            throw HIDMITokenStoreError.storage(error.localizedDescription)
        }
    }

    private func ensureStoreDirectory() throws {
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func defaultStoreURL() -> URL {
        let baseURL = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return baseURL
            .appendingPathComponent("HIDMI", isDirectory: true)
            .appendingPathComponent("tokens.json", isDirectory: false)
    }

    private func preferredTokenID(forDeviceID deviceID: String?) -> UUID? {
        guard let deviceID,
              let raw = preferredTokenMap()[deviceID] else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    private func preferredTokenMap() -> [String: String] {
        defaults.dictionary(forKey: preferredTokenKey) as? [String: String] ?? [:]
    }

    private func savePreferredTokenMap(_ map: [String: String]) {
        defaults.set(map, forKey: preferredTokenKey)
    }

    private func legacyTokenCandidates() -> [String] {
        let githubDefaults = defaultsSuite(named: "io.github.zhao-zirui.hidmi")
        let previousHIDMIDefaults = UserDefaults(suiteName: "app.local.HIDMI")
        let legacyDefaults = UserDefaults(suiteName: "app.local.HdmiViewer")
        return [
            defaults.string(forKey: "HIDMIToken"),
            defaults.string(forKey: "BridgeScopeToken"),
            githubDefaults?.string(forKey: "HIDMIToken"),
            githubDefaults?.string(forKey: "BridgeScopeToken"),
            previousHIDMIDefaults?.string(forKey: "HIDMIToken"),
            previousHIDMIDefaults?.string(forKey: "BridgeScopeToken"),
            legacyDefaults?.string(forKey: "HIDMIToken"),
            legacyDefaults?.string(forKey: "BridgeScopeToken")
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    private func defaultsSuite(named name: String) -> UserDefaults? {
        if Bundle.main.bundleIdentifier == name {
            return nil
        }
        return UserDefaults(suiteName: name)
    }

    private static func maskedPreview(for token: String) -> String {
        let suffix = String(token.suffix(4))
        return suffix.isEmpty ? "********" : "******** \(suffix)"
    }
}

@MainActor
protocol DeviceOwnerAuthenticating: AnyObject {
    func authenticate(reason: String) async -> HIDMIAuthenticationContext?
}

final class LocalDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    func authenticate(reason: String) async -> HIDMIAuthenticationContext? {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300
        let authenticationContext = HIDMIAuthenticationContext(context: context)
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success ? authenticationContext : nil)
            }
        }
    }
}

struct HIDMITokenPromptResult: Equatable {
    let token: String
    let remember: Bool
}

protocol HIDMITokenPrompting: AnyObject {
    @MainActor
    func requestToken(for device: HIDMIDiscoveredDevice) async -> HIDMITokenPromptResult?
}

final class AlertHIDMITokenPrompt: HIDMITokenPrompting {
    @MainActor
    func requestToken(for device: HIDMIDiscoveredDevice) async -> HIDMITokenPromptResult? {
        await HIDMITokenPromptWindowController(device: device).requestToken()
    }
}

@MainActor
struct HIDMITokenPromptState: Equatable {
    var token = ""
    var remember = true

    var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canConfirm: Bool {
        !trimmedToken.isEmpty
    }

    func confirmedResult() -> HIDMITokenPromptResult? {
        guard canConfirm else { return nil }
        return HIDMITokenPromptResult(token: trimmedToken, remember: remember)
    }
}

struct HIDMITokenPromptContent: Equatable {
    let title: String
    let message: String
    let placeholder: String
    let rememberTitle: String
    let confirmTitle: String
    let cancelTitle: String

    init(device: HIDMIDiscoveredDevice) {
        let deviceName = device.promptDeviceName
        let address = device.promptAddress
        title = String(localized: "token.prompt.title")
        message = String(format: String(localized: "token.prompt.message"), deviceName, address)
        placeholder = String(localized: "token.prompt.placeholder")
        rememberTitle = String(localized: "token.prompt.remember")
        confirmTitle = String(localized: "common.ok")
        cancelTitle = String(localized: "common.cancel")
    }
}

@MainActor
private final class HIDMITokenPromptPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

@MainActor
private final class HIDMITokenPromptWindowController: NSObject, NSWindowDelegate {
    private let viewController: HIDMITokenPromptViewController
    private weak var sheetParent: NSWindow?
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<HIDMITokenPromptResult?, Never>?
    private var lifetimeRetainer: HIDMITokenPromptWindowController?
    private var didComplete = false

    init(device: HIDMIDiscoveredDevice) {
        viewController = HIDMITokenPromptViewController(content: HIDMITokenPromptContent(device: device))
        super.init()

        viewController.onConfirm = { [weak self] result in
            self?.complete(result)
        }
        viewController.onCancel = { [weak self] in
            self?.complete(nil)
        }
    }

    func requestToken() async -> HIDMITokenPromptResult? {
        await withCheckedContinuation { continuation in
            lifetimeRetainer = self
            self.continuation = continuation
            show()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        complete(nil)
        return false
    }

    private func show() {
        let panel = makePanel()
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)

        if let parent = NSApp.keyWindow ?? NSApp.mainWindow,
           parent.isVisible,
           parent.canBecomeKey {
            sheetParent = parent
            parent.beginSheet(panel) { [weak self] _ in
                guard let self, !self.didComplete else { return }
                self.complete(nil)
            }
            panel.makeFirstResponder(viewController.tokenField)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(viewController.tokenField)
            _ = NSApp.runModal(for: panel)
        }
    }

    private func makePanel() -> NSPanel {
        _ = viewController.view
        let contentSize = viewController.panelContentSize

        let panel = HIDMITokenPromptPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = viewController
        panel.title = String(localized: "token.prompt.title")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentMinSize = contentSize
        panel.setContentSize(contentSize)
        panel.delegate = self
        panel.defaultButtonCell = viewController.confirmButton.cell as? NSButtonCell
        return panel
    }

    private func complete(_ result: HIDMITokenPromptResult?) {
        guard !didComplete else { return }
        didComplete = true

        continuation?.resume(returning: result)
        continuation = nil

        if let sheetParent, let panel {
            sheetParent.endSheet(panel)
            panel.orderOut(nil)
        } else if let panel {
            NSApp.stopModal()
            panel.orderOut(nil)
        }

        lifetimeRetainer = nil
    }
}

@MainActor
final class HIDMITokenPromptViewController: NSViewController, NSTextFieldDelegate {
    private enum Layout {
        static let width: CGFloat = 392
        static let leadingInset: CGFloat = 22
        static let trailingInset: CGFloat = 22
        static let topInset: CGFloat = 22
        static let bottomInset: CGFloat = 10
    }

    private let content: HIDMITokenPromptContent
    private var state = HIDMITokenPromptState()

    let tokenField = NSSecureTextField()
    let confirmButton: NSButton
    let buttonRow = NSStackView()
    private let contentStack = NSStackView()
    private let rememberButton: NSButton
    private let cancelButton: NSButton
    var onConfirm: ((HIDMITokenPromptResult) -> Void)?
    var onCancel: (() -> Void)?

    init(content: HIDMITokenPromptContent) {
        self.content = content
        confirmButton = NSButton(title: content.confirmTitle, target: nil, action: nil)
        rememberButton = NSButton(checkboxWithTitle: content.rememberTitle, target: nil, action: nil)
        cancelButton = NSButton(title: content.cancelTitle, target: nil, action: nil)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func loadView() {
        let glassView = NSGlassEffectView()
        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassView.style = .regular
        glassView.cornerRadius = 22
        glassView.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.08)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView = contentView
        view = glassView

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: glassView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: glassView.bottomAnchor)
        ])

        buildView(in: contentView)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(tokenField)
    }

    var panelContentSize: NSSize {
        view.layoutSubtreeIfNeeded()
        let stackHeight = contentStack.fittingSize.height
        return NSSize(
            width: Layout.width,
            height: ceil(stackHeight + Layout.topInset + Layout.bottomInset)
        )
    }

    func controlTextDidChange(_ obj: Notification) {
        state.token = tokenField.stringValue
        updateConfirmButton()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            confirm(confirmButton)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel(cancelButton)
            return true
        }
        return false
    }

    @objc private func confirm(_ sender: NSButton) {
        state.token = tokenField.stringValue
        state.remember = rememberButton.state == .on
        guard let result = state.confirmedResult() else {
            updateConfirmButton()
            return
        }
        onConfirm?(result)
    }

    @objc private func cancel(_ sender: NSButton) {
        onCancel?()
    }

    @objc private func rememberChanged(_ sender: NSButton) {
        state.remember = sender.state == .on
    }

    private func buildView(in contentView: NSView) {
        let title = NSTextField(wrappingLabelWithString: content.title)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .left
        title.textColor = .labelColor
        title.maximumNumberOfLines = 2

        let message = NSTextField(wrappingLabelWithString: content.message)
        message.translatesAutoresizingMaskIntoConstraints = false
        message.font = .systemFont(ofSize: 13)
        message.alignment = .left
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 3

        tokenField.placeholderString = content.placeholder
        tokenField.delegate = self
        tokenField.translatesAutoresizingMaskIntoConstraints = false
        tokenField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tokenField.setContentCompressionResistancePriority(.required, for: .horizontal)
        tokenField.controlSize = .large

        rememberButton.target = self
        rememberButton.action = #selector(rememberChanged(_:))
        rememberButton.state = .on
        rememberButton.controlSize = .regular
        rememberButton.font = .systemFont(ofSize: 13)

        confirmButton.target = self
        confirmButton.action = #selector(confirm(_:))
        confirmButton.keyEquivalent = "\r"
        confirmButton.isEnabled = false
        confirmButton.controlSize = .large
        confirmButton.bezelStyle = .glass

        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.controlSize = .large
        cancelButton.bezelStyle = .glass

        buttonRow.setViews([confirmButton, cancelButton], in: .leading)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .vertical
        buttonRow.alignment = .leading
        buttonRow.spacing = 10
        buttonRow.distribution = .fillEqually

        contentStack.setViews([title, message, tokenField, rememberButton, buttonRow], in: .leading)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.setCustomSpacing(12, after: title)
        contentStack.setCustomSpacing(18, after: message)
        contentStack.setCustomSpacing(18, after: rememberButton)
        contentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Layout.width),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.leadingInset),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.trailingInset),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.topInset),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.bottomInset),
            title.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            message.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            tokenField.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            tokenField.heightAnchor.constraint(equalToConstant: 32),
            confirmButton.heightAnchor.constraint(equalToConstant: 34),
            cancelButton.heightAnchor.constraint(equalTo: confirmButton.heightAnchor),
            confirmButton.widthAnchor.constraint(equalTo: buttonRow.widthAnchor),
            cancelButton.widthAnchor.constraint(equalTo: buttonRow.widthAnchor)
        ])
    }

    private func updateConfirmButton() {
        confirmButton.isEnabled = state.canConfirm
    }
}

private extension HIDMIDiscoveredDevice {
    var promptDeviceName: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return name
        }
        return promptAddress
    }

    var promptAddress: String {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty {
            return host
        }

        let deviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !deviceID.isEmpty {
            return deviceID
        }

        return id
    }
}

@MainActor
final class TokenManagementModel: ObservableObject {
    @Published private(set) var tokens: [HIDMITokenMetadata] = []
    @Published var selectedTokenID: UUID?
    @Published var errorMessage: String?

    private let tokenStore: HIDMITokenStoreProtocol

    init(tokenStore: HIDMITokenStoreProtocol) {
        self.tokenStore = tokenStore
        reload()
    }

    func reload() {
        tokens = tokenStore.metadata()
        if let selectedTokenID, !tokens.contains(where: { $0.id == selectedTokenID }) {
            self.selectedTokenID = nil
        }
    }

    func displayValue(for token: HIDMITokenMetadata) -> String {
        do {
            return try tokenStore.tokenValue(id: token.id)
        } catch {
            return String(format: String(localized: "token.value.unavailable"), token.preview)
        }
    }

    func lastUsedSummary(for date: Date, now: Date = Date()) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        let hour: TimeInterval = 60 * 60
        let day: TimeInterval = 24 * hour

        if elapsed < hour {
            return String(localized: "token.age.less_than_hour")
        }

        if elapsed < day {
            let hours = max(1, Int(elapsed / hour))
            let key = hours == 1 ? "token.age.hour" : "token.age.hours"
            return String.localizedStringWithFormat(String(localized: String.LocalizationValue(key)), hours)
        }

        let days = max(1, Int(elapsed / day))
        let key = days == 1 ? "token.age.day" : "token.age.days"
        return String.localizedStringWithFormat(String(localized: String.LocalizationValue(key)), days)
    }

    func addToken(_ token: String) -> Bool {
        do {
            _ = try tokenStore.saveToken(token)
            errorMessage = nil
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteSelectedToken() {
        guard let selectedTokenID else { return }
        do {
            try tokenStore.deleteToken(id: selectedTokenID)
            self.selectedTokenID = nil
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct TokenManagementView: View {
    @StateObject private var model: TokenManagementModel
    @State private var isAddingToken = false
    @State private var pendingToken = ""

    init(tokenStore: HIDMITokenStoreProtocol) {
        _model = StateObject(wrappedValue: TokenManagementModel(tokenStore: tokenStore))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.tokens.isEmpty {
                ContentUnavailableView("token.empty", systemImage: "key")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedTokenID) {
                    ForEach(model.tokens) { token in
                        HStack {
                            Label(model.displayValue(for: token), systemImage: "key")
                            Spacer()
                            if let lastUsedAt = token.lastUsedAt {
                                Text(model.lastUsedSummary(for: lastUsedAt))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(token.id)
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    pendingToken = ""
                    isAddingToken = true
                } label: {
                    Label("token.add", systemImage: "plus")
                }

                Button(role: .destructive) {
                    model.deleteSelectedToken()
                } label: {
                    Label("token.delete", systemImage: "trash")
                }
                .disabled(model.selectedTokenID == nil)
            }
        }
        .sheet(isPresented: $isAddingToken) {
            addTokenSheet
        }
    }

    private var addTokenSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("token.add.title")
                .font(.headline)

            SecureField("token.prompt.placeholder", text: $pendingToken)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()
                Button("common.cancel") {
                    isAddingToken = false
                }
                Button("token.add") {
                    if model.addToken(pendingToken) {
                        isAddingToken = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pendingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

@MainActor
final class TokenManagementWindowController {
    private let tokenStore: HIDMITokenStoreProtocol
    private var window: NSWindow?

    var isVisible: Bool {
        window?.isVisible == true
    }

    init(tokenStore: HIDMITokenStoreProtocol) {
        self.tokenStore = tokenStore
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let controller = NSHostingController(rootView: TokenManagementView(tokenStore: tokenStore))
        let window = NSWindow(contentViewController: controller)
        window.title = String(localized: "token.window.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 440, height: 360))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
