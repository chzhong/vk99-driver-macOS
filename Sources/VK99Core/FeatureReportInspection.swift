import Foundation

public enum FeatureReportInspection {
    public static func hexDump(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: bytes.count, by: 16).map { offset in
            let line = bytes[offset..<min(offset + 16, bytes.count)]
            return String(format: "%04X  ", offset) + line.map { String(format: "%02X", $0) }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    public static func interpretation(_ bytes: [UInt8]) -> String {
        if bytes.isEmpty { return "空报文；没有可解码的设备状态。" }
        if bytes.allSatisfy({ $0 == 0 }) { return "全零报文；没有可解码的设备状态。" }
        if bytes.count == 64, bytes[2] == 0x5A, bytes[62] == 0xAA, bytes[63] == 0x55,
           (1...12).contains(bytes[4]), (1...31).contains(bytes[5]),
           bytes[6] < 24, bytes[7] < 60, bytes[8] < 60 {
            let stamp = String(format: "%04d-%02d-%02d %02d:%02d:%02d",
                               2000 + Int(bytes[3]), Int(bytes[4]), Int(bytes[5]),
                               Int(bytes[6]), Int(bytes[7]), Int(bytes[8]))
            return "符合校时报文格式：\(stamp)。可能是最近写入的回显，不能作为键盘当前时间。"
        }
        return "未确认的报文格式；请依据原始字节核对，不能据此推断设备状态。"
    }
}
