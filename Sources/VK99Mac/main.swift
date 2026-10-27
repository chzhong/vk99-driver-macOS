import Foundation
import IOKit.hid
import ServiceManagement

struct HIDInterface: Codable {
    let product: String
    let manufacturer: String?
    let serialNumber: String?
    let vendorID: Int
    let productID: Int
    let locationID: Int?
    let usagePage: Int?
    let usage: Int?
    let transport: String?
    let maxInputReportSize: Int?
    let maxOutputReportSize: Int?
    let maxFeatureReportSize: Int?
    let reportDescriptorHex: String?
}

func property(_ device: IOHIDDevice, _ key: String) -> Any? {
    IOHIDDeviceGetProperty(device, key as CFString)
}

func number(_ device: IOHIDDevice, _ key: String) -> Int? {
    (property(device, key) as? NSNumber)?.intValue
}

func string(_ device: IOHIDDevice, _ key: String) -> String? {
    property(device, key) as? String
}

func scan() -> [HIDInterface] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [
        kIOHIDVendorIDKey: 0x05AC,
        kIOHIDProductIDKey: 0x024F
    ] as CFDictionary)
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
    return devices.compactMap { device in
        guard let vendorID = number(device, kIOHIDVendorIDKey),
              let productID = number(device, kIOHIDProductIDKey) else { return nil }
        let product = string(device, kIOHIDProductKey) ?? ""
        let knownProducts = [
            "Valkyrie-99", "Valkyrie-99pro", "VK99Pro Wireless Receiver",
            "2.4G Wireless Receiver"
        ]
        guard knownProducts.contains(product) else { return nil }
        let descriptor = property(device, "ReportDescriptor") as? Data
        return HIDInterface(
            product: product,
            manufacturer: string(device, kIOHIDManufacturerKey),
            serialNumber: string(device, kIOHIDSerialNumberKey),
            vendorID: vendorID,
            productID: productID,
            locationID: number(device, kIOHIDLocationIDKey),
            usagePage: number(device, kIOHIDPrimaryUsagePageKey),
            usage: number(device, kIOHIDPrimaryUsageKey),
            transport: string(device, kIOHIDTransportKey),
            maxInputReportSize: number(device, kIOHIDMaxInputReportSizeKey),
            maxOutputReportSize: number(device, kIOHIDMaxOutputReportSizeKey),
            maxFeatureReportSize: number(device, kIOHIDMaxFeatureReportSizeKey),
            reportDescriptorHex: descriptor?.map { String(format: "%02x", $0) }.joined()
        )
    }.sorted {
        if $0.product != $1.product { return $0.product < $1.product }
        if $0.usagePage != $1.usagePage { return ($0.usagePage ?? 0) < ($1.usagePage ?? 0) }
        if $0.usage != $1.usage { return ($0.usage ?? 0) < ($1.usage ?? 0) }
        return ($0.maxFeatureReportSize ?? 0) < ($1.maxFeatureReportSize ?? 0)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let usage = """
Usage:
  vk99 scan
  vk99 gui
  vk99 clock-show
  vk99 clock-sync --confirm
  vk99 clock-diagnose --confirm [--screen-index 1|2|3]
  vk99 login-status
  vk99 read-feature
  vk99 send-feature HEX --confirm
  vk99 send-output FILE --confirm
  vk99 tft-pack IMAGE OUTPUT
  vk99 tft-preview IMAGE OUTPUT.png
  vk99 tft-upload IMAGE --confirm

HEX contains exactly 64 payload bytes; FILE contains exactly 4096 payload bytes.
The report ID is passed separately as 0. Raw sends are for protocol research.
TFT upload replaces the screen's current image; packing alone does not access the device.
"""
do {
    switch arguments.first ?? "gui" {
    case "scan" where arguments.count <= 1:
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(scan())
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    case "gui" where arguments.count <= 1:
        VK99GUI.run()
    case "clock-show" where arguments.count == 1:
        print("Mac local time: \(DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .medium))")
        print("Keyboard time: unavailable; this protocol has no confirmed clock readback command")
    case "clock-sync" where arguments.count == 2 && arguments[1] == "--confirm":
        let now = Date()
        try VK99Transport.syncClock(at: now)
        print("Sent Mac local time: \(DateFormatter.localizedString(from: now, dateStyle: .full, timeStyle: .medium))")
    case "clock-diagnose" where arguments.first == "clock-diagnose" &&
        (arguments.count == 2 || arguments.count == 4) && arguments[1] == "--confirm":
        let index: UInt8
        if arguments.count == 4 {
            guard arguments[2] == "--screen-index", let parsed = UInt8(arguments[3]), (1...3).contains(parsed) else {
                throw VK99Error.invalidScreenIndex
            }
            index = parsed
        } else {
            index = 1
        }
        let diagnosis = try VK99Transport.diagnoseClock(screenIndex: index)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(diagnosis))
        FileHandle.standardOutput.write(Data([0x0A]))
    case "login-status" where arguments.count == 1:
        print("Login item status: \(SMAppService.mainApp.status.rawValue)")
    case "read-feature" where arguments.count == 1:
        let bytes = try VK99Transport.readFeature()
        print(bytes.map { String(format: "%02x", $0) }.joined())
    case "send-feature" where arguments.count == 3 && arguments[2] == "--confirm":
        try VK99Transport.writeFeature(VK99Transport.parseHex(arguments[1]))
        print("Sent 64-byte feature report")
    case "send-output" where arguments.count == 3 && arguments[2] == "--confirm":
        try VK99Transport.writeOutput(Array(try Data(contentsOf: URL(fileURLWithPath: arguments[1]))))
        print("Sent 4096-byte output report")
    case "tft-pack" where arguments.count == 3:
        let packed = try TFTImage.packedFrame(at: URL(fileURLWithPath: arguments[1]))
        try Data(packed).write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
        print("Wrote \(packed.count) bytes (\(packed.count / VK99Transport.outputBytes) output reports)")
    case "tft-preview" where arguments.count == 3:
        let packed = try TFTImage.packedFrame(at: URL(fileURLWithPath: arguments[1]))
        let data = try TFTImage.previewPNG(packed)
        try data.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
        print("Wrote 160×96 RGB565 screen preview")
    case "tft-upload" where arguments.count == 3 && arguments[2] == "--confirm":
        let packed = try TFTImage.packedFrame(at: URL(fileURLWithPath: arguments[1]))
        try VK99Transport.uploadTFT(packed)
        print("Uploaded one 160×96 TFT frame")
    default:
        fputs(usage + "\n", stderr)
        exit(2)
    }
} catch {
    fputs("vk99: \(error)\n", stderr)
    exit(1)
}
