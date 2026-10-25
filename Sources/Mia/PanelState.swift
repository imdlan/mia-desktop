import Foundation

/// Shared UI state between the panel controller (AppKit) and the chat view (SwiftUI).
final class PanelState: ObservableObject {
    /// Always-on-top. When false, the panel hides as soon as it loses key status
    /// (i.e. you click into another app). Persisted — "keep Mia around" is a
    /// decision made once, not re-made every session. 0.6.0's short-lived
    /// "Hide when switching apps" preference migrates in: turning that off
    /// meant the same thing as pinning, so it seeds this flag.
    @Published var pinned = PanelState.restorePin() {
        didSet { UserDefaults.standard.set(pinned, forKey: PanelState.pinKey) }
    }

    /// Bumped every time the panel is shown or re-focused; the chat view observes
    /// this to move keyboard focus into the input field.
    @Published var focusBump = 0

    // MARK: - Persistence

    private static let pinKey = "panelPinned"

    private static func restorePin() -> Bool {
        if UserDefaults.standard.object(forKey: "hideOnFocusLoss") != nil,
           !UserDefaults.standard.bool(forKey: "hideOnFocusLoss") {
            return true
        }
        return UserDefaults.standard.bool(forKey: pinKey)
    }
}
