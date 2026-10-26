import Foundation

/// One quota window, reduced to the fields a low-balance alert needs.
public struct QuotaWindowSample: Equatable {
    public var provider: String
    public var label: String
    public var remainingPercent: Double
    public var resetsAt: Double?
    public var unlimited: Bool

    public init(provider: String, label: String, remainingPercent: Double, resetsAt: Double?, unlimited: Bool) {
        self.provider = provider
        self.label = label
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.unlimited = unlimited
    }
}

public struct QuotaNotice: Equatable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public struct QuotaAlertPlan: Equatable {
    public var notice: QuotaNotice?
    public var memory: [String: Int]

    public init(notice: QuotaNotice?, memory: [String: Int]) {
        self.notice = notice
        self.memory = memory
    }
}

/// Decides when a fresh quota snapshot deserves a notification.
///
/// The same window is announced at 25% remaining and again at 10%. Repeating the
/// poll must not repeat the banner. A later recovery above 25%, or a new reset
/// timestamp, arms the window so the next drop can be announced again.
public enum QuotaAlerts {
    public static let warning = 25
    public static let critical = 10

    public static func plan(windows: [QuotaWindowSample], memory: [String: Int], now: TimeInterval) -> QuotaAlertPlan {
        var memory = prune(memory, now: now)
        var lines: [(threshold: Int, text: String)] = []
        for window in windows {
            guard window.remainingPercent.isFinite else { continue }
            let key = key(window)
            guard !window.unlimited, let threshold = threshold(window.remainingPercent) else {
                memory.removeValue(forKey: key)
                continue
            }
            let announced = memory[key]
            if announced == nil || threshold < announced! {
                lines.append((threshold, line(window)))
            }
            memory[key] = threshold
        }
        guard !lines.isEmpty else { return QuotaAlertPlan(notice: nil, memory: memory) }
        let worst = lines.map(\.threshold).min() ?? warning
        let title = worst <= critical ? "Лимит почти исчерпан" : "Осталось меньше четверти лимита"
        return QuotaAlertPlan(notice: QuotaNotice(title: title, body: lines.map(\.text).joined(separator: "\n")), memory: memory)
    }

    private static func threshold(_ remaining: Double) -> Int? {
        if remaining <= Double(critical) { return critical }
        if remaining <= Double(warning) { return warning }
        return nil
    }

    private static func line(_ window: QuotaWindowSample) -> String {
        let shown = Int(window.remainingPercent.rounded())
        let amount = shown <= 0 ? "лимит исчерпан" : "осталось \(shown)%"
        return "\(name(window.provider)) · \(window.label): \(amount)"
    }

    private static func name(_ provider: String) -> String {
        switch provider {
        case "chatgpt": return "ChatGPT"
        case "cursor": return "Cursor"
        default: return provider
        }
    }

    private static func key(_ window: QuotaWindowSample) -> String {
        let reset = window.resetsAt.map { String(Int($0)) } ?? "-"
        return [window.provider, window.label, reset].joined(separator: "\u{1e}")
    }

    /// Drop announcements whose reset is already two days behind, so memory does not grow forever.
    private static func prune(_ memory: [String: Int], now: TimeInterval) -> [String: Int] {
        memory.filter { key, _ in
            guard let reset = key.split(separator: "\u{1e}").last.flatMap({ Double($0) }) else { return true }
            return reset > now - 86400 * 2
        }
    }
}
