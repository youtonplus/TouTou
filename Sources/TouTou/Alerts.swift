import Combine
import Foundation
import QuotaAlerts
import UserNotifications

/// Posts a local notification when a quota window newly crosses 25% or 10% remaining.
/// The app is already running in the menu bar, so this is a banner from the latest
/// fetch — not a push. Screen sleep still pauses that fetch.
final class QuotaAlertCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "quotaAlertsEnabled"
    static let memoryKey = "quotaAlertMemory"

    @Published var enabled: Bool
    @Published var permissionDenied = false
    var onOpen: (() -> Void)?

    override init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        super.init()
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        if enabled { authorize() }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
        if value { authorize() }
    }

    func consider(_ snapshot: UsageSnapshot) {
        guard enabled, ProcessInfo.processInfo.environment["TOUTOU_DEMO"] == nil, ProcessInfo.processInfo.environment["TOUTU_DEMO"] == nil,
              !CommandLine.arguments.contains("--snapshot") else { return }
        let windows = snapshot.providers.flatMap { provider in
            provider.windows.map { window in
                QuotaWindowSample(
                    provider: provider.provider,
                    label: window.label,
                    remainingPercent: window.remainingPercent,
                    resetsAt: window.resetsAt,
                    unlimited: window.detail == "Без лимита"
                )
            }
        }
        // Remember a window only after macOS will actually show the banner.
        // Otherwise a denied or not-yet-answered permission would swallow the alert.
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self = self, self.enabled else { return }
                self.permissionDenied = settings.authorizationStatus == .denied
                guard settings.authorizationStatus == .authorized else { return }
                let plan = QuotaAlerts.plan(windows: windows, memory: self.loadMemory(), now: Date().timeIntervalSince1970)
                self.saveMemory(plan.memory)
                guard let notice = plan.notice else { return }
                self.post(title: notice.title, body: notice.body)
            }
        }
    }

    /// Battery / sleep safety banners are independent of the quota bell.
    func postSafety(title: String, body: String) {
        authorize()
        post(title: title, body: body, id: "toutou-battery-guard")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { self.onOpen?() }
    }

    private func post(title: String, body: String, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func authorize() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.permissionDenied = !granted }
        }
    }

    private func loadMemory() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: Self.memoryKey),
              let memory = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return memory
    }

    private func saveMemory(_ memory: [String: Int]) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        UserDefaults.standard.set(data, forKey: Self.memoryKey)
    }
}
