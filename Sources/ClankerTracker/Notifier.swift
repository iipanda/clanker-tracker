import ClankerCore
import Foundation
import Observation
import UserNotifications

/// Sends the run-out / threshold / reset notifications decided by `NotificationPlanner`.
@Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    enum Authorization { case unknown, allowed, denied }
    private(set) var authorization: Authorization = .unknown
    @ObservationIgnored var onOpen: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let ledgerKey = "notificationLedger"
    private let seededKey = "notificationsSeeded"

    /// UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func setUp() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refreshAuthorization()
        }
    }

    func refreshAuthorization() async {
        guard available else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        authorization = switch status {
        case .authorized, .provisional: .allowed
        case .denied: .denied
        default: .unknown
        }
    }

    /// Checks every current limit. While the first Codex read is running, or on the very first
    /// launch, conditions are only recorded so old news isn't announced.
    func evaluate(_ forecasts: [Forecast], prefs: NotificationPrefs, isInitialLoad: Bool, now: Date) {
        var ledger = (defaults.dictionary(forKey: ledgerKey) as? [String: Double] ?? [:])
            .mapValues { Date(timeIntervalSince1970: $0) }
        let seeded = defaults.bool(forKey: seededKey)
        let planned = NotificationPlanner.plan(forecasts, prefs: prefs, ledger: &ledger, now: now, deliver: seeded && !isInitialLoad)
        defaults.set(ledger.mapValues(\.timeIntervalSince1970), forKey: ledgerKey)
        if !isInitialLoad && !seeded { defaults.set(true, forKey: seededKey) }
        for n in planned { send(id: n.id, title: n.title, body: n.body) }
    }

    func sendTest() {
        send(id: "test-\(UUID().uuidString)", title: "Claude Code 5-hour limit runs out around \(Fmt.clock(Date().addingTimeInterval(42 * 60)))",
             body: "This is a test. Real alerts look like this, once per window.")
    }

    private func send(id: String, title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { onOpen?() }
    }
}
