import AppKit
import Combine
import IOKit.ps
import ServiceManagement

// Keeps the Mac running with the lid closed so agents finish their work.
// macOS only honours lid-closed wake through `pmset -a disablesleep 1`, which
// needs administrator rights; the system password prompt is shown each time.
// While an agent is working, `caffeinate -i` holds idle sleep without a password.
final class PowerStore: ObservableObject {
    static let batteryFloor = 20

    @Published var lidAwake = false
    @Published var busy = false
    @Published var onBattery = false
    @Published var batteryPercent: Int?
    @Published var message: String?
    @Published var launchAtLogin = false
    @Published var launchNeedsApproval = false
    @Published var holdingAgent = false
    @Published var batteryGuard = false
    @Published var restoreOnQuit = true {
        didSet { UserDefaults.standard.set(restoreOnQuit, forKey: "restoreSleepOnQuit") }
    }
    @Published var stayAwakeWhileAgent = true {
        didSet {
            UserDefaults.standard.set(stayAwakeWhileAgent, forKey: "stayAwakeWhileAgent")
            syncAgentWake()
        }
    }
    @Published var stopOnLowBattery = true {
        didSet {
            UserDefaults.standard.set(stopOnLowBattery, forKey: "stopOnLowBattery")
            syncAgentWake()
        }
    }
    var onSafetyNotice: ((String, String) -> Void)?
    private var enabledByApp = false
    private var agentWorking = false
    private var caffeinate: Process?
    private var timer: Timer?
    private var powerSource: CFRunLoopSource?
    private var lastSettingsRead: Date?

    init() {
        restoreOnQuit = UserDefaults.standard.object(forKey: "restoreSleepOnQuit") as? Bool ?? true
        stayAwakeWhileAgent = UserDefaults.standard.object(forKey: "stayAwakeWhileAgent") as? Bool ?? true
        stopOnLowBattery = UserDefaults.standard.object(forKey: "stopOnLowBattery") as? Bool ?? true
        readBattery()
        refreshLaunchAtLogin()
        refresh()
        // IOKit tells us when the power source changes; no polling required.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            Unmanaged<PowerStore>.fromOpaque(context).takeUnretainedValue().readBattery()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        // `pmset -g` spawns a process, so the system setting is re-read rarely;
        // the toggle and opening the Power tab refresh it on demand.
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 120
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        stopCaffeinate()
        if let source = powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    var batteryBlocked: Bool {
        stopOnLowBattery && onBattery && (batteryPercent ?? 100) <= Self.batteryFloor
    }

    func readBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let battery = type == kIOPMBatteryPowerKey
        var percent: Int?
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            percent = Int((Double(capacity) / Double(maximum) * 100).rounded())
            break
        }
        if onBattery != battery { onBattery = battery }
        if batteryPercent != percent { batteryPercent = percent }
        considerBatteryGuard()
        syncAgentWake()
    }

    static func read(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func sleepDisabled(in settings: String) -> Bool {
        settings.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    func refresh() {
        lastSettingsRead = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let disabled = Self.sleepDisabled(in: Self.read(["-g"]))
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !self.busy && self.lidAwake != disabled { self.lidAwake = disabled }
            }
        }
    }

    func refreshIfStale(_ seconds: TimeInterval = 30) {
        refreshLaunchAtLogin()
        guard Date().timeIntervalSince(lastSettingsRead ?? .distantPast) >= seconds else { return }
        refresh()
    }

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        launchNeedsApproval = status == .requiresApproval
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            message = on ? "TouTou откроется при включении" : "Автозапуск выключен"
        } catch {
            message = Bundle.main.bundlePath.hasSuffix(".app") ? "Не удалось изменить автозапуск" : "Соберите TouTou.app — автозапуск работает из приложения"
        }
        refreshLaunchAtLogin()
        if launchNeedsApproval { message = "Разрешите в Настройках → Объекты входа" }
    }

    func setLidAwake(_ on: Bool) {
        guard !busy, on != lidAwake else { return }
        busy = true
        message = nil
        let source = "do shell script \"/usr/bin/pmset -a disablesleep \(on ? 1 : 0)\" with administrator privileges"
        var failure: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&failure)
        busy = false
        if let failure = failure {
            let code = failure[NSAppleScript.errorNumber] as? Int
            message = code == -128 ? "Отменено" : "Нужен пароль администратора"
        } else {
            lidAwake = on
            enabledByApp = on
            message = on ? "Крышку можно закрывать" : "Обычный режим сна"
        }
        refresh()
    }

    func setAgentWorking(_ working: Bool) {
        agentWorking = working
        syncAgentWake()
    }

    func restoreBeforeQuit() {
        stopCaffeinate()
        guard restoreOnQuit, enabledByApp, lidAwake else { return }
        setLidAwake(false)
    }

    var statusText: String {
        var parts: [String] = []
        parts.append(onBattery ? "От батареи" : "От сети")
        if let percent = batteryPercent { parts[0] += " \(percent)%" }
        if holdingAgent { parts.append("агент держит сон") }
        parts.append(lidAwake ? "сон при закрытии выключен" : "при закрытии крышки уснёт")
        return parts.joined(separator: " · ")
    }

    private func considerBatteryGuard() {
        if batteryBlocked {
            let holding = holdingAgent || lidAwake
            stopCaffeinate()
            guard holding, !batteryGuard else { return }
            batteryGuard = true
            if lidAwake {
                message = "Батарея ≤\(Self.batteryFloor)%. Крышка всё ещё не даёт уснуть — выключите режим"
                onSafetyNotice?("Батарея ≤\(Self.batteryFloor)%", "Удержание агента снято. Режим закрытой крышки выключите сами: для pmset нужен пароль.")
            } else {
                message = "Батарея ≤\(Self.batteryFloor)%, удержание снято"
                onSafetyNotice?("Батарея ≤\(Self.batteryFloor)%", "Mac снова может уснуть, чтобы не разрядиться в сумке.")
            }
        } else if !onBattery || (batteryPercent ?? 100) > Self.batteryFloor + 5 {
            batteryGuard = false
        }
    }

    private func syncAgentWake() {
        if stayAwakeWhileAgent && agentWorking && !batteryBlocked {
            startCaffeinate()
        } else {
            stopCaffeinate()
        }
    }

    private func startCaffeinate() {
        if let existing = caffeinate, existing.isRunning {
            if !holdingAgent { holdingAgent = true }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i"]
        process.qualityOfService = .utility
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.caffeinate != nil else { return }
                self.caffeinate = nil
                if self.holdingAgent { self.holdingAgent = false }
            }
        }
        do {
            try process.run()
            caffeinate = process
            holdingAgent = true
            if message == nil { message = "Не уснёт, пока агент работает" }
        } catch {
            holdingAgent = false
            message = "Не удалось удержать бодрствование"
        }
    }

    private func stopCaffeinate() {
        let process = caffeinate
        caffeinate = nil
        process?.terminationHandler = nil
        process?.terminate()
        if holdingAgent { holdingAgent = false }
    }
}
