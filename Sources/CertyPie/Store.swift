import Foundation
import AppKit
import ServiceManagement
import UserNotifications

@MainActor
final class Store: ObservableObject {
    @Published private(set) var allItems: [ExpiryItem] = []
    @Published private(set) var lastScan: Date?
    @Published var thresholdDays: Int { didSet { defaults.set(thresholdDays, forKey: "thresholdDays") } }
    @Published var checkHour: Int { didSet { defaults.set(checkHour, forKey: "checkHour") } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notifications") } }
    @Published var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { NSLog("Launch at login error: \(error)") }
        }
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    /// Items expiring within threshold (or already expired).
    var flagged: [ExpiryItem] { allItems.filter { $0.daysLeft <= thresholdDays } }

    /// Demo mode (screenshots): fixed fake items, no scanning, no timers.
    init(demoItems: [ExpiryItem]) {
        thresholdDays = 7; checkHour = 9; notificationsEnabled = true; launchAtLogin = false
        allItems = demoItems
        lastScan = Date()
    }

    init() {
        let d = UserDefaults.standard
        thresholdDays = d.object(forKey: "thresholdDays") as? Int ?? 7
        checkHour = d.object(forKey: "checkHour") as? Int ?? 9
        notificationsEnabled = d.object(forKey: "notifications") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled

        refresh()
        runScheduledCheckIfDue()
        // Poll each minute + on wake: covers "9:00 or as soon as possible".
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runScheduledCheckIfDue() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.runScheduledCheckIfDue() }
        }
    }

    func refresh() {
        allItems = Scanner.scan()
        lastScan = Date()
    }

    /// Manual check from the UI.
    func checkNow() { refresh() }

    private func runScheduledCheckIfDue() {
        let cal = Calendar.current
        let now = Date()
        guard let scheduled = cal.date(bySettingHour: checkHour, minute: 0, second: 0, of: now),
              now >= scheduled else { return }
        if let last = defaults.object(forKey: "lastScheduledRun") as? Date, last >= scheduled { return }
        defaults.set(now, forKey: "lastScheduledRun")
        refresh()
        notify()
    }

    private func notify() {
        guard notificationsEnabled, !flagged.isEmpty,
              Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let total = flagged.count
        let expired = flagged.filter { $0.isExpired }.count
        let days = thresholdDays
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(format: NSLocalizedString("Xcode: %lld items expiring", comment: ""), total)
            content.body = expired > 0
                ? String(format: NSLocalizedString("%lld already expired. Open Certy Pie for details.", comment: ""), expired)
                : String(format: NSLocalizedString("Certificates/profiles expiring within %lld days.", comment: ""), days)
            center.add(UNNotificationRequest(identifier: "daily-check", content: content, trigger: nil))
        }
    }
}
