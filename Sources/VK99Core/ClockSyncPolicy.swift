import Foundation

/// Pure scheduling rules. The caller supplies the current time and the current system time zone.
public struct ClockSyncPolicy {
    public let timeZone: TimeZone

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = timeZone
        return result
    }

    public func dayKey(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public func cutoff(on date: Date) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.nextDate(
            after: start.addingTimeInterval(-1),
            matching: DateComponents(hour: 3, minute: 0, second: 0),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )!
    }

    public func isDailyDue(at now: Date, lastSatisfiedDay: String?) -> Bool {
        now >= cutoff(on: now) && lastSatisfiedDay != dayKey(for: now)
    }

    public func satisfiedDay(afterSuccessfulSendAt now: Date) -> String? {
        now >= cutoff(on: now) ? dayKey(for: now) : nil
    }

    public func nextFire(after now: Date) -> Date {
        let today = cutoff(on: now)
        if today > now { return today }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return cutoff(on: tomorrow)
    }
}
