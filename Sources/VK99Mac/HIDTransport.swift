import Foundation
import IOKit.hid

enum VK99Error: Error, CustomStringConvertible {
    case noInterface(page: Int)
    case ambiguousInterface(page: Int, count: Int)
    case openFailed(code: IOReturn)
    case reportFailed(code: IOReturn)
    case invalidLength(expected: Int, actual: Int)
    case invalidHex
    case unsupportedConnection
    case invalidClockYear(Int)
    case invalidScreenIndex
    case controlNotAcknowledged(code: UInt8, responseByte: UInt8?)

    var description: String {
        switch self {
        case .noInterface(let page): return String(format: "No VK99 HID interface on page 0x%04X", page)
        case .ambiguousInterface(let page, let count): return String(format: "Found %d VK99 interfaces on page 0x%04X; disconnect extra keyboards", count, page)
        case .openFailed(let code): return String(format: "Could not open HID interface: 0x%08X", code)
        case .reportFailed(let code): return String(format: "HID report failed: 0x%08X", code)
        case .invalidLength(let expected, let actual): return "Expected \(expected) bytes, got \(actual)"
        case .invalidHex: return "Expected an even number of hexadecimal digits"
        case .unsupportedConnection: return "This command currently supports a VK99 TFT (Valkyrie-99pro) connected directly by USB"
        case .invalidClockYear(let year): return "Clock protocol cannot encode year \(year)"
        case .invalidScreenIndex: return "Screen index must be 1, 2, or 3"
        case .controlNotAcknowledged(let code, let byte):
            return String(format: "Clock control 0x%02X was not acknowledged (response byte 3: %@)",
                          code, byte.map { String(format: "0x%02X", $0) } ?? "missing")
        }
    }
}

struct ClockDiagnosticStep: Codable {
    let name: String
    let sentHex: String
    let setReportStatus: String
    let getReportStatus: String?
    let receivedHex: String?
    let responseByte3: Int?
    let matchesWindowsAckCheck: Bool?
    let isWriteEcho: Bool?
}

struct ClockDiagnostic: Codable {
    let capturedAt: Date
    let product: String
    let transport: String
    let screenIndex: Int
    let steps: [ClockDiagnosticStep]
}

struct VK99Transport {
    static let featurePage = 0xFF13
    static let outputPage = 0xFF68
    static let featureBytes = 64
    static let outputBytes = 4096

    private static let knownProducts: Set<String> = [
        "Valkyrie-99", "Valkyrie-99pro", "VK99Pro Wireless Receiver", "2.4G Wireless Receiver"
    ]

    static func withDevice<T>(page: Int, _ body: (IOHIDDevice) throws -> T) throws -> T {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x024F,
            kIOHIDPrimaryUsagePageKey: page
        ] as CFDictionary)
        let candidates = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []).filter {
            guard let product = IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String,
                  let usage = IOHIDDeviceGetProperty($0, kIOHIDPrimaryUsageKey as CFString) as? NSNumber else { return false }
            return knownProducts.contains(product) && usage.intValue == (page == featurePage ? 1 : 0x61)
        }
        guard !candidates.isEmpty else { throw VK99Error.noInterface(page: page) }
        guard candidates.count == 1, let device = candidates.first else {
            throw VK99Error.ambiguousInterface(page: page, count: candidates.count)
        }
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else { throw VK99Error.openFailed(code: status) }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        return try body(device)
    }

    static func readFeature() throws -> [UInt8] {
        try withDevice(page: featurePage) { device in
            var bytes = [UInt8](repeating: 0, count: featureBytes)
            var length = CFIndex(bytes.count)
            let status = bytes.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, &length)
            }
            guard status == kIOReturnSuccess else { throw VK99Error.reportFailed(code: status) }
            return Array(bytes.prefix(length))
        }
    }

    static func writeFeature(_ bytes: [UInt8]) throws {
        guard bytes.count == featureBytes else {
            throw VK99Error.invalidLength(expected: featureBytes, actual: bytes.count)
        }
        try withDevice(page: featurePage) { device in
            try sendFeature(bytes, to: device)
        }
    }

    static func writeOutput(_ bytes: [UInt8]) throws {
        guard bytes.count == outputBytes else {
            throw VK99Error.invalidLength(expected: outputBytes, actual: bytes.count)
        }
        try withDevice(page: outputPage) { device in
            try sendOutput(bytes, to: device)
        }
    }

    static func uploadTFT(_ packed: [UInt8]) throws {
        guard !packed.isEmpty && packed.count.isMultiple(of: outputBytes) else {
            throw VK99Error.invalidLength(expected: outputBytes, actual: packed.count)
        }
        let blockCount = packed.count / outputBytes
        guard blockCount <= Int(UInt16.max) else {
            throw VK99Error.invalidLength(expected: Int(UInt16.max) * outputBytes, actual: packed.count)
        }
        func command(_ code: UInt8) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: featureBytes)
            bytes[0] = 0x04
            bytes[1] = code
            if code == 0x72 {
                // The Windows sender places the little-endian block count at offsets 8 and 9.
                bytes[8] = UInt8(truncatingIfNeeded: blockCount)
                bytes[9] = UInt8(truncatingIfNeeded: blockCount >> 8)
            }
            return bytes
        }
        try withDevice(page: featurePage) { feature in
            try requireDirectUSB(feature)
            try sendFeature(command(0x18), to: feature)
            Thread.sleep(forTimeInterval: 0.035)
            do {
                try sendFeature(command(0x72), to: feature)
                Thread.sleep(forTimeInterval: 0.035)
                try withDevice(page: outputPage) { output in
                    for start in stride(from: 0, to: packed.count, by: outputBytes) {
                        try sendOutput(Array(packed[start..<(start + outputBytes)]), to: output)
                    }
                }
                try sendFeature(command(0x02), to: feature)
            } catch {
                try? sendFeature(command(0x02), to: feature)
                throw error
            }
        }
    }

    static func clockPacket(at date: Date, screenIndex: UInt8 = 1, timeZone: TimeZone = .current) throws -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        guard let year = parts.year, (2000...2255).contains(year),
              let month = parts.month, let day = parts.day, let hour = parts.hour,
              let minute = parts.minute, let second = parts.second, let weekday = parts.weekday else {
            throw VK99Error.invalidClockYear(parts.year ?? 0)
        }
        var bytes = [UInt8](repeating: 0, count: featureBytes)
        bytes[1] = screenIndex
        bytes[2] = 0x5A
        bytes[3] = UInt8(year - 2000)
        bytes[4] = UInt8(month)
        bytes[5] = UInt8(day)
        bytes[6] = UInt8(hour)
        bytes[7] = UInt8(minute)
        bytes[8] = UInt8(second)
        bytes[10] = UInt8(weekday - 1) // Windows SYSTEMTIME: Sunday = 0.
        bytes[62] = 0xAA
        bytes[63] = 0x55
        return bytes
    }

    static func syncClock(at date: Date = Date()) throws {
        try withDevice(page: featurePage) { device in
            try requireDirectUSB(device)
            func command(_ code: UInt8) -> [UInt8] {
                var bytes = [UInt8](repeating: 0, count: featureBytes)
                bytes[0] = 0x04
                bytes[1] = code
                if code == 0x28 { bytes[8] = 1 }
                return bytes
            }
            func sendAndRead(_ packet: [UInt8], controlCode: UInt8? = nil) throws {
                try sendFeature(packet, to: device)
                Thread.sleep(forTimeInterval: 0.035)
                let response = try readFeature(on: device, seededWith: packet)
                if let controlCode, response.count <= 3 || response[3] != 1 {
                    throw VK99Error.controlNotAcknowledged(
                        code: controlCode, responseByte: response.count > 3 ? response[3] : nil)
                }
            }
            do {
                try sendAndRead(command(0x18), controlCode: 0x18)
                try sendAndRead(command(0x28), controlCode: 0x28)
                // The observed USB response to the time packet is a write echo rather than
                // the Windows control ACK. Reading it is still part of the working sequence.
                try sendAndRead(clockPacket(at: date))
                try sendAndRead(command(0x02), controlCode: 0x02)
            } catch {
                try? sendFeature(command(0x02), to: device)
                throw error
            }
        }
    }

    /// Mirrors the four Windows clock writes and samples Feature GET_REPORT after each one.
    /// A zero SetReport status means the host accepted the transfer, not that the clock changed.
    static func diagnoseClock(at date: Date = Date(), screenIndex: UInt8 = 1) throws -> ClockDiagnostic {
        try withDevice(page: featurePage) { device in
            try requireDirectUSB(device)
            func command(_ code: UInt8) -> [UInt8] {
                var bytes = [UInt8](repeating: 0, count: featureBytes)
                bytes[0] = 0x04
                bytes[1] = code
                if code == 0x28 { bytes[8] = 1 }
                return bytes
            }
            let packets: [(String, [UInt8])] = [
                ("begin 04 18", command(0x18)),
                ("clock mode 04 28", command(0x28)),
                ("local time", try clockPacket(at: date, screenIndex: screenIndex)),
                ("end 04 02", command(0x02))
            ]
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "unknown"
            var steps: [ClockDiagnosticStep] = []
            for (name, packet) in packets {
                let sent = packet.withUnsafeBufferPointer {
                    IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, $0.count)
                }
                let sentStatus = String(format: "0x%08X", UInt32(bitPattern: sent))
                var readStatus: String?
                var received: [UInt8]?
                if sent == kIOReturnSuccess {
                    Thread.sleep(forTimeInterval: 0.035)
                    // Windows passes the sent bytes as the GET_FEATURE input buffer.
                    var buffer = packet
                    var length = CFIndex(buffer.count)
                    let result = buffer.withUnsafeMutableBufferPointer {
                        IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, &length)
                    }
                    readStatus = String(format: "0x%08X", UInt32(bitPattern: result))
                    if result == kIOReturnSuccess { received = Array(buffer.prefix(length)) }
                }
                steps.append(ClockDiagnosticStep(
                    name: name,
                    sentHex: packet.map { String(format: "%02X", $0) }.joined(),
                    setReportStatus: sentStatus,
                    getReportStatus: readStatus,
                    receivedHex: received?.map { String(format: "%02X", $0) }.joined(),
                    responseByte3: received.flatMap { $0.count > 3 ? Int($0[3]) : nil },
                    matchesWindowsAckCheck: received.flatMap { $0.count > 3 ? $0[3] == 1 : nil },
                    isWriteEcho: received.map { $0 == packet }
                ))
                if sent != kIOReturnSuccess { break }
            }
            return ClockDiagnostic(capturedAt: date, product: product, transport: transport,
                                   screenIndex: Int(screenIndex), steps: steps)
        }
    }

    private static func requireDirectUSB(_ device: IOHIDDevice) throws {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
        guard product == "Valkyrie-99pro", transport == "USB" else {
            throw VK99Error.unsupportedConnection
        }
    }

    private static func sendFeature(_ bytes: [UInt8], to device: IOHIDDevice) throws {
        let status = bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, $0.count)
        }
        guard status == kIOReturnSuccess else { throw VK99Error.reportFailed(code: status) }
    }

    private static func readFeature(on device: IOHIDDevice, seededWith packet: [UInt8]) throws -> [UInt8] {
        var bytes = packet
        var length = CFIndex(bytes.count)
        let status = bytes.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, &length)
        }
        guard status == kIOReturnSuccess else { throw VK99Error.reportFailed(code: status) }
        return Array(bytes.prefix(length))
    }

    private static func sendOutput(_ bytes: [UInt8], to device: IOHIDDevice) throws {
        let status = bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
        }
        guard status == kIOReturnSuccess else { throw VK99Error.reportFailed(code: status) }
    }

    static func parseHex(_ text: String) throws -> [UInt8] {
        let hex = text.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard hex.count.isMultiple(of: 2), hex.utf8.allSatisfy({ $0.isASCIIHexDigit }) else {
            throw VK99Error.invalidHex
        }
        let chars = Array(hex)
        return try stride(from: 0, to: chars.count, by: 2).map {
            guard let value = UInt8(String(chars[$0...($0 + 1)]), radix: 16) else { throw VK99Error.invalidHex }
            return value
        }
    }
}

private extension UInt8 {
    var isASCIIHexDigit: Bool {
        (48...57).contains(self) || (65...70).contains(self) || (97...102).contains(self)
    }
}
