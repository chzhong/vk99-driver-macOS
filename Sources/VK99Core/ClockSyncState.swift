import Foundation

public struct ClockSyncState {
    public enum Event {
        case startup
        case connected
        case disconnected
        case dailyCheck
        case wake
        case clockChanged
    }

    public enum Reason: Equatable {
        case connection
        case daily
    }

    public private(set) var lastSatisfiedDay: String?
    private var attemptedForConnection = false

    public init(lastSatisfiedDay: String?) {
        self.lastSatisfiedDay = lastSatisfiedDay
    }

    public mutating func reason(for event: Event, at now: Date,
                                timeZone: TimeZone, connected: Bool) -> Reason? {
        if case .disconnected = event {
            attemptedForConnection = false
            return nil
        }
        guard connected else { return nil }
        switch event {
        case .startup, .connected:
            guard !attemptedForConnection else { return nil }
            attemptedForConnection = true
            return .connection
        case .dailyCheck, .wake, .clockChanged:
            return ClockSyncPolicy(timeZone: timeZone).isDailyDue(
                at: now, lastSatisfiedDay: lastSatisfiedDay) ? .daily : nil
        case .disconnected:
            return nil
        }
    }

    /// Call only after the HID write reports success, including a manual send.
    public mutating func recordSuccessfulSend(at now: Date, timeZone: TimeZone) {
        if let day = ClockSyncPolicy(timeZone: timeZone).satisfiedDay(afterSuccessfulSendAt: now) {
            lastSatisfiedDay = day
        }
    }
}
