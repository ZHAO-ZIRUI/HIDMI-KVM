import AppKit
import Darwin
import Foundation

struct RemoteAbsolutePointer: Sendable, Equatable {
    let x: Int
    let y: Int
}

enum RemoteInputEvent {
    case keyDown(NSEvent)
    case keyUp(NSEvent)
    case flagsChanged(NSEvent)
    case mouseDown(NSEvent, button: Int, absolute: RemoteAbsolutePointer?)
    case mouseUp(NSEvent, button: Int, absolute: RemoteAbsolutePointer?)
    case mouseMoved(NSEvent, scale: CGSize, absolute: RemoteAbsolutePointer?)
    case scrollWheel(NSEvent)
}

enum RemoteInputReport: Equatable, Sendable {
    case keyboard(modifiers: Int, keys: [Int])
    case mouse(buttons: Int, dx: Int, dy: Int, wheel: Int)
    case absoluteMouse(buttons: Int, x: Int, y: Int, dx: Int = 0, dy: Int = 0)
}

struct HIDMISampledInputReport: Equatable, Sendable {
    let report: RemoteInputReport
    let sampleMonoUs: UInt64
}

protocol HIDMIMouseReportWriting: Sendable {
    func enqueueMouseReports(
        _ reports: [HIDMISampledInputReport],
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    )
}

protocol HIDMIKeyboardReportWriting: Sendable {
    func enqueueKeyboardReports(
        _ reports: [HIDMISampledInputReport],
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    )

    func enqueueCtrlAltDel(
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    )
}

enum HIDMIMonotonic {
    static func microseconds() -> UInt64 {
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC_RAW, &now)
        return UInt64(now.tv_sec) * 1_000_000 + UInt64(now.tv_nsec) / 1_000
    }
}

enum HIDMIInputTrace {
    static let isEnabled = ProcessInfo.processInfo.environment["HIDMI_INPUT_TRACE"] == "1"

    static func log(_ stage: String, fields: [String: String] = [:]) {
        guard isEnabled else { return }
        var parts = [
            "hidmi_input_trace",
            "stage=\(stage)",
            "mono_us=\(HIDMIMonotonic.microseconds())"
        ]
        for key in fields.keys.sorted() {
            if let value = fields[key] {
                parts.append("\(key)=\(value.replacingOccurrences(of: " ", with: "_"))")
            }
        }
        fputs(parts.joined(separator: " ") + "\n", stderr)
    }
}

extension RemoteInputReport {
    var isMouseReport: Bool {
        switch self {
        case .mouse, .absoluteMouse:
            return true
        case .keyboard:
            return false
        }
    }

    var isKeyboardReport: Bool {
        switch self {
        case .keyboard:
            return true
        case .mouse, .absoluteMouse:
            return false
        }
    }

    var traceName: String {
        switch self {
        case .keyboard:
            return "keyboard"
        case .mouse:
            return "mouse"
        case .absoluteMouse:
            return "absolute_mouse"
        }
    }
}

extension RemoteInputEvent {
    var traceName: String {
        switch self {
        case .keyDown:
            return "key_down"
        case .keyUp:
            return "key_up"
        case .flagsChanged:
            return "flags_changed"
        case .mouseDown:
            return "mouse_down"
        case .mouseUp:
            return "mouse_up"
        case .mouseMoved:
            return "mouse_moved"
        case .scrollWheel:
            return "scroll_wheel"
        }
    }

    func mappedEmptyReason(preferAbsolute: Bool) -> String {
        switch self {
        case .mouseMoved(_, _, nil) where preferAbsolute:
            return "absolute_pointer_unavailable"
        case .mouseMoved:
            return "zero_relative_delta"
        case .scrollWheel:
            return "zero_scroll_delta"
        case .keyDown:
            return "ignored_key_down"
        case .keyUp:
            return "ignored_key_up"
        case .flagsChanged:
            return "ignored_flags_changed"
        case .mouseDown, .mouseUp:
            return "missing_absolute_pointer"
        }
    }
}

struct RemoteInputMapper {
    private var modifiers = 0
    private var pressedKeys = [UInt16: Int]()
    private var pressedButtons = 0
    private var residualMouseX: CGFloat = 0
    private var residualMouseY: CGFloat = 0
    private var lastAbsolutePointer: RemoteAbsolutePointer?

    mutating func reset() -> [RemoteInputReport] {
        var releaseReports = [RemoteInputReport]()
        releaseReports.append(.keyboard(modifiers: 0, keys: []))
        if pressedButtons != 0 {
            releaseReports.append(.mouse(buttons: 0, dx: 0, dy: 0, wheel: 0))
        }
        if let pointer = lastAbsolutePointer {
            releaseReports.append(.absoluteMouse(buttons: 0, x: pointer.x, y: pointer.y))
        }
        modifiers = 0
        pressedKeys.removeAll()
        pressedButtons = 0
        residualMouseX = 0
        residualMouseY = 0
        lastAbsolutePointer = nil
        return releaseReports
    }

    mutating func map(_ event: RemoteInputEvent, preferAbsolute: Bool = false) -> [RemoteInputReport] {
        switch event {
        case .keyDown(let nsEvent):
            if nsEvent.modifierFlags.contains(.command) {
                return []
            }
            guard !nsEvent.isARepeat,
                  let (usage, eventModifiers) = Self.keyUsageAndModifiers(for: nsEvent) else {
                return []
            }
            pressedKeys[nsEvent.keyCode] = usage
            return [keyboardReport(modifiers: modifiers | eventModifiers)]

        case .keyUp(let nsEvent):
            guard Self.keyUsage(for: nsEvent.keyCode) != nil else {
                return []
            }
            pressedKeys.removeValue(forKey: nsEvent.keyCode)
            return [keyboardReport()]

        case .flagsChanged(let nsEvent):
            guard let modifier = Self.modifierBit(for: nsEvent.keyCode) else {
                return []
            }
            if Self.modifierIsPressed(nsEvent) {
                modifiers |= modifier
            } else {
                modifiers &= ~modifier
            }
            return [keyboardReport()]

        case .mouseDown(_, let button, let absolute):
            pressedButtons |= button
            if preferAbsolute {
                return absoluteMouseReport(buttons: pressedButtons, absolute: absolute)
            }
            return [.mouse(buttons: pressedButtons, dx: 0, dy: 0, wheel: 0)]

        case .mouseUp(_, let button, let absolute):
            pressedButtons &= ~button
            if preferAbsolute {
                return absoluteMouseReport(buttons: pressedButtons, absolute: absolute)
            }
            return [.mouse(buttons: pressedButtons, dx: 0, dy: 0, wheel: 0)]

        case .mouseMoved(let nsEvent, let scale, let absolute):
            let dx = Self.scaledIntegerDelta(nsEvent.deltaX, scale: scale.width, residual: &residualMouseX)
            let dy = Self.scaledIntegerDelta(nsEvent.deltaY, scale: scale.height, residual: &residualMouseY)
            if preferAbsolute {
                guard let absolute else { return [] }
                lastAbsolutePointer = absolute
                return [.absoluteMouse(buttons: pressedButtons, x: absolute.x, y: absolute.y, dx: dx, dy: dy)]
            }
            guard dx != 0 || dy != 0 else {
                return []
            }
            return Self.splitMouseReports(buttons: pressedButtons, dx: dx, dy: dy, wheel: 0)

        case .scrollWheel(let nsEvent):
            let wheel = Self.clampedDelta(nsEvent.scrollingDeltaY)
            guard wheel != 0 else {
                return []
            }
            return [.mouse(buttons: pressedButtons, dx: 0, dy: 0, wheel: wheel)]
        }
    }

    private mutating func absoluteMouseReport(buttons: Int, absolute: RemoteAbsolutePointer?) -> [RemoteInputReport] {
        if let absolute {
            lastAbsolutePointer = absolute
        }
        guard let pointer = absolute ?? lastAbsolutePointer else {
            return []
        }
        return [.absoluteMouse(buttons: buttons, x: pointer.x, y: pointer.y)]
    }

    private func keyboardReport(modifiers overrideModifiers: Int? = nil) -> RemoteInputReport {
        let keys = Array(pressedKeys.values.prefix(6))
        return .keyboard(modifiers: overrideModifiers ?? modifiers, keys: keys)
    }

    private static func scaledIntegerDelta(_ value: CGFloat, scale: CGFloat, residual: inout CGFloat) -> Int {
        let scaled = value * max(scale, 0.01) + residual
        let whole = scaled >= 0 ? floor(scaled) : ceil(scaled)
        residual = scaled - whole
        return Int(whole)
    }

    private static func splitMouseReports(buttons: Int, dx: Int, dy: Int, wheel: Int) -> [RemoteInputReport] {
        var remainingX = dx
        var remainingY = dy
        var remainingWheel = wheel
        var reports = [RemoteInputReport]()

        repeat {
            let stepX = clampedReportValue(remainingX)
            let stepY = clampedReportValue(remainingY)
            let stepWheel = clampedReportValue(remainingWheel)
            reports.append(.mouse(buttons: buttons, dx: stepX, dy: stepY, wheel: stepWheel))
            remainingX -= stepX
            remainingY -= stepY
            remainingWheel -= stepWheel
        } while remainingX != 0 || remainingY != 0 || remainingWheel != 0

        return reports
    }

    private static func clampedReportValue(_ value: Int) -> Int {
        min(127, max(-127, value))
    }

    private static func clampedDelta(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        return min(127, max(-127, rounded))
    }

    private static func modifierIsPressed(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 56, 60:
            return event.modifierFlags.contains(.shift)
        case 59, 62:
            return event.modifierFlags.contains(.control)
        case 58, 61:
            return event.modifierFlags.contains(.option)
        case 55, 54:
            return event.modifierFlags.contains(.command)
        default:
            return false
        }
    }

    private static func modifierBit(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 59: return 0x01
        case 56: return 0x02
        case 58: return 0x04
        case 55: return 0x08
        case 62: return 0x10
        case 60: return 0x20
        case 61: return 0x40
        case 54: return 0x80
        default: return nil
        }
    }

    private static func keyUsage(for keyCode: UInt16) -> Int? {
        keyUsages[keyCode]
    }

    private static func keyUsageAndModifiers(for event: NSEvent) -> (usage: Int, modifiers: Int)? {
        if let character = event.characters?.first,
           let mapped = characterUsages[character] {
            return mapped
        }
        guard let usage = keyUsage(for: event.keyCode) else {
            return nil
        }
        return (usage, modifierBits(from: event.modifierFlags))
    }

    private static func modifierBits(from flags: NSEvent.ModifierFlags) -> Int {
        var bits = 0
        if flags.contains(.control) {
            bits |= 0x01
        }
        if flags.contains(.shift) {
            bits |= 0x02
        }
        if flags.contains(.option) {
            bits |= 0x04
        }
        return bits
    }

    private static let keyUsages: [UInt16: Int] = [
        0: 0x04,
        11: 0x05,
        8: 0x06,
        2: 0x07,
        14: 0x08,
        3: 0x09,
        5: 0x0A,
        4: 0x0B,
        34: 0x0C,
        38: 0x0D,
        40: 0x0E,
        37: 0x0F,
        46: 0x10,
        45: 0x11,
        31: 0x12,
        35: 0x13,
        12: 0x14,
        15: 0x15,
        1: 0x16,
        17: 0x17,
        32: 0x18,
        9: 0x19,
        13: 0x1A,
        7: 0x1B,
        16: 0x1C,
        6: 0x1D,

        18: 0x1E,
        19: 0x1F,
        20: 0x20,
        21: 0x21,
        23: 0x22,
        22: 0x23,
        26: 0x24,
        28: 0x25,
        25: 0x26,
        29: 0x27,

        36: 0x28,
        53: 0x29,
        51: 0x2A,
        48: 0x2B,
        49: 0x2C,
        27: 0x2D,
        24: 0x2E,
        33: 0x2F,
        30: 0x30,
        42: 0x31,
        41: 0x32,
        39: 0x33,
        43: 0x36,
        47: 0x37,
        44: 0x38,

        122: 0x3A,
        120: 0x3B,
        99: 0x3C,
        118: 0x3D,
        96: 0x3E,
        97: 0x3F,
        98: 0x40,
        100: 0x41,
        101: 0x42,
        109: 0x43,
        103: 0x44,
        111: 0x45,

        114: 0x49,
        115: 0x4A,
        116: 0x4B,
        117: 0x4C,
        119: 0x4D,
        121: 0x4E,
        123: 0x50,
        124: 0x4F,
        125: 0x51,
        126: 0x52,

        82: 0x62,
        83: 0x59,
        84: 0x5A,
        85: 0x5B,
        86: 0x5C,
        87: 0x5D,
        88: 0x5E,
        89: 0x5F,
        91: 0x60,
        92: 0x61,
        65: 0x63
    ]

    private static let characterUsages: [Character: (usage: Int, modifiers: Int)] = {
        var values = [Character: (usage: Int, modifiers: Int)]()
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        for (index, letter) in letters.enumerated() {
            let usage = 0x04 + index
            values[letter] = (usage, 0)
            values[Character(letter.uppercased())] = (usage, 0x02)
        }

        let digits: [(Character, Character, Int)] = [
            ("1", "!", 0x1E),
            ("2", "@", 0x1F),
            ("3", "#", 0x20),
            ("4", "$", 0x21),
            ("5", "%", 0x22),
            ("6", "^", 0x23),
            ("7", "&", 0x24),
            ("8", "*", 0x25),
            ("9", "(", 0x26),
            ("0", ")", 0x27)
        ]
        for (plain, shifted, usage) in digits {
            values[plain] = (usage, 0)
            values[shifted] = (usage, 0x02)
        }

        let punctuation: [(Character, Character, Int)] = [
            ("-", "_", 0x2D),
            ("=", "+", 0x2E),
            ("[", "{", 0x2F),
            ("]", "}", 0x30),
            ("\\", "|", 0x31),
            (";", ":", 0x33),
            ("'", "\"", 0x34),
            ("`", "~", 0x35),
            (",", "<", 0x36),
            (".", ">", 0x37),
            ("/", "?", 0x38)
        ]
        for (plain, shifted, usage) in punctuation {
            values[plain] = (usage, 0)
            values[shifted] = (usage, 0x02)
        }

        values[" "] = (0x2C, 0)
        values["\t"] = (0x2B, 0)
        values["\n"] = (0x28, 0)
        values["\r"] = (0x28, 0)
        return values
    }()
}
