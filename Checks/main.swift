import Foundation
import VK99Core

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, timeZone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

let shanghai = TimeZone(identifier: "Asia/Shanghai")!
let policy = ClockSyncPolicy(timeZone: shanghai)
let before = date(2026, 10, 26, 2, timeZone: shanghai)
let three = date(2026, 10, 26, 3, timeZone: shanghai)
let later = date(2026, 10, 26, 10, timeZone: shanghai)
require(policy.satisfiedDay(afterSuccessfulSendAt: before) == nil, "2 AM startup leaves 3 AM due")
require(policy.nextFire(after: before) == three, "next timer fires at 3 AM")
require(policy.isDailyDue(at: three, lastSatisfiedDay: nil), "3 AM is due")
let satisfied = policy.satisfiedDay(afterSuccessfulSendAt: later)
require(satisfied == "2026-10-26", "after-3 startup or reconnect satisfies the day")
require(!policy.isDailyDue(at: later, lastSatisfiedDay: satisfied), "same day does not repeat")
require(policy.isDailyDue(at: later, lastSatisfiedDay: "2026-10-25"), "sleep miss or disconnected send remains due")
require(policy.nextFire(after: later) == date(2026, 10, 27, 3, timeZone: shanghai), "next day scheduled")

let laZone = TimeZone(identifier: "America/Los_Angeles")!
let la = ClockSyncPolicy(timeZone: laZone)
let spring = date(2026, 3, 8, 1, timeZone: laZone)
require(la.dayKey(for: la.nextFire(after: spring)) == "2026-03-08", "DST day stays local")

var state = ClockSyncState(lastSatisfiedDay: "2026-10-25")
require(state.reason(for: .startup, at: before, timeZone: shanghai, connected: true) == .connection,
        "startup sends once")
state.recordSuccessfulSend(at: before, timeZone: shanghai)
require(state.lastSatisfiedDay == "2026-10-25", "pre-3 startup does not satisfy 3 AM")
require(state.reason(for: .startup, at: before, timeZone: shanghai, connected: true) == nil,
        "startup callback cannot duplicate")
require(state.reason(for: .dailyCheck, at: three, timeZone: shanghai, connected: true) == .daily,
        "3 AM sends")
state.recordSuccessfulSend(at: three, timeZone: shanghai)
require(state.reason(for: .wake, at: later, timeZone: shanghai, connected: true) == nil,
        "same-day wake is deduplicated")
_ = state.reason(for: .disconnected, at: later, timeZone: shanghai, connected: false)
require(state.reason(for: .connected, at: later, timeZone: shanghai, connected: true) == .connection,
        "reconnect sends even after daily send")

var missed = ClockSyncState(lastSatisfiedDay: "2026-10-25")
require(missed.reason(for: .dailyCheck, at: three, timeZone: shanghai, connected: false) == nil,
        "disconnected at 3 AM sends nothing")
require(missed.reason(for: .wake, at: later, timeZone: shanghai, connected: true) == .daily,
        "sleep missed 3 AM sends on wake")
require(missed.lastSatisfiedDay == "2026-10-25", "failed send is not recorded")
require(missed.reason(for: .dailyCheck, at: later, timeZone: shanghai, connected: true) == .daily,
        "failed send remains due")
missed.recordSuccessfulSend(at: later, timeZone: shanghai)
require(missed.reason(for: .dailyCheck, at: later, timeZone: shanghai, connected: true) == nil,
        "successful catch-up is deduplicated")
var reconnected = ClockSyncState(lastSatisfiedDay: "2026-10-25")
require(reconnected.reason(for: .connected, at: later, timeZone: shanghai, connected: true) == .connection,
        "reconnect after missed 3 AM sends")
reconnected.recordSuccessfulSend(at: later, timeZone: shanghai)
require(reconnected.reason(for: .dailyCheck, at: later, timeZone: shanghai, connected: true) == nil,
        "reconnect send satisfies missed daily send")

require(FeatureReportInspection.interpretation([UInt8](repeating: 0, count: 64)).contains("全零"),
        "zero Feature report is not decoded as status")
var clockEcho = [UInt8](repeating: 0, count: 64)
clockEcho[2] = 0x5A
clockEcho[3] = 26
clockEcho[4] = 10
clockEcho[5] = 27
clockEcho[6] = 3
clockEcho[62] = 0xAA
clockEcho[63] = 0x55
require(FeatureReportInspection.interpretation(clockEcho).contains("不能作为键盘当前时间"),
        "clock-shaped echo must be labeled as unverified")
require(FeatureReportInspection.hexDump([0x20, 0x01]).contains("20 01"), "raw bytes are visible")

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let yaml = try String(contentsOf: root.appendingPathComponent("Resources/SettingsCatalog.yaml"), encoding: .utf8)
let catalog = try SettingsCatalog(yaml: yaml)
require(catalog.options(in: "effects").count == 20, "all requested effects are present")
require(catalog.options(in: "screens").map(\.label) == ["设置", "动画", "状态"], "screen names")
require(catalog.options.allSatisfy { $0.rawValue == nil }, "unverified wire values remain unknown")
do {
    _ = try SettingsCatalog(yaml: "effects:\n    raw: 0x02\n")
    require(false, "malformed catalog must fail")
} catch {}
print("VK99 core checks passed")
