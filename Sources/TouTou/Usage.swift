import Foundation
import Combine
import QuotaAlerts

struct QuotaWindow: Codable {
    let label: String
    let remainingPercent: Double
    let resetsAt: Double?
    var detail: String?
    var usedPercent: Double? = nil
}
struct ProviderQuota: Codable, Identifiable {
    let provider: String
    let windows: [QuotaWindow]
    let source: String?
    let error: String?
    var plan: String?
    var notes: [String]?
    var id: String { provider }
}
struct UsageSnapshot: Codable {
    let updatedAt: Double
    var providers: [ProviderQuota]
}
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var refreshing = false
    @Published var error: String?
    // Each refresh launches python3 and `codex app-server`, which is the most
    // expensive thing this app does, so the cadence adapts to power and visibility.
    var interval: TimeInterval = 300 { didSet { if interval != oldValue { schedule() } } }
    var paused = false { didSet { if !paused && oldValue { refreshIfStale(60) } } }
    var onSnapshot: ((UsageSnapshot) -> Void)?
    private var timer: Timer?
    private var lastAttempt: Date?
    private var forecastMemory: [String: ForecastPoint] = {
        guard let data = UserDefaults.standard.data(forKey: "quotaForecastMemory"),
              let memory = try? JSONDecoder().decode([String: ForecastPoint].self, from: data) else { return [:] }
        return memory
    }()
    init() {
        refresh()
        schedule()
    }
    private func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self, !self.paused else { return }
            self.refresh()
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func refreshIfStale(_ seconds: TimeInterval) {
        guard Date().timeIntervalSince(lastAttempt ?? .distantPast) >= seconds else { return }
        refresh()
    }
    // Fixed sample data for screenshots and UI work; no account is contacted.
    static var demo: UsageSnapshot {
        let now = Date().timeIntervalSince1970
        return UsageSnapshot(updatedAt: now, providers: [
            ProviderQuota(provider: "chatgpt", windows: [
                QuotaWindow(label: "5 часов", remainingPercent: 72, resetsAt: now + 41 * 60, detail: nil),
                QuotaWindow(label: "Неделя", remainingPercent: 58, resetsAt: now + 5 * 86400, detail: nil),
            ], source: "ChatGPT Work / Codex", error: nil, plan: "Plus", notes: ["хватит ~40 мин · 5 часов"]),
            ProviderQuota(provider: "cursor", windows: [
                QuotaWindow(label: "Cursor", remainingPercent: 97, resetsAt: now + 19 * 86400, detail: nil, usedPercent: 3),
                QuotaWindow(label: "Другие", remainingPercent: 0, resetsAt: now + 19 * 86400, detail: nil, usedPercent: 100),
            ], source: "Cursor plan", error: nil, plan: "Pro", notes: []),
        ])
    }
    func refresh() {
        guard !refreshing else { return }
        if ProcessInfo.processInfo.environment["TOUTOU_DEMO"] != nil || ProcessInfo.processInfo.environment["TOUTU_DEMO"] != nil { snapshot = Self.demo; return }
        refreshing = true
        lastAttempt = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("fetch_usage.py")
            let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/fetch_usage.py")
            guard let script = [bundled, development].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                DispatchQueue.main.async { self?.refreshing = false; self?.error = "Не найден модуль лимитов" }
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path]
            process.qualityOfService = .utility
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            var result: UsageSnapshot?
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 { result = try? JSONDecoder().decode(UsageSnapshot.self, from: data) }
            } catch { }
            let value = result
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.refreshing = false
                if let value = value {
                    let annotated = self.annotated(value)
                    self.snapshot = annotated
                    self.error = nil
                    self.onSnapshot?(annotated)
                } else { self.error = "Не удалось обновить лимиты" }
            }
        }
    }

    private struct ForecastPoint: Codable {
        var remaining: Double
        var at: Double
    }

    /// Adds a single "хватит ~N мин" note for the window that will empty first.
    private func annotated(_ snapshot: UsageSnapshot) -> UsageSnapshot {
        var snapshot = snapshot
        var next: [String: ForecastPoint] = [:]
        var best: (minutes: Int, provider: Int, label: String)?
        for (index, provider) in snapshot.providers.enumerated() {
            for window in provider.windows {
                let key = provider.provider + "|" + window.label
                let point = ForecastPoint(remaining: window.remainingPercent, at: snapshot.updatedAt)
                if let previous = forecastMemory[key], snapshot.updatedAt - previous.at < 3 * 3600,
                   let minutes = QuotaForecast.minutesRemaining(from: previous.remaining, at: previous.at, to: point.remaining, at: point.at) {
                    if best == nil || minutes < best!.minutes {
                        best = (minutes, index, window.label)
                    }
                }
                next[key] = point
            }
        }
        forecastMemory = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: "quotaForecastMemory")
        }
        if let best {
            var notes = snapshot.providers[best.provider].notes ?? []
            notes.append(QuotaForecast.phrase(best.minutes) + " · " + best.label)
            snapshot.providers[best.provider].notes = notes
        }
        return snapshot
    }
}
