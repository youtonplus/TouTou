import AppKit
import SwiftUI
import Combine

struct AgentStep: Codable, Equatable {
    let detail: String
    let state: String
    let timestamp: Double
}

struct AgentEvent: Codable, Identifiable, Equatable {
    let id: String
    let session: String
    let agent: String
    let project: String
    let state: String
    let detail: String
    let timestamp: Double
    var startedAt: Double?
    var steps: [AgentStep]?
}

final class SessionStore: ObservableObject {
    @Published var sessions: [AgentEvent] = []
    @Published var demo = false
    @Published var error: String?
    @Published var expanded = false
    @Published var expansionProgress: CGFloat = 0
    @Published var notchWidth: CGFloat = 180
    @Published var notchHeight: CGFloat = 32
    @Published var muted = false
    @Published var pinned = false
    @Published var celebrating = false
    @Published var tab: PanelTab = .quotas
    let directory: URL
    /// Events written before the app was renamed TouTou.
    private let legacyDirectory: URL?
    private var timer: Timer?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var celebrationWork: DispatchWorkItem?
    init() {
        let env = ProcessInfo.processInfo.environment["TOUTOU_DATA_DIR"] ?? ProcessInfo.processInfo.environment["TOUTU_DATA_DIR"]
        directory = env.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TouTou/events")
        let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Toutu/events")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { self.error = error.localizedDescription }
        // On a case-insensitive disk the old and new names are the same folder.
        legacyDirectory = env == nil && !Self.sameFolder(directory, legacy) ? legacy : nil
        poll()
        watch()
        // The directory watcher delivers new events instantly; this slow timer only
        // expires stale entries and covers the rare case where the watcher is unavailable.
        let timer = Timer(timeInterval: watchers.isEmpty ? 5 : 60, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = watchers.isEmpty ? 1 : 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private static func sameFolder(_ left: URL, _ right: URL) -> Bool {
        func fileNumber(_ url: URL) -> NSNumber? {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber]) as? NSNumber
        }
        guard let leftNumber = fileNumber(left), let rightNumber = fileNumber(right) else { return false }
        return leftNumber == rightNumber
    }
    private func watch() {
        for folder in [directory, legacyDirectory].compactMap({ $0 }) {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                guard let self = self else { return }
                // Hooks write several files in quick succession; coalesce into one read.
                self.pending?.cancel()
                let work = DispatchWorkItem { self.poll() }
                self.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }
    func poll() {
        guard !demo else { return }
        do {
            let primary = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let older = legacyDirectory.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
            let files = (primary + older).filter { $0.pathExtension == "json" }
            let events = files.compactMap { url -> AgentEvent? in
                guard let data = try? Data(contentsOf: url), data.count <= 262144 else { return nil }
                return try? JSONDecoder().decode(AgentEvent.self, from: data)
            }.filter { Date().timeIntervalSince1970 - $0.timestamp < 86400 }.sorted { $0.timestamp > $1.timestamp }
            var seen = Set<String>()
            let latest = Array(events.filter { seen.insert($0.session).inserted }.prefix(20))
            let previousIds = Set(sessions.map(\.id))
            let fresh = latest.filter { !previousIds.contains($0.id) }
            if !muted {
                if fresh.contains(where: { $0.state == "error" }) { NSSound(named: "Basso")?.play() }
                else if fresh.contains(where: { $0.state == "done" }) { NSSound(named: "Glass")?.play() }
            }
            if fresh.contains(where: { $0.state == "done" }) { celebrate() }
            // Avoid publishing identical state: every change re-renders the SwiftUI tree.
            if latest.map(\.id) != sessions.map(\.id) { sessions = latest }
            if error != nil { error = nil }
        } catch { self.error = error.localizedDescription }
    }
    func celebrate() {
        celebrating = true
        celebrationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.celebrating = false }
        celebrationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
    func togglePin() {
        pinned.toggle()
        expanded = pinned
    }
    func toggleDemo() {
        demo.toggle()
        if demo {
            let now = Date().timeIntervalSince1970
            sessions = [
                AgentEvent(id: "demo-1", session: "demo-1", agent: "Cursor", project: "/Users/demo/TouTou", state: "working",
                           detail: "Обновляет компоненты интерфейса", timestamp: now, startedAt: now - 12 * 60,
                           steps: [
                            AgentStep(detail: "Сессия началась", state: "working", timestamp: now - 12 * 60),
                            AgentStep(detail: "Файл обновлён: Sources/TouTou/main.swift", state: "working", timestamp: now - 8 * 60),
                            AgentStep(detail: "Команда выполнена", state: "working", timestamp: now - 3 * 60),
                            AgentStep(detail: "Обновляет компоненты интерфейса", state: "working", timestamp: now),
                           ]),
                AgentEvent(id: "demo-2", session: "demo-2", agent: "Cursor", project: "/Users/demo/api", state: "done",
                           detail: "Задача завершена", timestamp: now - 40 * 60, startedAt: now - 70 * 60,
                           steps: [AgentStep(detail: "Задача завершена", state: "done", timestamp: now - 40 * 60)]),
            ]
        } else { sessions = []; poll() }
    }
    func openApp(_ name: String, fallback: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let url = URL(string: fallback) { NSWorkspace.shared.open(url) }
    }
    func openProject(_ event: AgentEvent) {
        let url = URL(fileURLWithPath: event.project)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let cursor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") {
            NSWorkspace.shared.open([url], withApplicationAt: cursor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

func projectName(_ project: String) -> String {
    let name = URL(fileURLWithPath: project).lastPathComponent
    return name.isEmpty ? project : name
}

func durationText(from start: Double, to end: Double) -> String {
    let seconds = max(0, end - start)
    if seconds < 45 { return "" }
    if seconds < 3600 { return "\(max(1, Int((seconds / 60).rounded()))) мин" }
    let hours = Int(seconds / 3600)
    let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
    return minutes == 0 ? "\(hours) ч" : "\(hours) ч \(minutes) мин"
}

func stepLabel(_ detail: String) -> String {
    guard let colon = detail.lastIndex(of: ":") else { return detail }
    let path = detail[detail.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    if path.contains("/") { return URL(fileURLWithPath: String(path)).lastPathComponent }
    return detail
}

func todaySummary(from sessions: [AgentEvent], now: Date = Date()) -> String? {
    let calendar = Calendar.current
    let todays = sessions.filter { calendar.isDateInToday(Date(timeIntervalSince1970: $0.startedAt ?? $0.timestamp)) }
    guard !todays.isEmpty else { return nil }
    let seconds = todays.reduce(0.0) { sum, event in
        let start = event.startedAt ?? event.timestamp
        let end = event.state == "working" ? now.timeIntervalSince1970 : max(event.timestamp, start)
        return sum + max(0, end - start)
    }
    let errors = todays.filter { $0.state == "error" }.count
    let count = todays.count
    let word = count == 1 ? "сессия" : (count < 5 ? "сессии" : "сессий")
    var text = "сегодня \(count) \(word)"
    let duration = durationText(from: 0, to: seconds)
    if !duration.isEmpty { text += " · " + duration }
    if errors > 0 { text += " · \(errors) \(errors == 1 ? "ошибка" : "ошибки")" }
    return text
}

// Every animated frame re-renders the SwiftUI tree, which is the main CPU and
// battery cost of a notch companion. The character is therefore static when idle,
// nods a few frames per second in the compact strip while an agent works, and only
// moves continuously while the panel is open and someone is looking at it.
enum CompanionMotion { case still, gentle, lively }
enum CompanionMood { case idle, working, error, lowQuota, celebrating }

struct Companion: View {
    var active: Bool
    var motion: CompanionMotion
    var mood: CompanionMood = .idle
    @State private var float = false
    @State private var blink = false
    @State private var tilt: CGFloat = 0
    @State private var timer: Timer?
    @State private var ticks = 0
    var worried: Bool { mood == .error || mood == .lowQuota }
    var mouthWidth: CGFloat {
        switch mood {
        case .error: return 14
        case .celebrating: return 11
        case .working: return 9
        case .lowQuota: return 8
        case .idle: return 12
        }
    }
    var eyeHeight: CGFloat { blink ? 2 : (mood == .lowQuota ? 6 : 12) }
    var fill: [Color] {
        switch mood {
        case .error: return [Color(red: 0.95, green: 0.78, blue: 0.55), Color(red: 0.72, green: 0.48, blue: 0.32)]
        case .lowQuota: return [Color(red: 0.70, green: 0.82, blue: 0.52), Color(red: 0.38, green: 0.55, blue: 0.34)]
        default: return [Color(red: 0.82, green: 0.94, blue: 0.64), Color(red: 0.43, green: 0.72, blue: 0.42)]
        }
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22).fill(LinearGradient(colors: fill, startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(spacing: 13) {
                Capsule().fill(Color.black.opacity(0.85)).frame(width: 7, height: eyeHeight)
                Capsule().fill(Color.black.opacity(0.85)).frame(width: 7, height: eyeHeight)
            }.offset(y: worried ? 2 : -2)
            Capsule().fill(Color.black.opacity(0.55)).frame(width: mouthWidth, height: 3).offset(y: 12)
        }.frame(width: 58, height: 54)
        .rotationEffect(.degrees((float && (active || mood == .celebrating) ? 5 : -3) + tilt))
        .offset(y: float ? (mood == .celebrating ? -6 : -3) : (worried ? 4 : 2))
        .onAppear { update(motion) }
        .onChange(of: motion) { value in update(value) }
        .onChange(of: mood) { value in react(value) }
        .onDisappear { timer?.invalidate(); timer = nil }
    }
    private func react(_ mood: CompanionMood) {
        if mood == .error { shake() }
        if mood == .celebrating { withAnimation(.easeInOut(duration: 0.22)) { float = true } }
        update(motion)
    }
    private func shake() {
        let offsets: [CGFloat] = [-6, 6, -4, 4, 0]
        for (index, value) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.05) {
                withAnimation(.linear(duration: 0.05)) { tilt = value }
            }
        }
    }
    private func update(_ motion: CompanionMotion) {
        timer?.invalidate()
        timer = nil
        switch motion {
        case .still:
            withAnimation(.easeOut(duration: 0.3)) { float = false }
            blink = false
        case .lively:
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { float = true }
            schedule(every: 4.2) { doBlink() }
        case .gentle:
            // One short eased nod per 1.2 s averages roughly a dozen frames per second.
            schedule(every: 1.2) {
                withAnimation(.easeInOut(duration: 0.25)) { float.toggle() }
                ticks += 1
                if ticks % 4 == 0 { doBlink() }
            }
        }
    }
    private func schedule(every interval: TimeInterval, _ action: @escaping () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func doBlink() {
        blink = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { blink = false }
    }
}

enum IslandLayout {
    static let expandedWidth: CGFloat = 440
    static let expandedHeight: CGFloat = 248
    static let cardHeight: CGFloat = 148
    static let compactSide: CGFloat = 56
    static var compactExtra: CGFloat { compactSide * 2 }
}

enum PanelTab: String, CaseIterable {
    case quotas, power
    var title: String { self == .quotas ? "Лимиты" : "Питание" }
}

struct IslandView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var usage: UsageStore
    @ObservedObject var power: PowerStore
    @ObservedObject var alerts: QuotaAlertCenter
    @State private var closeTask: DispatchWorkItem?
    var active: Bool { store.sessions.contains { $0.state == "working" } }
    var mood: CompanionMood {
        if store.celebrating { return .celebrating }
        if store.sessions.first?.state == "error" { return .error }
        if active { return .working }
        if lowestRemaining <= 10 { return .lowQuota }
        return .idle
    }
    var lowestRemaining: Double {
        usage.snapshot?.providers.flatMap { $0.windows.map(\.remainingPercent) }.min() ?? 100
    }
    var companionMotion: CompanionMotion {
        if store.celebrating { return store.expansionProgress > 0 ? .lively : .gentle }
        if store.expansionProgress > 0 { return active || mood == .error ? .lively : .still }
        return active ? .gentle : .still
    }
    var body: some View {
        VStack(spacing: 0) {
            Button { store.expanded = true } label: {
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Companion(active: active, motion: companionMotion, mood: mood)
                            .scaleEffect(0.32).frame(width: 32, height: store.notchHeight)
                    }.frame(width: IslandLayout.compactSide, height: store.notchHeight)
                    Color.clear.frame(width: store.notchWidth, height: store.notchHeight)
                    HStack(spacing: 4) {
                        compactPercent("chatgpt")
                        compactPercent("cursor")
                        if power.lidAwake {
                            Image(systemName: "moon.zzz.fill").font(.system(size: 7)).foregroundStyle(power.batteryGuard ? .red : .yellow)
                        } else if power.holdingAgent {
                            Image(systemName: "bolt.fill").font(.system(size: 7)).foregroundStyle(.yellow)
                        }
                        Spacer(minLength: 0)
                    }.frame(width: IslandLayout.compactSide, height: store.notchHeight)
                }.frame(maxWidth: .infinity)
            }.buttonStyle(.plain).help("Остаток лимитов ChatGPT и Cursor")
                VStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(PanelTab.allCases, id: \.self) { tab in
                            Button(tab.title) { store.tab = tab }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(store.tab == tab ? .primary : .secondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(store.tab == tab ? Color.white.opacity(0.14) : .clear, in: Capsule())
                        }
                        Spacer()
                        if store.tab == .quotas {
                            Button { usage.refresh() } label: {
                                Image(systemName: usage.refreshing ? "ellipsis" : "arrow.clockwise")
                            }.disabled(usage.refreshing).help("Обновить лимиты")
                        }
                        Button { store.togglePin() } label: {
                            Image(systemName: store.pinned ? "pin.fill" : "pin")
                        }.help(store.pinned ? "Открепить панель" : "Закрепить панель")
                        Button { store.pinned = false; store.expanded = false } label: { Image(systemName: "chevron.up") }.help("Свернуть")
                    }.font(.system(size: 10)).buttonStyle(.plain)
                    Group {
                        if store.tab == .quotas {
                            HStack(alignment: .top, spacing: 8) {
                                quotaRow("ChatGPT", id: "chatgpt", icon: "sparkles", color: .green)
                                quotaRow("Cursor", id: "cursor", icon: "cursorarrow", color: .cyan)
                            }
                        } else { powerTab }
                    }.frame(height: IslandLayout.cardHeight)
                    footerBar
                }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
                .frame(width: IslandLayout.expandedWidth)
                .opacity(Double(store.expansionProgress))
                .offset(y: -6 * (1 - store.expansionProgress))
                .allowsHitTesting(store.expansionProgress > 0.95)
                .accessibilityHidden(store.expansionProgress < 0.95)
        }.frame(width: store.notchWidth + IslandLayout.compactExtra + (IslandLayout.expandedWidth - store.notchWidth - IslandLayout.compactExtra) * store.expansionProgress,
                 height: store.notchHeight + (IslandLayout.expandedHeight - store.notchHeight) * store.expansionProgress,
                 alignment: .top)
        .foregroundStyle(.white).background(Color.black, in: NotchShape())
        .clipShape(NotchShape()).preferredColorScheme(.dark)
        .contentShape(NotchShape())
        .onHover { inside in
            closeTask?.cancel()
            if inside { store.expanded = true }
            else if !store.pinned {
                let task = DispatchWorkItem { store.expanded = false }
                closeTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
            }
        }
    }
    var footerBar: some View {
        HStack(spacing: 8) {
            if store.expansionProgress > 0.95, active {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    footerLabel(now: timeline.date)
                }
            } else {
                footerLabel(now: Date())
            }
            Spacer(minLength: 2)
            Button { alerts.setEnabled(!alerts.enabled) } label: { Image(systemName: alerts.enabled ? "bell" : "bell.slash") }
                .help(alerts.permissionDenied ? "Разрешите уведомления TouTou в Системных настройках" : "Предупреждать, когда остаток лимита опускается ниже 25%, и ещё раз ниже 10%")
            Button { store.muted.toggle() } label: { Image(systemName: store.muted ? "speaker.slash" : "speaker.wave.2") }.help("Звук завершения")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }.help("Выйти")
        }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
    }
    func footerLabel(now: Date) -> some View {
        Button { if let event = store.sessions.first { store.openProject(event) } } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let event = store.sessions.first {
                        Circle().fill(event.state == "working" ? Color.green : event.state == "error" ? Color.red : .gray).frame(width: 4, height: 4)
                    }
                    Text(footerText(now: now)).lineLimit(1).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if let sub = footerSubtext {
                    Text(sub).lineLimit(1).font(.system(size: 8)).foregroundStyle(.secondary.opacity(0.9))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
        .help(store.sessions.first.map { "Открыть \(projectName($0.project)) в Cursor" } ?? "События агента")
    }
    func compactPercent(_ id: String) -> some View {
        Text(compactLabel(id))
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(quotaColor(id))
    }
    func compactLabel(_ id: String) -> String {
        guard let windows = usage.snapshot?.providers.first(where: { $0.provider == id })?.windows, !windows.isEmpty,
              let worst = windows.min(by: { $0.remainingPercent < $1.remainingPercent }) else { return "–" }
        return String(format: "%.0f", displayedPercent(worst, id: id))
    }
    func quotaColor(_ provider: String) -> Color {
        guard let windows = usage.snapshot?.providers.first(where: { $0.provider == provider })?.windows,
              let remaining = windows.map({ $0.remainingPercent }).min() else { return .gray }
        return remaining <= 10 ? .red : remaining <= 25 ? .orange : .green
    }
    func footerText(now: Date) -> String {
        if store.tab == .power, let message = power.message { return message }
        if let error = usage.error { return error }
        if usage.refreshing { return "Обновляю…" }
        if let event = store.sessions.first {
            let name = projectName(event.project)
            let duration = durationText(from: event.startedAt ?? event.timestamp, to: event.state == "working" ? now.timeIntervalSince1970 : event.timestamp)
            if event.state == "working" {
                return duration.isEmpty ? name : "\(name) · \(duration)"
            }
            return duration.isEmpty ? event.detail : "\(event.detail) · \(duration)"
        }
        return todaySummary(from: store.sessions, now: now) ?? (usage.snapshot == nil ? "Подключение…" : "Автообновление · \(Int(usage.interval / 60)) мин")
    }
    var footerSubtext: String? {
        guard store.tab != .power, let steps = store.sessions.first?.steps, steps.count >= 2 else { return nil }
        return steps.suffix(4).map { stepLabel($0.detail) }.joined(separator: " · ")
    }
    func quotaRow(_ title: String, id: String, icon: String, color: Color) -> some View {
        let provider = usage.snapshot?.providers.first(where: { $0.provider == id })
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Button(title) {
                    store.openApp(id == "chatgpt" ? "com.openai.codex" : "com.todesktop.230313mzl4w4u92", fallback: id == "chatgpt" ? "https://chatgpt.com" : "https://cursor.com")
                }.buttonStyle(.plain)
                if let plan = provider?.plan {
                    Text(plan).font(.system(size: 8, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(color.opacity(0.22), in: Capsule())
                }
                Spacer()
                if id == "chatgpt" { Text("Codex").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize().help("Лимиты ChatGPT Work / Codex") }
            }.font(.system(size: 12, weight: .semibold))
            if let provider = provider, !provider.windows.isEmpty {
                ForEach(Array(provider.windows.enumerated()), id: \.offset) { _, window in
                    HStack(spacing: 7) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(window.label).foregroundStyle(.secondary).lineLimit(1)
                            if distinctResets(provider), let reset = window.resetsAt {
                                Text(shortReset(reset)).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.frame(width: 52, alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.12))
                                Capsule().fill(window.remainingPercent <= 10 ? Color.red : window.remainingPercent <= 25 ? Color.orange : color)
                                    .frame(width: geometry.size.width * max(0, min(1, displayedPercent(window, id: id) / 100)))
                            }
                        }.frame(height: 4)
                        Text(window.detail ?? String(format: "%.0f%%", displayedPercent(window, id: id))).monospacedDigit()
                            .frame(width: window.detail == nil ? 30 : 60, alignment: .trailing).lineLimit(1)
                    }.font(.system(size: 10)).help(windowHelp(window))
                }
                let note = noteText(provider)
                if !note.isEmpty {
                    Text(note).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(note)
                }
            } else {
                Text(provider?.error ?? "Получаю данные…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }
    var powerTab: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").foregroundStyle(.yellow)
                Text("Не спать при закрытой крышке").font(.system(size: 12, weight: .semibold))
                Spacer()
                if power.busy { ProgressView().controlSize(.mini) }
                Toggle("", isOn: Binding(get: { power.lidAwake }, set: { power.setLidAwake($0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(power.busy)
                    .help("Включает системную настройку pmset disablesleep; нужен пароль администратора")
            }
            HStack(spacing: 6) {
                Circle().fill(power.batteryGuard ? Color.red : (power.lidAwake ? Color.yellow : (power.onBattery ? Color.orange : Color.green))).frame(width: 5, height: 5)
                Text(power.statusText).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                if power.lidAwake && power.onBattery {
                    Text("· батарея").font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Toggle(isOn: $power.stayAwakeWhileAgent) {
                Text("Не спать, пока агент работает").font(.system(size: 9))
            }.toggleStyle(.checkbox).controlSize(.mini)
            .help("Удерживает Mac через caffeinate без пароля, пока хуки видят работающего агента. Крышку это не открывает.")
            Toggle(isOn: $power.stopOnLowBattery) {
                Text("На батарее ≤\(PowerStore.batteryFloor)% отпускать удержание").font(.system(size: 9))
            }.toggleStyle(.checkbox).controlSize(.mini)
            .help("Снимает caffeinate. Режим закрытой крышки сам не выключается: для pmset нужен пароль, а вас может не быть рядом.")
            Toggle(isOn: Binding(get: { power.launchAtLogin }, set: { power.setLaunchAtLogin($0) })) {
                Text(power.launchNeedsApproval ? "Автозапуск: разрешите в Объектах входа" : "Открывать TouTou при включении Mac")
                    .font(.system(size: 9))
            }.toggleStyle(.checkbox).controlSize(.mini)
            .help("Добавляет TouTou в объекты входа, чтобы панель появлялась после включения или входа в систему")
            Toggle(isOn: $power.restoreOnQuit) {
                Text("Вернуть обычный сон при выходе из TouTou").font(.system(size: 9))
            }.toggleStyle(.checkbox).controlSize(.mini)
        }.padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }
    func displayedPercent(_ window: QuotaWindow, id: String) -> Double {
        // Cursor's own dashboard shows used % ("Cursor Models 3%"); ChatGPT card stays on remaining.
        if id == "cursor", let used = window.usedPercent { return used }
        return window.remainingPercent
    }
    func distinctResets(_ provider: ProviderQuota) -> Bool {
        Set(provider.windows.compactMap { $0.resetsAt.map { Int($0) } }).count > 1
    }
    func noteText(_ provider: ProviderQuota) -> String {
        var parts = provider.notes ?? []
        if !distinctResets(provider), let timestamp = provider.windows.compactMap({ $0.resetsAt }).first {
            parts.append("сброс " + shortReset(timestamp))
        }
        return parts.joined(separator: " · ")
    }
    func windowHelp(_ window: QuotaWindow) -> String {
        let used = window.usedPercent ?? (100 - window.remainingPercent)
        let remaining = window.remainingPercent
        let text = String(format: "Использовано %.1f%%, осталось %.1f%%", used, remaining)
        return text + ". " + resetText(window.resetsAt)
    }
    func shortReset(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let delta = date.timeIntervalSinceNow
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        if delta <= 60 { return "сейчас" }
        if delta < 3600 { return "через \(max(1, Int(delta / 60))) мин" }
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        formatter.dateFormat = delta < 172800 ? "d MMM, HH:mm" : "d MMM"
        return formatter.string(from: date)
    }
    func resetText(_ timestamp: Double?) -> String {
        guard let timestamp = timestamp else { return "Остаток включённого лимита" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM, HH:mm"
        return "Сброс: " + formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(22, rect.height / 2))
    }
}

// AppKit normally constrains windows to the area below the menu bar.
// A notch companion deliberately occupies that reserved top strip.
final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    let store = SessionStore()
    let usage = UsageStore()
    let power = PowerStore()
    let alerts = QuotaAlertCenter()
    override init() {
        super.init()
        usage.onSnapshot = { [weak self] snapshot in self?.alerts.consider(snapshot) }
        alerts.onOpen = { [weak self] in
            guard let self = self else { return }
            self.panel.orderFrontRegardless()
            self.store.expanded = true
            self.updatePause()
        }
        power.onSafetyNotice = { [weak self] title, body in self?.alerts.postSafety(title: title, body: body) }
    }
    private var subscriptions = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var animationTimer: Timer?
    func positionPanel(animated: Bool = true) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let top = screen.safeAreaInsets.top
        var centerX = screen.frame.midX
        store.notchHeight = top > 0 ? top : 30
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, top > 0 {
            store.notchWidth = max(120, right.minX - left.maxX)
            centerX = (right.minX + left.maxX) / 2
        } else { store.notchWidth = 180 }
        animationTimer?.invalidate()
        let start = store.expansionProgress
        let target: CGFloat = store.expanded ? 1 : 0
        let compactWidth = store.notchWidth + IslandLayout.compactExtra
        let compactHeight = store.notchHeight
        let expandedHeight = IslandLayout.expandedHeight
        func apply(_ progress: CGFloat) {
            let width = compactWidth + (IslandLayout.expandedWidth - compactWidth) * progress
            let height = compactHeight + (expandedHeight - compactHeight) * progress
            self.store.expansionProgress = progress
            self.panel.setFrame(NSRect(x: centerX - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: true)
        }
        guard animated, panel.isVisible, abs(start - target) > 0.001,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            apply(target)
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let duration = target > start ? 0.32 : 0.26
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            let time = min(1, (ProcessInfo.processInfo.systemUptime - started) / duration)
            // Smooth acceleration and deceleration; a reversal starts at the current size.
            let eased = CGFloat(time * time * (3 - 2 * time))
            apply(start + (target - start) * eased)
            if time >= 1 { timer.invalidate() }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 394, height: 500), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: IslandView(store: store, usage: usage, power: power, alerts: alerts).frame(maxHeight: .infinity, alignment: .top).ignoresSafeArea())
        host.sizingOptions = []
        panel.contentView = host
        positionPanel(animated: false)
        store.$expanded.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] expanded in
            guard let self = self else { return }
            self.positionPanel()
            // Fresh numbers when the user actually looks, instead of polling in the background.
            if expanded {
                self.usage.refreshIfStale(90)
                if self.store.tab == .power { self.power.refreshIfStale() }
            }
        }.store(in: &subscriptions)
        store.$tab.removeDuplicates().sink { [weak self] tab in if tab == .power { self?.power.refreshIfStale() } }.store(in: &subscriptions)
        store.$sessions.map { $0.isEmpty }.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.positionPanel() }.store(in: &subscriptions)
        store.$sessions.map { $0.contains { $0.state == "working" } }.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] working in self?.power.setAgentWorking(working) }.store(in: &subscriptions)
        // On battery the expensive quota refresh runs half as often.
        power.$onBattery.removeDuplicates().sink { [weak self] battery in self?.usage.interval = battery ? 600 : 300 }.store(in: &subscriptions)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.updatePause(asleep: true) }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.updatePause(asleep: false) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.positionPanel() }
        panel.orderFrontRegardless()
        alerts.start()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "TouTou")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }
    private var screensAsleep = false
    private func updatePause(asleep: Bool? = nil) {
        if let asleep = asleep { screensAsleep = asleep }
        // A hidden panel still needs fresh quotas, otherwise a low-balance banner never fires.
        // Screen sleep is the only pause: nothing can be announced until the display wakes.
        usage.paused = screensAsleep
    }
    @objc func toggle() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        updatePause()
    }
    @objc func revealPanel() {
        panel.orderFrontRegardless()
        store.expanded = true
        updatePause()
    }
    @objc func togglePin() { store.togglePin(); if store.pinned { revealPanel() } }
    @objc func toggleAgentWake() { power.stayAwakeWhileAgent.toggle() }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, action: Selector?, state: NSControl.StateValue = .off, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = action == nil ? nil : self
            item.state = state
            item.isEnabled = enabled
            return item
        }
        menu.addItem(item(panel.isVisible ? "Скрыть панель" : "Показать панель", action: #selector(toggle)))
        menu.addItem(item(store.pinned ? "Открепить панель" : "Закрепить панель", action: #selector(togglePin)))
        menu.addItem(.separator())
        if let snapshot = usage.snapshot {
            for provider in snapshot.providers {
                let name = provider.provider == "chatgpt" ? "ChatGPT" : (provider.provider == "cursor" ? "Cursor" : provider.provider)
                if let worst = provider.windows.min(by: { $0.remainingPercent < $1.remainingPercent }) {
                    let shown = provider.provider == "cursor" ? (worst.usedPercent ?? 100 - worst.remainingPercent) : worst.remainingPercent
                    let text = provider.provider == "cursor" ? "\(name) · исп. \(Int(shown.rounded()))%" : "\(name) · \(Int(shown.rounded()))%"
                    menu.addItem(item(text, action: nil, enabled: false))
                } else {
                    menu.addItem(item("\(name) · нет данных", action: nil, enabled: false))
                }
            }
        }
        if let event = store.sessions.first {
            let title = "\(projectName(event.project)) · \(event.detail)"
            menu.addItem(item(String(title.prefix(56)), action: #selector(revealPanel)))
        } else if let summary = todaySummary(from: store.sessions) {
            menu.addItem(item(summary, action: nil, enabled: false))
        }
        menu.addItem(.separator())
        menu.addItem(item("Не спать, пока агент работает", action: #selector(toggleAgentWake), state: power.stayAwakeWhileAgent ? .on : .off))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
    func applicationWillTerminate(_ notification: Notification) { power.restoreBeforeQuit() }
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--screen-info") {
    for screen in NSScreen.screens {
        print("Screen:", screen.localizedName, "frame:", screen.frame, "visible:", screen.visibleFrame, "safeTop:", screen.safeAreaInsets.top, "left:", String(describing: screen.auxiliaryTopLeftArea), "right:", String(describing: screen.auxiliaryTopRightArea))
    }
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
    // Renders the expanded panel for each tab into PNG files: <path>-quotas.png, <path>-power.png.
    let base = CommandLine.arguments[index + 1]
    let store = SessionStore(), usage = UsageStore(), power = PowerStore()
    store.expanded = true
    store.expansionProgress = 1
    if ProcessInfo.processInfo.environment["TOUTOU_DEMO"] != nil || ProcessInfo.processInfo.environment["TOUTU_DEMO"] != nil { store.toggleDemo() }
    RunLoop.main.run(until: Date().addingTimeInterval(ProcessInfo.processInfo.environment["TOUTOU_DEMO"] != nil || ProcessInfo.processInfo.environment["TOUTU_DEMO"] != nil ? 1 : 8))
    for tab in PanelTab.allCases {
        store.tab = tab
        let host = NSHostingView(rootView: IslandView(store: store, usage: usage, power: power, alerts: QuotaAlertCenter()))
        host.frame = NSRect(x: 0, y: 0, width: IslandLayout.expandedWidth, height: IslandLayout.expandedHeight)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "-" + tab.rawValue + ".png"))
    }
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
