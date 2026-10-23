import AppKit
import UserNotifications

/// Pulls the user back when a turn ends while they're in another app. The
/// panel hides on every deactivation (see AppDelegate.applicationDidResignActive),
/// so by the time a reply finishes the user is somewhere else with no signal
/// at all — the only way to notice is re-summoning the panel by hand.
///
/// Two channels behind one gate: a system banner (tap it to reopen the panel)
/// and a system sound (needs no authorization, so it keeps working when
/// banners are denied). Off by default — the Settings toggle enables it and
/// is the one moment authorization is requested. Never fires while Mia is
/// the active app: active means the user is looking at the panel and can
/// watch the answer land.
@MainActor
final class CompletionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CompletionNotifier()

    /// UserDefaults keys, shared with SettingsView's @AppStorage bindings.
    /// A missing enabled key reads false — banners are strictly opt-in.
    static let enabledKey = "notifyOnCompletion"
    static let soundKey = "notifyCompletionSound"

    /// Reopens the panel when a banner is clicked. Wired by AppDelegate at
    /// launch so a cold-start click still routes somewhere.
    private var onActivate: (() -> Void)?

    private override init() { super.init() }

    func configure(onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        // Before any delivery, so didReceive is in place even for a banner
        // the user clicks the instant the app launches.
        UNUserNotificationCenter.current().delegate = self
    }

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    private var wantsSound: Bool {
        // object(forKey:), not bool(forKey:) with its missing-becomes-false —
        // the sound defaults ON once notifications are on at all.
        UserDefaults.standard.object(forKey: Self.soundKey) as? Bool ?? true
    }

    /// The Settings toggle turning on: the one moment the system's
    /// authorization prompt is welcome. Denial doesn't disable the sound half.
    func requestAuthorization() {
        // Bare `swift build` runs (smoke tests) carry no bundle identity and
        // have no notification center to talk to.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A turn that produced an answer. Called from ChatStore's stream tail —
    /// never for a user-initiated stop (a stop IS the user already there).
    func turnFinished() {
        announce(
            title: "Reply ready",
            body: "Mia finished answering — click to view it.",
            sound: "Pop"
        )
    }

    /// A turn that ended without an answer: an error row, or a stream that
    /// simply came back empty. Either way the user's question is dangling.
    func turnFailed(_ summary: String) {
        announce(
            title: "Reply failed",
            body: summary.isEmpty
                ? "The turn ended without an answer — click to view what happened."
                : summary,
            sound: "Basso"
        )
    }

    private func announce(title: String, body: String, sound: String) {
        // Active = the user is in Mia, watching the panel. The cancelled-task
        // case never reaches here (ChatStore checks before calling), so this
        // guard is exactly "finished while away".
        guard isEnabled, !NSApp.isActive else { return }
        if wantsSound { NSSound(named: NSSound.Name(sound))?.play() }
        postBanner(title: title, body: body)
    }

    private func postBanner(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Silent on purpose: the sound half is NSSound, one switch governs
        // both — an authorized banner with its own sound would double-play.
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "turn-\(UUID().uuidString)", content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate (callbacks arrive off MainActor)

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Rare by construction (nothing is posted while Mia is active), but
        // if one lands while the app is frontmost, show it, don't drop it.
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            // The click came from Notification Center, so Mia is not active.
            // The panel's own show() orders it front without stealing
            // activation — pull that first or the panel surfaces unfocused
            // under the user's current app.
            NSApp.activate(ignoringOtherApps: true)
            onActivate?()
            completionHandler()
        }
    }
}
