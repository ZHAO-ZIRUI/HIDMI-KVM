import Foundation
import LocalAuthentication

#if DEBUG
enum HIDMIUITestSupport {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["HIDMI_UI_TESTING"] == "1"
    }

    @MainActor
    static func makeModel() -> AppModel {
        let token = ProcessInfo.processInfo.environment["HIDMI_UI_TEST_TOKEN"] ?? "ui-test-token"
        let tokenStore = InMemoryHIDMITokenStore()
        _ = try? tokenStore.saveToken(token)

        let worker = FakeHIDMIWorker(acceptedToken: token)
        let hidmi = HIDMIController(
            worker: worker,
            tokenStore: tokenStore,
            tokenPrompt: FakeHIDMITokenPrompt(token: token),
            timeout: 0.2,
            discoveryInterval: 3_600,
            offlineInterval: 45,
            keepaliveInterval: 3_600
        )

        return AppModel(
            tokenStore: tokenStore,
            authenticator: AlwaysSucceedingAuthenticator(),
            hidmi: hidmi,
            startsVideoInputSetup: false
        )
    }
}

private final class InMemoryHIDMITokenStore: HIDMITokenStoreProtocol {
    private var records: [HIDMITokenMetadata] = []
    private var tokenValues: [UUID: String] = [:]
    private var preferredTokensByDeviceID: [String: UUID] = [:]
    private var didUnlockSavedTokens = true

    var isSessionUnlocked: Bool {
        didUnlockSavedTokens
    }

    func migrateLegacyTokensIfNeeded() {}

    func metadata() -> [HIDMITokenMetadata] {
        records.sorted {
            ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
        }
    }

    func unlockSavedTokens(context: HIDMIAuthenticationContext?) throws {
        didUnlockSavedTokens = true
    }

    func candidates(preferredForDeviceID deviceID: String?) throws -> [HIDMITokenCandidate] {
        var sortedRecords = metadata()
        if let deviceID,
           let preferredID = preferredTokensByDeviceID[deviceID],
           let preferredIndex = sortedRecords.firstIndex(where: { $0.id == preferredID }) {
            let preferred = sortedRecords.remove(at: preferredIndex)
            sortedRecords.insert(preferred, at: 0)
        }
        return sortedRecords.compactMap { record in
            guard let value = tokenValues[record.id] else { return nil }
            return HIDMITokenCandidate(id: record.id, preview: record.preview, value: value)
        }
    }

    func tokenValue(id: UUID) throws -> String {
        guard let value = tokenValues[id] else {
            throw HIDMITokenStoreError.tokenNotFound
        }
        return value
    }

    @discardableResult
    func saveToken(_ token: String) throws -> HIDMITokenMetadata {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HIDMITokenStoreError.emptyToken }
        if let existing = records.first(where: { tokenValues[$0.id] == trimmed }) {
            return existing
        }

        let record = HIDMITokenMetadata(
            id: UUID(),
            preview: "******** \(trimmed.suffix(4))",
            createdAt: Date(),
            lastUsedAt: nil
        )
        records.append(record)
        tokenValues[record.id] = trimmed
        return record
    }

    func deleteToken(id: UUID) throws {
        records.removeAll { $0.id == id }
        tokenValues[id] = nil
        preferredTokensByDeviceID = preferredTokensByDeviceID.filter { $0.value != id }
    }

    func recordSuccessfulUse(tokenID: UUID, deviceID: String) {
        if let index = records.firstIndex(where: { $0.id == tokenID }) {
            records[index].lastUsedAt = Date()
        }
        preferredTokensByDeviceID[deviceID] = tokenID
    }
}

private final class AlwaysSucceedingAuthenticator: DeviceOwnerAuthenticating {
    func authenticate(reason: String) async -> HIDMIAuthenticationContext? {
        HIDMIAuthenticationContext(context: LAContext())
    }
}

private final class FakeHIDMITokenPrompt: HIDMITokenPrompting {
    private let token: String

    init(token: String) {
        self.token = token
    }

    @MainActor
    func requestToken(for device: HIDMIDiscoveredDevice) async -> HIDMITokenPromptResult? {
        HIDMITokenPromptResult(token: token, remember: true)
    }
}

private actor FakeHIDMIWorker: HIDMIWorkerProtocol {
    private let acceptedToken: String
    private let mouseWriter = FakeMouseReportWriter()
    private let keyboardWriter = FakeKeyboardReportWriter()
    private var connected = false

    init(acceptedToken: String) {
        self.acceptedToken = acceptedToken
    }

    func discoverBroadcast(timeout: TimeInterval) async throws -> [HIDMIDevice] {
        [Self.device]
    }

    func connect(device: HIDMIDevice, token: String, timeout: TimeInterval, establishedIOTimeout: TimeInterval) async throws -> HIDMIWorkerConnection {
        guard token == acceptedToken else {
            throw HIDMIClientError.message("HELLO_REJECTED: authentication failed")
        }
        connected = true
        return HIDMIWorkerConnection(
            device: device,
            generation: 1,
            mouseWriter: mouseWriter,
            keyboardWriter: keyboardWriter
        )
    }

    func disconnect() async {
        connected = false
    }

    func releaseAll(generation: UInt64) async throws {
        guard connected else { return }
    }

    func releaseAllBestEffort(generation: UInt64, timeout: TimeInterval) async {
        guard connected else { return }
    }

    func shutdownBestEffort(timeout: TimeInterval) async {
        connected = false
    }

    func ping(generation: UInt64) async throws {
        guard connected else {
            throw HIDMIClientError.message(String(localized: "error.not_connected"))
        }
    }

    func sendReports(_ reports: [HIDMISampledInputReport], generation: UInt64) async throws {
        guard connected else {
            throw HIDMIClientError.message(String(localized: "error.not_connected"))
        }
    }

    func sendCtrlAltDel(generation: UInt64) async throws {
        guard connected else {
            throw HIDMIClientError.message(String(localized: "error.not_connected"))
        }
    }

    private static let device = HIDMIDevice(
        host: "192.0.2.10",
        udpPort: HIDMIClient.defaultUDPPort,
        tcpPort: 55536,
        deviceID: "ui-test-device",
        deviceName: "UI Test KVM",
        sessionID: "ui-test-session",
        serverNonce: "ui-test-server-nonce",
        clientID: "ui-test-client",
        clientNonce: "ui-test-client-nonce",
        requiresAuth: true,
        capabilities: ["absolute_pointer"]
    )
}

private final class FakeMouseReportWriter: HIDMIMouseReportWriting, @unchecked Sendable {
    func enqueueMouseReports(
        _ reports: [HIDMISampledInputReport],
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        completion(.success(reports.count))
    }
}

private final class FakeKeyboardReportWriter: HIDMIKeyboardReportWriting, @unchecked Sendable {
    func enqueueKeyboardReports(
        _ reports: [HIDMISampledInputReport],
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        completion(.success(reports.count))
    }

    func enqueueCtrlAltDel(
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        completion(.success(()))
    }
}
#endif
