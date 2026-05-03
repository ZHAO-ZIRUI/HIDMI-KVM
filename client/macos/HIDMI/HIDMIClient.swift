import CryptoKit
import Darwin
import Foundation
import Security
import SwiftProtobuf

enum HIDMIDeviceTransport: Equatable, Sendable {
    case ethernet
    case wlan
    case usb
}

enum HIDMIDeviceAvailability: Equatable, Sendable {
    case ready
    case busy
    case hidUnavailable
    case unavailable(String)

    var isConnectable: Bool {
        self == .ready
    }

    var connectionFailureKind: HIDMIConnectionFailureKind {
        switch self {
        case .ready:
            return .other
        case .busy:
            return .busy
        case .hidUnavailable:
            return .hidFailure
        case .unavailable:
            return .network
        }
    }

    var userFacingConnectionDescription: String {
        switch self {
        case .ready:
            return ""
        case .busy:
            return String(localized: "error.server_busy")
        case .hidUnavailable:
            return String(localized: "error.hid_unavailable")
        case .unavailable(let message):
            return message
        }
    }
}

struct HIDMIDevice: Equatable, Sendable {
    let host: String
    let udpPort: Int
    let tcpPort: Int
    let controlTCPPort: Int
    let mouseTCPPort: Int
    let keyboardTCPPort: Int
    let deviceID: String
    let deviceName: String
    let serverID: UInt64
    let bootID: UInt64
    let sessionID: String
    let sessionIDValue: UInt64
    let serverNonce: String
    let challengeNonce: Data
    let clientID: String
    let clientIDValue: UInt64
    let clientNonce: String
    let clientNonceData: Data
    let tcpAcceptMin: Int
    let tcpAcceptMax: Int
    let tcpRejected: Set<Int>
    let requiresAuth: Bool
    let capabilities: Set<String>
    let availability: HIDMIDeviceAvailability
    let transport: HIDMIDeviceTransport
    let usbInterface: String?

    init(
        host: String,
        udpPort: Int,
        tcpPort: Int,
        deviceID: String,
        deviceName: String,
        sessionID: String,
        serverNonce: String,
        clientID: String,
        clientNonce: String,
        requiresAuth: Bool,
        capabilities: Set<String>,
        availability: HIDMIDeviceAvailability = .ready,
        transport: HIDMIDeviceTransport = .ethernet,
        usbInterface: String? = nil,
        controlTCPPort: Int? = nil,
        mouseTCPPort: Int? = nil,
        keyboardTCPPort: Int? = nil,
        serverID: UInt64? = nil,
        bootID: UInt64 = 0,
        sessionIDValue: UInt64 = 0,
        challengeNonce: Data = Data(),
        clientIDValue: UInt64? = nil,
        clientNonceData: Data? = nil,
        tcpAcceptMin: Int = 10_000,
        tcpAcceptMax: Int = 60_999,
        tcpRejected: Set<Int> = []
    ) {
        self.host = host
        self.udpPort = udpPort
        self.tcpPort = tcpPort
        self.controlTCPPort = controlTCPPort ?? tcpPort
        self.mouseTCPPort = mouseTCPPort ?? tcpPort
        self.keyboardTCPPort = keyboardTCPPort ?? tcpPort
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.serverID = serverID ?? HIDMIClient.legacyID(from: deviceID)
        self.bootID = bootID
        self.sessionID = sessionID
        self.sessionIDValue = sessionIDValue
        self.serverNonce = serverNonce
        self.challengeNonce = challengeNonce
        self.clientID = clientID
        self.clientIDValue = clientIDValue ?? HIDMIClient.legacyID(from: clientID)
        self.clientNonce = clientNonce
        self.clientNonceData = clientNonceData ?? Data(clientNonce.utf8)
        self.tcpAcceptMin = tcpAcceptMin
        self.tcpAcceptMax = tcpAcceptMax
        self.tcpRejected = tcpRejected
        self.requiresAuth = requiresAuth
        self.capabilities = capabilities
        self.availability = availability
        self.transport = transport
        self.usbInterface = usbInterface
    }

    var displayName: String {
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }
        return host
    }

    var summary: String {
        if displayName == host {
            return host
        }
        return "\(displayName) \(host)"
    }

    var supportsAbsolutePointer: Bool {
        capabilities.contains("absolute_pointer")
    }

    var discoveryID: String {
        let baseID = deviceID.isEmpty ? host : deviceID
        switch transport {
        case .wlan:
            return "\(baseID)#wlan"
        case .ethernet, .usb:
            return baseID
        }
    }

    func withCapabilities(_ capabilities: Set<String>) -> HIDMIDevice {
        HIDMIDevice(
            host: host,
            udpPort: udpPort,
            tcpPort: tcpPort,
            deviceID: deviceID,
            deviceName: deviceName,
            sessionID: sessionID,
            serverNonce: serverNonce,
            clientID: clientID,
            clientNonce: clientNonce,
            requiresAuth: requiresAuth,
            capabilities: capabilities,
            availability: availability,
            transport: transport,
            usbInterface: usbInterface,
            controlTCPPort: controlTCPPort,
            mouseTCPPort: mouseTCPPort,
            keyboardTCPPort: keyboardTCPPort,
            serverID: serverID,
            bootID: bootID,
            sessionIDValue: sessionIDValue,
            challengeNonce: challengeNonce,
            clientIDValue: clientIDValue,
            clientNonceData: clientNonceData,
            tcpAcceptMin: tcpAcceptMin,
            tcpAcceptMax: tcpAcceptMax,
            tcpRejected: tcpRejected
        )
    }

    func withSession(sessionIDValue: UInt64, controlPort: Int, mousePort: Int, keyboardPort: Int) -> HIDMIDevice {
        HIDMIDevice(
            host: host,
            udpPort: udpPort,
            tcpPort: controlPort,
            deviceID: deviceID,
            deviceName: deviceName,
            sessionID: String(sessionIDValue),
            serverNonce: serverNonce,
            clientID: clientID,
            clientNonce: clientNonce,
            requiresAuth: requiresAuth,
            capabilities: capabilities,
            availability: availability,
            transport: transport,
            usbInterface: usbInterface,
            controlTCPPort: controlPort,
            mouseTCPPort: mousePort,
            keyboardTCPPort: keyboardPort,
            serverID: serverID,
            bootID: bootID,
            sessionIDValue: sessionIDValue,
            challengeNonce: challengeNonce,
            clientIDValue: clientIDValue,
            clientNonceData: clientNonceData,
            tcpAcceptMin: tcpAcceptMin,
            tcpAcceptMax: tcpAcceptMax,
            tcpRejected: tcpRejected
        )
    }
}

enum HIDMIClientError: LocalizedError, Sendable {
    case message(String)
    case server(code: String, detail: String)
    case posix(String, Int32)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            message
        case .server(let code, let detail):
            String(format: String(localized: "error.server"), code, detail)
        case .posix(let operation, let code):
            String(format: String(localized: "error.posix"), operation, String(cString: strerror(code)))
        }
    }

    var isAuthenticationFailure: Bool {
        switch self {
        case .server(let code, _):
            return code == "TOKEN_AUTH_FAILED" || code == "HELLO_REJECTED"
        case .message(let message):
            return message.localizedCaseInsensitiveContains("authentication failed")
                || message.localizedCaseInsensitiveContains("requires a token")
                || message.localizedCaseInsensitiveContains("requires a hidmi kvm token")
                || message.localizedCaseInsensitiveContains("TOKEN_AUTH_FAILED")
                || message.localizedCaseInsensitiveContains("HELLO_REJECTED")
                || message == String(localized: "error.device_requires_token")
                || message == String(localized: "error.hello_rejected")
        case .posix:
            return false
        }
    }

    var isAcceptRequiredFailure: Bool {
        false
    }

    var connectionFailureKind: HIDMIConnectionFailureKind {
        switch self {
        case .server(let code, let detail):
            if code == "SERVER_BUSY" || code == "BUSY" {
                return .busy
            }
            if code == "TOKEN_AUTH_FAILED" || code == "HELLO_REJECTED" {
                return .authentication
            }
            if Self.isLikelyHIDFailure(code: code, detail: detail) {
                return .hidFailure
            }
            return .protocolFailure
        case .posix(_, let code):
            switch code {
            case EAGAIN, EWOULDBLOCK, ETIMEDOUT:
                return .timeout
            case ECONNRESET, ECONNABORTED, ENOTCONN, EPIPE:
                return .peerClosed
            default:
                return .network
            }
        case .message(let message):
            let lowercased = message.lowercased()
            if isAuthenticationFailure {
                return .authentication
            }
            if lowercased.contains("busy") {
                return .busy
            }
            if lowercased.contains("temporarily unavailable")
                || lowercased.contains("timed out")
                || lowercased.contains("timeout") {
                return .timeout
            }
            if lowercased.contains("no route to host")
                || lowercased.contains("network is unreachable")
                || lowercased.contains("host is unreachable") {
                return .network
            }
            if lowercased.contains("socket closed")
                || lowercased.contains("connection closed")
                || lowercased.contains("not connected") {
                return .peerClosed
            }
            if message == String(localized: "error.protocol_failure")
                || message == String(localized: "error.response_too_large")
                || lowercased.contains("response is not")
                || lowercased.contains("response too large")
                || lowercased.contains("server response is too large") {
                return .protocolFailure
            }
            if Self.isLikelyHIDFailure(code: "ERROR", detail: message) {
                return .hidFailure
            }
            return .network
        }
    }

    static func isLikelyHIDFailure(code: String, detail: String) -> Bool {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalizedCode == "HID_UNAVAILABLE" || normalizedCode == "HID_FAILURE" {
            return true
        }
        let lowercasedDetail = detail.lowercased()
        if normalizedCode == "BAD_COMMAND", lowercasedDetail.contains("hid") {
            return true
        }
        guard normalizedCode == "ERROR" || normalizedCode == "KEYBOARD_ERROR" else {
            return false
        }
        return [
            "hid",
            "hid_failure",
            "writer unavailable",
            "writer is not available",
            "write timed out",
            "hidg",
            "gadget",
            "/dev/hid",
            "endpoint"
        ].contains { lowercasedDetail.contains($0) }
    }

    var userFacingConnectionDescription: String {
        if case .server(let code, _) = self, code == "AUTH_RATE_LIMITED" {
            return String(localized: "error.auth_rate_limited")
        }
        if case .posix(_, let code) = self {
            switch code {
            case ENETUNREACH, EHOSTUNREACH:
                return String(localized: "error.network_unreachable")
            case ECONNREFUSED:
                return String(localized: "error.connection_refused")
            case ETIMEDOUT:
                return String(localized: "error.device_response_timeout")
            default:
                break
            }
        }
        if case .message(let message) = self {
            let lowercased = message.lowercased()
            if lowercased.contains("no route to host")
                || lowercased.contains("network is unreachable")
                || lowercased.contains("host is unreachable") {
                return String(localized: "error.network_unreachable")
            }
            if lowercased.contains("connection refused") {
                return String(localized: "error.connection_refused")
            }
        }
        switch connectionFailureKind {
        case .timeout:
            return String(localized: "error.device_response_timeout")
        case .busy:
            return String(localized: "error.server_busy")
        case .authentication:
            return String(localized: "error.hello_rejected")
        case .hidFailure:
            return String(localized: "error.hid_unavailable")
        case .protocolFailure:
            return String(localized: "error.protocol_failure")
        case .peerClosed:
            return String(localized: "error.peer_closed")
        case .network:
            return errorDescription ?? String(localized: "error.network")
        case .other:
            return errorDescription ?? String(localized: "error.unknown")
        }
    }
}

enum HIDMIConnectionFailureKind: Equatable, Sendable {
    case timeout
    case peerClosed
    case network
    case protocolFailure
    case authentication
    case busy
    case hidFailure
    case other

    var isTransient: Bool {
        switch self {
        case .timeout, .busy, .network:
            return true
        case .peerClosed, .protocolFailure, .authentication, .hidFailure, .other:
            return false
        }
    }
}

enum HIDMIProtocolLimits {
    static let maximumFrameBytes = 64 * 1024
    static let minimumPort = 1
    static let maximumPort = 65_535
    static let minimumTimeout: TimeInterval = 0.1
    static let maximumTimeout: TimeInterval = 30.0

    static func validatedPort(_ port: Int, field: String = "port") throws -> Int {
        guard minimumPort...maximumPort ~= port else {
            throw HIDMIClientError.message(
                String(format: String(localized: "error.invalid_port"), field, port)
            )
        }
        return port
    }

    static func normalizedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        guard timeout.isFinite else { return 1.0 }
        return min(max(timeout, minimumTimeout), maximumTimeout)
    }
}

enum HIDMIClient {
    static let proto: UInt32 = 1
    static let defaultUDPPort = 55536

    static func discover(host: String, udpPort: Int, timeout: TimeInterval) throws -> HIDMIDevice {
        let devices = try discoverBroadcast(udpPort: udpPort, timeout: timeout)
        if let exact = devices.first(where: { $0.host == host || $0.discoveryID == host }) {
            return exact
        }
        throw HIDMIClientError.message(String(localized: "error.discovery_no_offer"))
    }

    static func discoverBroadcast(udpPort: Int, timeout: TimeInterval) throws -> [HIDMIDevice] {
        let client = clientIdentity()
        let fd = try udpSocket(timeout: timeout, bindPort: udpPort, reusable: true)
        defer { Darwin.close(fd) }

        let deadline = Date().addingTimeInterval(max(timeout, 0.1))
        var devicesByID = [String: HIDMIDevice]()
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            try setTimeout(remaining, fd: fd)

            var buffer = [UInt8](repeating: 0, count: 1200)
            let bufferCapacity = buffer.count
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                withUnsafeMutablePointer(to: &peer) { peerPointer in
                    peerPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        Darwin.recvfrom(fd, rawBuffer.baseAddress, bufferCapacity, 0, sockaddrPointer, &peerLength)
                    }
                }
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    break
                }
                throw HIDMIClientError.posix("recvfrom", errno)
            }

            let data = Data(buffer.prefix(count))
            do {
                let packet = try Hidmi_Kvm_Input_V1_UdpPacket(serializedBytes: data)
                guard packet.protocolVersion == proto,
                      case .discover(let discover)? = packet.body else {
                    continue
                }
                let host = try ipv4Host(from: peer)
                let device = try device(fromDiscover: discover, host: host, udpPort: udpPort, client: client)
                devicesByID[device.discoveryID] = device
            } catch {
                continue
            }
        }

        return devicesByID.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    static func connect(
        device: HIDMIDevice,
        token: String,
        timeout: TimeInterval,
        establishedIOTimeout: TimeInterval
    ) throws -> HIDMISession {
        guard device.availability.isConnectable else {
            let code: String
            switch device.availability {
            case .busy:
                code = "SERVER_BUSY"
            case .hidUnavailable:
                code = "HID_UNAVAILABLE"
            case .unavailable:
                code = "UNAVAILABLE"
            case .ready:
                code = "OFFER_REJECTED"
            }
            throw HIDMIClientError.server(code: code, detail: device.availability.userFacingConnectionDescription)
        }

        var lastReject: HIDMIClientError?
        for _ in 0..<3 {
            let ports = try choosePorts(for: device)
            let callback = try sendOffer(device: device, token: token, ports: ports, timeout: timeout)
            if callback.accept {
                let connectedDevice = device.withSession(
                    sessionIDValue: callback.sessionID,
                    controlPort: ports.control,
                    mousePort: ports.mouse,
                    keyboardPort: ports.keyboard
                )
                return try HIDMISession(
                    device: connectedDevice,
                    timeout: TimeInterval(callback.connectDeadlineMs) / 1000.0,
                    establishedIOTimeout: establishedIOTimeout
                )
            }

            let error = error(forReject: callback.rejectReason)
            lastReject = error
            if callback.rejectReason == .tcpOccupied || callback.rejectReason == .invalidPort {
                continue
            }
            throw error
        }
        throw lastReject ?? HIDMIClientError.message(String(localized: "error.not_connected"))
    }

    static func device(
        fromOffer response: [String: Any],
        host: String,
        udpPort: Int,
        clientID: String,
        clientNonce: String
    ) throws -> HIDMIDevice {
        guard let tcpPort = intField("tcp_port", in: response) else {
            throw HIDMIClientError.message(String(localized: "error.offer_missing_fields"))
        }
        let validatedTCPPort = try HIDMIProtocolLimits.validatedPort(tcpPort, field: "tcp_port")
        let status = response["status"] as? String ?? "ready"
        let availability: HIDMIDeviceAvailability = status == "hid_unavailable" ? .hidUnavailable : .ready
        let advertisedCapabilities = Set((response["capabilities"] as? [Any] ?? []).compactMap { $0 as? String })
        return HIDMIDevice(
            host: host,
            udpPort: udpPort,
            tcpPort: validatedTCPPort,
            deviceID: response["device_id"] as? String ?? host,
            deviceName: response["device_name"] as? String ?? "",
            sessionID: response["session_id"] as? String ?? "",
            serverNonce: response["server_nonce"] as? String ?? "",
            clientID: clientID,
            clientNonce: clientNonce,
            requiresAuth: response["requires_auth"] as? Bool ?? false,
            capabilities: availability.isConnectable ? advertisedCapabilities : [],
            availability: availability
        )
    }

    fileprivate static func intField(_ name: String, in message: [String: Any]) -> Int? {
        guard let rawValue = message[name] else { return nil }
        if let value = rawValue as? Int {
            return value
        }
        if rawValue is Bool {
            return nil
        }
        if let value = rawValue as? NSNumber {
            let doubleValue = value.doubleValue
            guard doubleValue.isFinite,
                  doubleValue.rounded(.towardZero) == doubleValue,
                  doubleValue >= Double(Int.min),
                  doubleValue <= Double(Int.max)
            else {
                return nil
            }
            return value.intValue
        }
        return nil
    }

    fileprivate static func setTimeout(_ timeout: TimeInterval, fd: Int32) throws {
        let interval = HIDMIProtocolLimits.normalizedTimeout(timeout)
        var value = timeval(
            tv_sec: Int(interval),
            tv_usec: Int32((interval - floor(interval)) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, size) != 0 {
            throw HIDMIClientError.posix("setsockopt(SO_RCVTIMEO)", errno)
        }
        if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, size) != 0 {
            throw HIDMIClientError.posix("setsockopt(SO_SNDTIMEO)", errno)
        }
    }

    fileprivate static func ipv4Address(host: String, port: Int) throws -> sockaddr_in {
        let port = try HIDMIProtocolLimits.validatedPort(port)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        let result = host.withCString { pointer in
            inet_pton(AF_INET, pointer, &address.sin_addr)
        }
        if result != 1 {
            throw HIDMIClientError.message(String(localized: "error.host_ipv4"))
        }
        return address
    }

    fileprivate static func ipv4Host(from storage: sockaddr_storage) throws -> String {
        guard Int32(storage.ss_family) == AF_INET else {
            throw HIDMIClientError.message(String(localized: "error.discovery_response_not_ipv4"))
        }
        var address = storage
        var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4Pointer in
                var sinAddress = ipv4Pointer.pointee.sin_addr
                guard inet_ntop(AF_INET, &sinAddress, &hostBuffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    throw HIDMIClientError.posix("inet_ntop", errno)
                }
                return hostBuffer.withUnsafeBufferPointer { buffer in
                    String(cString: buffer.baseAddress!)
                }
            }
        }
    }

    fileprivate static func legacyID(from text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash == 0 ? 1 : hash
    }

    static func device(
        fromDiscover discover: Hidmi_Kvm_Input_V1_Discover,
        host: String,
        udpPort: Int,
        client: ClientIdentity
    ) throws -> HIDMIDevice {
        let minPort = try HIDMIProtocolLimits.validatedPort(Int(discover.tcpAcceptMin), field: "tcp_accept_min")
        let maxPort = try HIDMIProtocolLimits.validatedPort(Int(discover.tcpAcceptMax), field: "tcp_accept_max")
        guard minPort <= maxPort else {
            throw HIDMIClientError.message(String(localized: "error.invalid_port"))
        }
        let advertisedCapabilities = Set(discover.capabilities)
        let isLegacyDiscover = discover.hidStatus == .unknown
            && !discover.hidAvailable
            && !discover.absolutePointerAvailable
            && !discover.relativePointerAvailable
            && advertisedCapabilities.isEmpty
        let hidAvailable = isLegacyDiscover ? true : discover.hidAvailable
        let capabilities = isLegacyDiscover
            ? Set(["keyboard", "mouse", "release_all", "absolute_pointer"])
            : advertisedCapabilities
        let availability: HIDMIDeviceAvailability
        if discover.isBusy {
            availability = .busy
        } else if hidAvailable || discover.hidStatus == .ready || discover.hidStatus == .absoluteDegraded {
            availability = .ready
        } else {
            availability = .hidUnavailable
        }
        let transport: HIDMIDeviceTransport = discover.interfaceType == .ifaceWlan ? .wlan : .ethernet

        return HIDMIDevice(
            host: host,
            udpPort: udpPort,
            tcpPort: minPort,
            deviceID: String(discover.serverID),
            deviceName: discover.serverName,
            sessionID: "",
            serverNonce: String(discover.bootID),
            clientID: String(client.id),
            clientNonce: client.nonce.map { String(format: "%02x", $0) }.joined(),
            requiresAuth: false,
            capabilities: capabilities,
            availability: availability,
            transport: transport,
            serverID: discover.serverID,
            bootID: discover.bootID,
            challengeNonce: discover.challengeNonce,
            clientIDValue: client.id,
            clientNonceData: client.nonce,
            tcpAcceptMin: minPort,
            tcpAcceptMax: maxPort,
            tcpRejected: Set(discover.tcpRejected.map(Int.init))
        )
    }

    private static func sendOffer(
        device: HIDMIDevice,
        token: String,
        ports: (control: Int, mouse: Int, keyboard: Int),
        timeout: TimeInterval
    ) throws -> Hidmi_Kvm_Input_V1_OfferCallback {
        var offer = Hidmi_Kvm_Input_V1_Offer()
        offer.serverID = device.serverID
        offer.bootID = device.bootID
        offer.clientID = device.clientIDValue
        offer.clientNonce = device.clientNonceData
        offer.clientUnixMs = UInt64(Date().timeIntervalSince1970 * 1000.0)
        offer.controlTcpPort = UInt32(ports.control)
        offer.mouseTcpPort = UInt32(ports.mouse)
        offer.keyboardTcpPort = UInt32(ports.keyboard)
        offer.authMac = offerAuth(
            token: token,
            serverID: offer.serverID,
            bootID: offer.bootID,
            challengeNonce: device.challengeNonce,
            clientNonce: offer.clientNonce,
            controlPort: offer.controlTcpPort,
            mousePort: offer.mouseTcpPort,
            keyboardPort: offer.keyboardTcpPort,
            clientUnixMs: offer.clientUnixMs
        )

        var packet = Hidmi_Kvm_Input_V1_UdpPacket()
        packet.protocolVersion = proto
        packet.offer = offer
        let payload = try packet.serializedData()

        let fd = try udpSocket(timeout: timeout, bindPort: nil, reusable: false)
        defer { Darwin.close(fd) }

        let deadline = Date().addingTimeInterval(max(timeout, HIDMIProtocolLimits.minimumTimeout))
        let retryInterval: TimeInterval = 0.2
        var nextSend = Date.distantPast
        while Date() < deadline {
            let now = Date()
            if now >= nextSend {
                try sendUDP(payload: payload, host: device.host, port: device.udpPort, fd: fd)
                nextSend = now.addingTimeInterval(retryInterval)
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            let receiveTimeout = min(remaining, max(0.01, nextSend.timeIntervalSinceNow))
            try setTimeout(receiveTimeout, fd: fd)

            var buffer = [UInt8](repeating: 0, count: 1200)
            let bufferCapacity = buffer.count
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                withUnsafeMutablePointer(to: &peer) { peerPointer in
                    peerPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        Darwin.recvfrom(fd, rawBuffer.baseAddress, bufferCapacity, 0, sockaddrPointer, &peerLength)
                    }
                }
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                throw HIDMIClientError.posix("recvfrom", errno)
            }

            if let peerHost = try? ipv4Host(from: peer), peerHost != device.host {
                HIDMIInputTrace.log(
                    "stale_udp_callback",
                    fields: ["reason": "peer_mismatch", "peer": peerHost, "expected": device.host]
                )
                continue
            }

            let data = Data(buffer.prefix(count))
            if let callback = matchingOfferCallback(
                from: data,
                expectedServerID: device.serverID,
                expectedBootID: device.bootID
            ) {
                return callback
            }

            let reason = offerCallbackRejectionReason(
                from: data,
                expectedServerID: device.serverID,
                expectedBootID: device.bootID
            )
            if reason == "protocol_version" {
                HIDMIInputTrace.log("protocol_mismatch", fields: ["context": "offer_callback"])
            }
            HIDMIInputTrace.log(
                "stale_udp_callback",
                fields: ["reason": reason, "bytes": "\(count)"]
            )
        }
        throw HIDMIClientError.message(String(localized: "error.device_response_timeout"))
    }

    static func matchingOfferCallback(
        from data: Data,
        expectedServerID: UInt64,
        expectedBootID: UInt64
    ) -> Hidmi_Kvm_Input_V1_OfferCallback? {
        guard let packet = try? Hidmi_Kvm_Input_V1_UdpPacket(serializedBytes: data),
              packet.protocolVersion == proto,
              case .offerCallback(let callback)? = packet.body,
              callback.serverID == expectedServerID,
              callback.bootID == expectedBootID else {
            return nil
        }
        return callback
    }

    static func offerCallbackRejectionReason(
        from data: Data,
        expectedServerID: UInt64,
        expectedBootID: UInt64
    ) -> String {
        guard let packet = try? Hidmi_Kvm_Input_V1_UdpPacket(serializedBytes: data) else {
            return "invalid_protobuf"
        }
        guard packet.protocolVersion == proto else {
            return "protocol_version"
        }
        guard case .offerCallback(let callback)? = packet.body else {
            switch packet.body {
            case .discover?:
                return "discover"
            case .offer?:
                return "offer"
            case nil:
                return "empty_body"
            case .offerCallback?:
                return "offer_callback_mismatch"
            }
        }
        if callback.serverID != expectedServerID {
            return "server_id"
        }
        if callback.bootID != expectedBootID {
            return "boot_id"
        }
        return "offer_callback_mismatch"
    }

    private static func choosePorts(for device: HIDMIDevice) throws -> (control: Int, mouse: Int, keyboard: Int) {
        let lower = max(HIDMIProtocolLimits.minimumPort, device.tcpAcceptMin)
        let upper = min(HIDMIProtocolLimits.maximumPort, device.tcpAcceptMax)
        guard lower <= upper else {
            throw HIDMIClientError.message(String(localized: "error.invalid_port"))
        }
        let rejected = device.tcpRejected
        var selected = Set<Int>()
        var ports = [Int]()
        for _ in 0..<512 where ports.count < 3 {
            let candidate = Int.random(in: lower...upper)
            if rejected.contains(candidate) || selected.contains(candidate) {
                continue
            }
            selected.insert(candidate)
            ports.append(candidate)
        }
        guard ports.count == 3 else {
            throw HIDMIClientError.server(code: "INVALID_PORT", detail: "No usable TCP ports in advertised range")
        }
        return (ports[0], ports[1], ports[2])
    }

    private static func error(forReject reason: Hidmi_Kvm_Input_V1_OfferRejectReason) -> HIDMIClientError {
        switch reason {
        case .tokenAuthFailed:
            return .server(code: "TOKEN_AUTH_FAILED", detail: String(localized: "error.hello_rejected"))
        case .tcpOccupied:
            return .server(code: "TCP_OCCUPIED", detail: "TCP ports are occupied")
        case .serverIDMismatch:
            return .server(code: "SERVER_ID_MISMATCH", detail: "Server identity changed")
        case .serverBusy:
            return .server(code: "SERVER_BUSY", detail: String(localized: "error.server_busy"))
        case .hidUnavailable:
            return .server(code: "HID_UNAVAILABLE", detail: String(localized: "error.hid_unavailable"))
        case .authRateLimited:
            return .server(code: "AUTH_RATE_LIMITED", detail: String(localized: "error.auth_rate_limited"))
        case .protocolVersionMismatch:
            return .server(code: "PROTOCOL_VERSION_MISMATCH", detail: String(localized: "error.protocol_failure"))
        case .invalidPort:
            return .server(code: "INVALID_PORT", detail: "TCP port selection was rejected")
        case .internalError:
            return .server(code: "INTERNAL_ERROR", detail: "Server internal error")
        case .offerRejectNone, .UNRECOGNIZED(_):
            return .server(code: "OFFER_REJECTED", detail: String(localized: "error.protocol_failure"))
        }
    }

    fileprivate static func offerAuth(
        token: String,
        serverID: UInt64,
        bootID: UInt64,
        challengeNonce: Data,
        clientNonce: Data,
        controlPort: UInt32,
        mousePort: UInt32,
        keyboardPort: UInt32,
        clientUnixMs: UInt64
    ) -> Data {
        var payload = Data()
        payload.appendBigEndian(proto)
        payload.appendBigEndian(serverID)
        payload.appendBigEndian(bootID)
        payload.append(challengeNonce)
        payload.append(clientNonce)
        payload.appendBigEndian(controlPort)
        payload.appendBigEndian(mousePort)
        payload.appendBigEndian(keyboardPort)
        payload.appendBigEndian(clientUnixMs)
        let key = SymmetricKey(data: Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
    }

    private static func udpSocket(timeout: TimeInterval, bindPort: Int?, reusable: Bool) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 {
            throw HIDMIClientError.posix("socket", errno)
        }
        do {
            if reusable {
                var enabled: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &enabled, socklen_t(MemoryLayout<Int32>.size))
            }
            try setTimeout(timeout, fd: fd)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = INADDR_ANY.bigEndian
            address.sin_port = UInt16(bindPort ?? 0).bigEndian
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult != 0 {
                throw HIDMIClientError.posix("bind", errno)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func sendUDP(payload: Data, host: String, port: Int, fd: Int32) throws {
        var address = try ipv4Address(host: host, port: port)
        let result = payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.sendto(fd, bytes.baseAddress, payload.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if result < 0 {
            throw HIDMIClientError.posix("sendto", errno)
        }
    }

    private static func clientIdentity() -> ClientIdentity {
        let idKey = "HIDMIClientID.v2"
        let defaults = UserDefaults.standard
        let id: UInt64
        if let existing = defaults.object(forKey: idKey) as? NSNumber, existing.uint64Value != 0 {
            id = existing.uint64Value
        } else {
            let generated = UInt64.random(in: 1...UInt64.max)
            defaults.set(NSNumber(value: generated), forKey: idKey)
            id = generated
        }
        return ClientIdentity(id: id, nonce: randomNonceData())
    }

    private static func randomNonceData() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0...255)
            }
        }
        return Data(bytes)
    }
}

struct ClientIdentity {
    let id: UInt64
    let nonce: Data
}

struct HIDMIMouseFrameState: Sendable {
    private var mouseSeq: UInt32 = 0
    private var lastMouseButtons: UInt64 = 0
    private var lastAbsoluteX = 32_768
    private var lastAbsoluteY = 32_768

    mutating func makeFrame(
        sessionID: UInt64,
        report: RemoteInputReport,
        sampleMonoUs: UInt64
    ) throws -> Hidmi_Kvm_Input_V1_TcpFrame {
        let buttons: Int
        let wheelY: Int
        let wheelX = 0
        let relX: Int
        let relY: Int
        switch report {
        case .absoluteMouse(let nextButtons, let x, let y, let dx, let dy):
            buttons = nextButtons
            wheelY = 0
            relX = dx
            relY = dy
            lastAbsoluteX = max(0, min(x, 65_535))
            lastAbsoluteY = max(0, min(y, 65_535))
        case .mouse(let nextButtons, let dx, let dy, let wheel):
            buttons = nextButtons
            wheelY = wheel
            relX = dx
            relY = dy
        case .keyboard:
            throw HIDMIClientError.message(String(localized: "error.protocol_failure"))
        }

        mouseSeq &+= 1
        let nextButtons = UInt64(max(0, buttons))
        let hasReliableEdge = nextButtons != lastMouseButtons || wheelY != 0 || wheelX != 0
        lastMouseButtons = nextButtons

        return Hidmi_Kvm_Input_V1_TcpFrame.with {
            $0.sessionID = sessionID
            $0.channelID = .channelMouse
            $0.seq = mouseSeq
            $0.monotonicUs = HIDMIMonotonic.microseconds()
            $0.ackRequired = false
            $0.mouseState = Hidmi_Kvm_Input_V1_MouseState.with {
                $0.absX = UInt32(lastAbsoluteX)
                $0.absY = UInt32(lastAbsoluteY)
                $0.buttonsMask = nextButtons
                $0.wheelDeltaY = Int32(max(-127, min(wheelY, 127)))
                $0.wheelDeltaX = Int32(max(-127, min(wheelX, 127)))
                $0.relDx = Int32(max(-127, min(relX, 127)))
                $0.relDy = Int32(max(-127, min(relY, 127)))
                $0.hasReliableEdge_p = hasReliableEdge
                $0.sampleMonoUs = sampleMonoUs
            }
        }
    }
}

struct HIDMIKeyboardFrameState: Sendable {
    private var keyboardSeq: UInt32 = 0

    mutating func makeKeyboardStateFrame(
        sessionID: UInt64,
        modifiers: Int,
        keys: [Int]
    ) -> Hidmi_Kvm_Input_V1_TcpFrame {
        keyboardSeq &+= 1
        return Hidmi_Kvm_Input_V1_TcpFrame.with {
            $0.sessionID = sessionID
            $0.channelID = .channelKeyboard
            $0.seq = keyboardSeq
            $0.monotonicUs = HIDMIMonotonic.microseconds()
            $0.ackRequired = true
            $0.keyboardState = Hidmi_Kvm_Input_V1_KeyboardState.with {
                $0.modifierMask = UInt32(max(0, min(modifiers, 0xff)))
                $0.pressedUsageIds = keys.prefix(6).map { UInt32(max(0, min($0, 0xff))) }
            }
        }
    }

    mutating func makeKeyboardSpecialFrame(
        sessionID: UInt64,
        special: Hidmi_Kvm_Input_V1_KeyboardSpecialId
    ) -> Hidmi_Kvm_Input_V1_TcpFrame {
        keyboardSeq &+= 1
        return Hidmi_Kvm_Input_V1_TcpFrame.with {
            $0.sessionID = sessionID
            $0.channelID = .channelKeyboard
            $0.seq = keyboardSeq
            $0.monotonicUs = HIDMIMonotonic.microseconds()
            $0.ackRequired = true
            $0.keyboardSpecial = Hidmi_Kvm_Input_V1_KeyboardSpecial.with {
                $0.specID = special
                $0.releaseBefore = true
                $0.restorePreviousState = false
            }
        }
    }
}

private final class HIDMISessionMouseReportWriter: HIDMIMouseReportWriting, @unchecked Sendable {
    private weak var session: HIDMISession?
    private let queue = DispatchQueue(label: "io.github.zhao-zirui.hidmi.mouse-writer", qos: .userInteractive)

    init(session: HIDMISession) {
        self.session = session
    }

    func enqueueMouseReports(
        _ reports: [HIDMISampledInputReport],
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        guard !reports.isEmpty else {
            completion(.success(0))
            return
        }
        HIDMIInputTrace.log(
            "writer_enqueue",
            fields: [
                "count": "\(reports.count)",
                "first_report": reports.first?.report.traceName ?? "unknown",
                "sample_mono_us": "\(reports.first?.sampleMonoUs ?? 0)"
            ]
        )
        queue.async { [weak session] in
            guard let session else {
                completion(.failure(HIDMIClientError.message(String(localized: "error.not_connected"))))
                return
            }
            do {
                for report in reports {
                    try session.sendMouseReport(report)
                }
                completion(.success(reports.count))
            } catch {
                HIDMIInputTrace.log("write_error", fields: ["error": "\(error)"])
                completion(.failure(error))
            }
        }
    }
}

private final class HIDMISessionKeyboardReportWriter: HIDMIKeyboardReportWriting, @unchecked Sendable {
    private weak var session: HIDMISession?
    private let queue = DispatchQueue(label: "io.github.zhao-zirui.hidmi.keyboard-writer", qos: .userInteractive)

    init(session: HIDMISession) {
        self.session = session
    }

    func enqueueKeyboardReports(
        _ reports: [HIDMISampledInputReport],
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        guard !reports.isEmpty else {
            completion(.success(0))
            return
        }
        HIDMIInputTrace.log(
            "keyboard_enqueue",
            fields: [
                "count": "\(reports.count)",
                "sample_mono_us": "\(reports.first?.sampleMonoUs ?? 0)"
            ]
        )
        queue.async { [weak session] in
            guard let session else {
                completion(.failure(HIDMIClientError.message(String(localized: "error.not_connected"))))
                return
            }
            do {
                for report in reports {
                    try session.sendKeyboardReport(report)
                }
                completion(.success(reports.count))
            } catch {
                HIDMIInputTrace.log("keyboard_write_error", fields: ["error": "\(error)"])
                completion(.failure(error))
            }
        }
    }

    func enqueueCtrlAltDel(
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        HIDMIInputTrace.log("keyboard_enqueue", fields: ["special": "ctrl_alt_del"])
        queue.async { [weak session] in
            guard let session else {
                completion(.failure(HIDMIClientError.message(String(localized: "error.not_connected"))))
                return
            }
            do {
                try session.sendKeyboardSpecialReliable(.keyboardSpecialCtrlAltDel)
                completion(.success(()))
            } catch {
                HIDMIInputTrace.log("keyboard_write_error", fields: ["error": "\(error)", "special": "ctrl_alt_del"])
                completion(.failure(error))
            }
        }
    }
}

final class HIDMISession: @unchecked Sendable {
    private let device: HIDMIDevice
    private let control: HIDMITCPChannel
    private let mouse: HIDMITCPChannel
    private let keyboard: HIDMITCPChannel
    private let stateLock = NSLock()
    private let mouseSendLock = NSLock()
    private let keyboardSendLock = NSLock()
    private var isClosed = false
    private var negotiatedCapabilities = Set(["keyboard", "mouse", "release_all", "absolute_pointer"])
    private var heartbeatSeq: UInt32 = 0
    private var mouseFrameState = HIDMIMouseFrameState()
    private var keyboardFrameState = HIDMIKeyboardFrameState()
    private lazy var sessionMouseWriter = HIDMISessionMouseReportWriter(session: self)
    private lazy var sessionKeyboardWriter = HIDMISessionKeyboardReportWriter(session: self)

    init(device: HIDMIDevice, timeout: TimeInterval, establishedIOTimeout: TimeInterval) throws {
        self.device = device
        control = try HIDMITCPChannel(host: device.host, port: device.controlTCPPort, channelID: .channelControl, sessionID: device.sessionIDValue, timeout: timeout)
        mouse = try HIDMITCPChannel(host: device.host, port: device.mouseTCPPort, channelID: .channelMouse, sessionID: device.sessionIDValue, timeout: timeout)
        keyboard = try HIDMITCPChannel(host: device.host, port: device.keyboardTCPPort, channelID: .channelKeyboard, sessionID: device.sessionIDValue, timeout: timeout)

        do {
            try control.open()
            try mouse.open()
            try keyboard.open()
            try control.setDefaultTimeout(establishedIOTimeout)
            try mouse.setDefaultTimeout(establishedIOTimeout)
            try keyboard.setDefaultTimeout(establishedIOTimeout)
        } catch {
            control.close()
            mouse.close()
            keyboard.close()
            throw error
        }
    }

    convenience init(host: String, port: Int, timeout: TimeInterval) throws {
        let validated = try HIDMIProtocolLimits.validatedPort(port)
        let device = HIDMIDevice(
            host: host,
            udpPort: HIDMIClient.defaultUDPPort,
            tcpPort: validated,
            deviceID: host,
            deviceName: host,
            sessionID: "1",
            serverNonce: "",
            clientID: "1",
            clientNonce: "",
            requiresAuth: false,
            capabilities: [],
            sessionIDValue: 1
        )
        try self.init(device: device, timeout: timeout, establishedIOTimeout: timeout)
    }

    deinit {
        close(releaseAll: false)
    }

    var serverCapabilities: Set<String> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return negotiatedCapabilities
    }

    var mouseWriter: any HIDMIMouseReportWriting {
        sessionMouseWriter
    }

    var keyboardWriter: any HIDMIKeyboardReportWriting {
        sessionKeyboardWriter
    }

    func setNegotiatedCapabilities(_ capabilities: Set<String>) {
        stateLock.lock()
        negotiatedCapabilities = capabilities
        stateLock.unlock()
    }

    func setDefaultTimeout(_ timeout: TimeInterval) throws {
        try control.setDefaultTimeout(timeout)
        try mouse.setDefaultTimeout(timeout)
        try keyboard.setDefaultTimeout(timeout)
    }

    func sendReleaseAllBestEffort(timeout: TimeInterval) throws {
        try control.sendWithTemporaryTimeout(frame(body: .releaseAll(Hidmi_Kvm_Input_V1_ReleaseAll.with {
            $0.reason = "best_effort"
        }), channel: .channelControl, ackRequired: false), timeout: timeout)
    }

    func sendHeartbeat() throws {
        heartbeatSeq &+= 1
        let seq = heartbeatSeq
        let sentAt = HIDMIMonotonic.microseconds()
        let response = try control.sendAndReceive(frame(body: .heartbeat(Hidmi_Kvm_Input_V1_Heartbeat.with {
            $0.heartbeatSeq = seq
            $0.clientSendMonoUs = sentAt
        }), channel: .channelControl, seq: seq, ackRequired: true))
        guard case .heartbeatAck(let ack)? = response.body,
              ack.heartbeatSeq == seq,
              ack.clientSendMonoUs == sentAt else {
            HIDMIInputTrace.log(
                "protocol_mismatch",
                fields: ["context": "heartbeat_ack", "seq": "\(seq)"]
            )
            throw HIDMIClientError.message(String(localized: "error.protocol_failure"))
        }
    }

    func sendKeyboardState(modifiers: Int, keys: [Int]) throws {
        try sendKeyboardReport(
            HIDMISampledInputReport(
                report: .keyboard(modifiers: modifiers, keys: keys),
                sampleMonoUs: HIDMIMonotonic.microseconds()
            )
        )
    }

    @discardableResult
    func sendKeyboardReport(_ report: HIDMISampledInputReport) throws -> UInt32 {
        guard case .keyboard(let modifiers, let keys) = report.report else {
            throw HIDMIClientError.message(String(localized: "error.protocol_failure"))
        }
        keyboardSendLock.lock()
        defer { keyboardSendLock.unlock() }

        let request = keyboardFrameState.makeKeyboardStateFrame(
            sessionID: device.sessionIDValue,
            modifiers: modifiers,
            keys: keys
        )
        try sendKeyboardFrameWithAck(
            request,
            reportName: "keyboard",
            sampleMonoUs: report.sampleMonoUs
        )
        return request.seq
    }

    func sendKeyboardSpecial(_ special: Hidmi_Kvm_Input_V1_KeyboardSpecialId) throws {
        try sendKeyboardSpecialReliable(special)
    }

    func sendKeyboardSpecialReliable(_ special: Hidmi_Kvm_Input_V1_KeyboardSpecialId) throws {
        keyboardSendLock.lock()
        defer { keyboardSendLock.unlock() }

        let request = keyboardFrameState.makeKeyboardSpecialFrame(
            sessionID: device.sessionIDValue,
            special: special
        )
        try sendKeyboardFrameWithAck(
            request,
            reportName: "keyboard_special",
            sampleMonoUs: nil
        )
    }

    private func sendKeyboardFrameWithAck(
        _ request: Hidmi_Kvm_Input_V1_TcpFrame,
        reportName: String,
        sampleMonoUs: UInt64?
    ) throws {
        let seq = request.seq
        let deadline = Date().addingTimeInterval(3)
        var attempt = 0

        while true {
            attempt += 1
            var fields = [
                "attempt": "\(attempt)",
                "report": reportName,
                "seq": "\(seq)"
            ]
            if let sampleMonoUs {
                fields["sample_mono_us"] = "\(sampleMonoUs)"
            }
            HIDMIInputTrace.log("keyboard_write_start", fields: fields)
            try keyboard.send(request)
            do {
                let ackFrame = try keyboard.withTemporaryTimeout(0.1) {
                    try keyboard.receive()
                }
                if case .ack(let ack)? = ackFrame.body,
                   ack.targetChannelID == .channelKeyboard,
                   ack.targetSeq == seq,
                   ack.result == .ackOk || ack.result == .ackDuplicated {
                    HIDMIInputTrace.log(
                        "keyboard_ack_received",
                        fields: [
                            "result": "\(ack.result)",
                            "seq": "\(seq)"
                        ]
                    )
                    HIDMIInputTrace.log("keyboard_write_done", fields: fields)
                    return
                }
                if case .error(let error)? = ackFrame.body {
                    let clientError = HIDMIClientError.server(code: "KEYBOARD_ERROR", detail: error.errMsg)
                    if clientError.connectionFailureKind == .hidFailure {
                        HIDMIInputTrace.log(
                            "server_error_hid",
                            fields: ["channel": "\(error.channelID.rawValue)", "related_seq": "\(error.relatedSeq)"]
                        )
                    }
                    throw clientError
                }
            } catch let error as HIDMIClientError {
                if case .posix(_, let code) = error, code == EAGAIN || code == EWOULDBLOCK {
                    if Date() < deadline {
                        HIDMIInputTrace.log(
                            "keyboard_retry",
                            fields: [
                                "attempt": "\(attempt)",
                                "reason": "ack_timeout",
                                "seq": "\(seq)"
                            ]
                        )
                        continue
                    }
                }
                throw error
            }
            if Date() >= deadline {
                throw HIDMIClientError.message(String(localized: "error.device_response_timeout"))
            }
            HIDMIInputTrace.log(
                "keyboard_retry",
                fields: [
                    "attempt": "\(attempt)",
                    "reason": "unexpected_frame",
                    "seq": "\(seq)"
                ]
            )
        }
    }

    @discardableResult
    func sendMouseReport(_ report: HIDMISampledInputReport) throws -> UInt32 {
        mouseSendLock.lock()
        defer { mouseSendLock.unlock() }

        let frame = try mouseFrameState.makeFrame(
            sessionID: device.sessionIDValue,
            report: report.report,
            sampleMonoUs: report.sampleMonoUs
        )
        HIDMIInputTrace.log(
            "write_start",
            fields: [
                "report": report.report.traceName,
                "seq": "\(frame.seq)",
                "sample_mono_us": "\(report.sampleMonoUs)"
            ]
        )
        try mouse.send(frame)
        HIDMIInputTrace.log(
            "write_done",
            fields: [
                "report": report.report.traceName,
                "seq": "\(frame.seq)",
                "sample_mono_us": "\(report.sampleMonoUs)"
            ]
        )
        return frame.seq
    }

    func close(releaseAll: Bool = true) {
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return
        }
        isClosed = true
        stateLock.unlock()

        if releaseAll {
            try? sendReleaseAllBestEffort(timeout: 0.2)
            try? control.send(frame(body: .goodbye(Hidmi_Kvm_Input_V1_Goodbye.with {
                $0.reason = .goodbyeClientExit
                $0.message = "client closing"
            }), channel: .channelControl, ackRequired: false))
        }
        control.close()
        mouse.close()
        keyboard.close()
    }

    private func frame(
        body: Hidmi_Kvm_Input_V1_TcpFrame.OneOf_Body,
        channel: Hidmi_Kvm_Input_V1_ChannelId,
        seq: UInt32 = 0,
        ackRequired: Bool
    ) -> Hidmi_Kvm_Input_V1_TcpFrame {
        Hidmi_Kvm_Input_V1_TcpFrame.with {
            $0.sessionID = device.sessionIDValue
            $0.channelID = channel
            $0.seq = seq
            $0.monotonicUs = HIDMIMonotonic.microseconds()
            $0.ackRequired = ackRequired
            $0.body = body
        }
    }
}

private final class HIDMITCPChannel: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let channelID: Hidmi_Kvm_Input_V1_ChannelId
    private let sessionID: UInt64
    private var fd: Int32 = -1
    private let ioLock = NSLock()
    private var defaultTimeout: TimeInterval

    init(host: String, port: Int, channelID: Hidmi_Kvm_Input_V1_ChannelId, sessionID: UInt64, timeout: TimeInterval) throws {
        self.host = host
        self.port = try HIDMIProtocolLimits.validatedPort(port)
        self.channelID = channelID
        self.sessionID = sessionID
        self.defaultTimeout = HIDMIProtocolLimits.normalizedTimeout(timeout)
        let openedFD = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if openedFD < 0 {
            throw HIDMIClientError.posix("socket", errno)
        }
        do {
            var suppressSIGPIPE: Int32 = 1
            setsockopt(openedFD, SOL_SOCKET, SO_NOSIGPIPE, &suppressSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
            var noDelay: Int32 = 1
            setsockopt(openedFD, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
            try HIDMIClient.setTimeout(timeout, fd: openedFD)
            fd = openedFD
        } catch {
            Darwin.close(openedFD)
            throw error
        }
    }

    deinit {
        close()
    }

    func open() throws {
        var address = try HIDMIClient.ipv4Address(host: host, port: port)
        ioLock.lock()
        let currentFD: Int32
        do {
            currentFD = try openFDUnlocked()
        } catch {
            ioLock.unlock()
            throw error
        }
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(currentFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let connectErrno = errno
        ioLock.unlock()
        if connectResult != 0 {
            throw HIDMIClientError.posix("connect", connectErrno)
        }
        let response = try sendAndReceive(Hidmi_Kvm_Input_V1_TcpFrame.with {
            $0.sessionID = sessionID
            $0.channelID = channelID
            $0.seq = 1
            $0.monotonicUs = HIDMIMonotonic.microseconds()
            $0.ackRequired = true
            $0.channelOpen = Hidmi_Kvm_Input_V1_ChannelOpen.with {
                $0.expectedChannelID = channelID
            }
        })
        guard case .channelReady(let ready)? = response.body,
              ready.accepted,
              ready.channelID == channelID else {
            HIDMIInputTrace.log(
                "protocol_mismatch",
                fields: ["context": "channel_ready", "channel": "\(channelID.rawValue)"]
            )
            throw HIDMIClientError.message(String(localized: "error.protocol_failure"))
        }
    }

    func setDefaultTimeout(_ timeout: TimeInterval) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        let normalized = HIDMIProtocolLimits.normalizedTimeout(timeout)
        try HIDMIClient.setTimeout(normalized, fd: openFDUnlocked())
        defaultTimeout = normalized
    }

    func withTemporaryTimeout<T>(_ timeout: TimeInterval, _ body: () throws -> T) throws -> T {
        ioLock.lock()
        let previous = defaultTimeout
        let currentFD: Int32
        do {
            currentFD = try openFDUnlocked()
            try HIDMIClient.setTimeout(timeout, fd: currentFD)
        } catch {
            ioLock.unlock()
            throw error
        }
        do {
            let value = try body()
            try? HIDMIClient.setTimeout(previous, fd: currentFD)
            ioLock.unlock()
            return value
        } catch {
            try? HIDMIClient.setTimeout(previous, fd: currentFD)
            ioLock.unlock()
            throw error
        }
    }

    func sendAndReceive(_ frame: Hidmi_Kvm_Input_V1_TcpFrame) throws -> Hidmi_Kvm_Input_V1_TcpFrame {
        ioLock.lock()
        defer { ioLock.unlock() }
        try writeFrameUnlocked(frame)
        return try readFrameUnlocked()
    }

    func send(_ frame: Hidmi_Kvm_Input_V1_TcpFrame) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        try writeFrameUnlocked(frame)
    }

    func sendWithTemporaryTimeout(_ frame: Hidmi_Kvm_Input_V1_TcpFrame, timeout: TimeInterval) throws {
        ioLock.lock()
        let previous = defaultTimeout
        let currentFD: Int32
        do {
            currentFD = try openFDUnlocked()
            try HIDMIClient.setTimeout(timeout, fd: currentFD)
        } catch {
            ioLock.unlock()
            throw error
        }
        do {
            try writeFrameUnlocked(frame)
            try? HIDMIClient.setTimeout(previous, fd: currentFD)
            ioLock.unlock()
        } catch {
            try? HIDMIClient.setTimeout(previous, fd: currentFD)
            ioLock.unlock()
            throw error
        }
    }

    func receive() throws -> Hidmi_Kvm_Input_V1_TcpFrame {
        try readFrameUnlocked()
    }

    func close() {
        ioLock.lock()
        let currentFD = fd
        fd = -1
        ioLock.unlock()

        guard currentFD >= 0 else { return }
        Darwin.shutdown(currentFD, SHUT_RDWR)
        Darwin.close(currentFD)
    }

    private func openFDUnlocked() throws -> Int32 {
        guard fd >= 0 else {
            throw HIDMIClientError.message(String(localized: "error.socket_closed"))
        }
        return fd
    }

    private func writeFrameUnlocked(_ frame: Hidmi_Kvm_Input_V1_TcpFrame) throws {
        let payload = try frame.serializedData()
        guard payload.count <= HIDMIProtocolLimits.maximumFrameBytes else {
            throw HIDMIClientError.message(String(localized: "error.response_too_large"))
        }
        var data = Data()
        data.appendBigEndian(UInt32(payload.count))
        data.append(payload)
        try writeAll(data)
    }

    private func readFrameUnlocked() throws -> Hidmi_Kvm_Input_V1_TcpFrame {
        let lengthData = try readExact(count: 4)
        let lengthBytes = [UInt8](lengthData)
        let length = Int(UInt32(lengthBytes[0]) << 24 | UInt32(lengthBytes[1]) << 16 | UInt32(lengthBytes[2]) << 8 | UInt32(lengthBytes[3]))
        guard length <= HIDMIProtocolLimits.maximumFrameBytes else {
            throw HIDMIClientError.message(String(localized: "error.response_too_large"))
        }
        let payload = try readExact(count: length)
        let frame = try Hidmi_Kvm_Input_V1_TcpFrame(serializedBytes: payload)
        guard frame.sessionID == sessionID,
              frame.channelID == channelID || frame.channelID == .channelUnspecified else {
            HIDMIInputTrace.log(
                "protocol_mismatch",
                fields: [
                    "context": "tcp_frame",
                    "expected_channel": "\(channelID.rawValue)",
                    "actual_channel": "\(frame.channelID.rawValue)",
                    "expected_session": "\(sessionID)",
                    "actual_session": "\(frame.sessionID)"
                ]
            )
            throw HIDMIClientError.message(String(localized: "error.protocol_failure"))
        }
        if case .error(let error)? = frame.body {
            let clientError = HIDMIClientError.server(code: "ERROR", detail: error.errMsg)
            if clientError.connectionFailureKind == .hidFailure {
                HIDMIInputTrace.log(
                    "server_error_hid",
                    fields: ["channel": "\(error.channelID.rawValue)", "related_seq": "\(error.relatedSeq)"]
                )
            }
            throw clientError
        }
        return frame
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            let currentFD = try openFDUnlocked()
            while sent < data.count {
                let result = Darwin.write(currentFD, baseAddress.advanced(by: sent), data.count - sent)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw HIDMIClientError.posix("write", errno)
                }
                if result == 0 {
                    throw HIDMIClientError.message(String(localized: "error.socket_closed_writing"))
                }
                sent += result
            }
        }
    }

    private func readExact(count: Int) throws -> Data {
        var data = Data(count: count)
        var received = 0
        let currentFD = try openFDUnlocked()
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while received < count {
                let result = Darwin.read(currentFD, baseAddress.advanced(by: received), count - received)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw HIDMIClientError.posix("read", errno)
                }
                if result == 0 {
                    throw HIDMIClientError.message(String(localized: "error.socket_closed"))
                }
                received += result
            }
        }
        return data
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
