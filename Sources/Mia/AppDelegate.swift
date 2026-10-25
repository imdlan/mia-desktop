import AppKit
import SwiftUI
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let providerStore = ProviderStore()
    private let shortcutStore = ShortcutStore()
    /// Owned here (not built inside SettingsView) so the seed examples land
    /// at FIRST LAUNCH, not at first Settings open (P4 R4.3), and so reopening
    /// Settings reuses the same list the picker and ChatStore read.
    private let personaStore = PersonaStore()
    private let updateChecker = UpdateChecker()
    /// P5 selection floating button — same lifetime as the status item; built
    /// in didFinishLaunching because it needs the panel controller's show path.
    private var selectionButton: SelectionButtonController?
    private lazy var panelController = PanelController(providerStore: providerStore, shortcutStore: shortcutStore)
    private var settingsWindow: NSWindow?

    /// Hooks for `--smoke-firstrun`, which drives the real launch path.
    var isPanelOnScreen: Bool { panelController.isPanelOnScreen }
    func hidePanel() { panelController.hide() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Auto / Light / Dark (Settings › General): NSApp.appearance reaches every
        // window at once — panel, Settings, popovers; nil follows the system.
        AppearanceChoice.applyCurrent()
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // The bundled template art (44px raster = 22pt@2x) when the .app is
            // assembled; the SF Symbol stands in for bare swift-build runs,
            // where the png isn't in any bundle NSImage knows about.
            if let art = NSImage(named: "MiaMenubarIconTemplate") {
                art.size = NSSize(width: 22, height: 22)  // show at 22pt, keep 2x pixels
                art.isTemplate = true                     // suffix convention, made explicit
                button.image = art
            } else {
                button.image = NSImage(
                    systemSymbolName: "bubble.left.and.bubble.right.fill",
                    accessibilityDescription: "Mia"
                )
            }
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        KeyboardShortcuts.onKeyUp(for: .toggleMia) { [weak self] in
            self?.panelController.toggle()
        }

        // Turn-end notifications: clicking a banner reopens the panel, and
        // the notifier posts only when Mia isn't the active app (active means
        // the user is watching the panel already).
        CompletionNotifier.shared.configure { [weak self] in
            self?.panelController.show()
        }

        // P2 "ask about selection": the Services item declared in Info.plist
        // (NSServices → NSMessage) is delivered here. Registered at launch so
        // macOS can offer the service as soon as the menu bar item exists;
        // NSApp retains the provider, and the delegate outlives the app.
        NSApp.servicesProvider = self

        // P5 selection floating button: the click hands the captured text to
        // the SAME places the P2 Services handler feeds — the nonactivating
        // show path plus the quote channel — or sends it straight away when
        // the user opted into that. A send that gets refused (mid-stream)
        // falls back to the quote prefill so the text is never lost.
        selectionButton = SelectionButtonController { [weak self] text in
            guard let self else { return }
            if !self.panelController.isPanelOnScreen {
                self.panelController.show()
            }
            let quote = SelectionQuote.quote(text)
            if SelectionGesture.shouldSendImmediately(
                enabled: SelectionButtonController.sendImmediatelyEnabled, text: quote
            ), self.panelController.chatStore.send(quote) {
                return
            }
            NotificationCenter.default.post(name: .miaQuoteSelection, object: quote)
        }
        selectionButton?.start()

        // "Dismiss Mia" means all of it: a floating Settings window left
        // hovering over the app the user returned to reads as stuck. Only
        // USER-initiated dismissals (hotkey, Esc, ⌘W, close button) fire this —
        // the focus-loss auto-hide must not yank Settings away while the user
        // is off copying an API key from another app.
        panelController.onUserDismiss = { [weak self] in
            self?.settingsWindow?.close()
        }

        NotificationCenter.default.addObserver(
            forName: .miaOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }

        // Read while the launch Apple event is still the current one — by the
        // time the block below runs it is gone.
        let loginItem = launchedAsLoginItem
        // Also read BEFORE presentLaunchUI records it: "has this install run
        // before" decides whether the orientation popover is already behind us,
        // which is when the one-time Services hint may take its turn.
        let ranBefore = UserDefaults.standard.bool(forKey: Self.hasLaunchedKey)

        // Build the panel + view hierarchy and load the resumed conversation off
        // the critical path, so the first hotkey press shows a warm panel.
        DispatchQueue.main.async { [weak self] in
            self?.panelController.prewarm()
            self?.presentLaunchUI(loginItem: loginItem)
        }

        // One-time pointer at "Ask Mia About Selection" (P2): the service
        // must be enabled — and is best given a shortcut — in System Settings,
        // which nobody guesses. Deliberately NOT on the first launch ever
        // (that one already gets the orientation popover; two hints at once
        // teach nothing) and never on a login-item launch, like everything
        // else that greets. FirstRunHint enforces the once-ever flag itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard ranBefore, !loginItem, let button = self?.statusItem.button else { return }
            FirstRunHint.showServicesHint(from: button)
        }

        // Not in the prewarm block: launch has nothing to gain from it, and the
        // check has no deadline. Nothing else reaches the network this early.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated { self?.updateChecker.checkIfDue() }
        }

        // Dock-icon mode (Settings → General). Overrides the accessory default
        // set before run(); the plist's LSUIElement keeps every launch that
        // never reaches here (and every install that leaves the pref off)
        // menubar-only.
        Self.applyDockVisibility()

        // A runtime .accessory→.regular switch does NOT register the app with
        // the window server's ⌘Tab list until it has been activated once — in
        // Dock-icon mode a freshly launched Mia sat in the Dock yet was absent
        // from ⌘Tab until the user clicked the icon. A manual launch in that
        // mode activates once here (a login-item launch stays quiet), which
        // both lists Mia in ⌘Tab from the start and gives the double-click a
        // visible window, like any regular app. presentLaunchUI's activate+show
        // covers only the FIRST launch ever; this is the every-other-day one.
        if NSApp.activationPolicy() == .regular, !loginItem {
            NSApp.activate(ignoringOtherApps: true)
            panelController.show()
        }

        // With a Dock icon Mia joins ⌘Tab, and switching to it activates the
        // app. The panel auto-hides on focus loss, so activating with no
        // visible window would read as "nothing happened" — bring the panel
        // back, unless one of Mia's own windows (Settings) already represents
        // it on screen. Accessory apps never become active, so this only ever
        // fires in Dock-icon mode.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      NSApp.activationPolicy() == .regular,
                      !self.panelController.isPanelOnScreen,
                      !(self.settingsWindow?.isVisible ?? false) else { return }
                self.panelController.show()
            }
        }
    }

    // MARK: - Dock visibility

    nonisolated static let showDockIconKey = "showDockIcon"

    /// Applies the persisted Dock-icon preference, live (no restart needed):
    /// `.regular` puts Mia in the Dock and ⌘Tab, `.accessory` restores the
    /// menubar-only form. The status item exists either way.
    static func applyDockVisibility() {
        let show = UserDefaults.standard.bool(forKey: showDockIconKey)
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }

    // MARK: - Being findable at all

    nonisolated static let hasLaunchedKey = "hasLaunchedBefore"

    /// Whether macOS started us at login rather than the user opening the app.
    /// MUST be read during `applicationDidFinishLaunching` — it inspects the
    /// launch Apple event, which is only the current event that early. A login
    /// launch is the one case where showing the panel is wrong: the user asked
    /// for Mia to be *ready*, not to greet them at every boot.
    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// An LSUIElement app that opens nothing looks broken: the status item is
    /// one of a dozen menu bar glyphs, and nothing on screen names the hotkey.
    /// So the first launch ever opens the panel and points at the icon once.
    func presentLaunchUI(loginItem: Bool) {
        let defaults = UserDefaults.standard
        let firstLaunch = !defaults.bool(forKey: Self.hasLaunchedKey)
        defaults.set(true, forKey: Self.hasLaunchedKey)
        guard firstLaunch, !loginItem else { return }

        // The panel is a non-activating panel, so it can show without stealing
        // focus — but on a first launch the user just double-clicked us and IS
        // expecting the foreground.
        NSApp.activate(ignoringOtherApps: true)
        panelController.show()
        // After the panel, never before: the hint is a `.transient` popover and
        // a window ordering in front of it would dismiss it on the spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let button = self?.statusItem.button else { return }
            FirstRunHint.show(from: button)
        }
    }

    /// Double-clicking an already-running LSUIElement app otherwise does
    /// NOTHING — macOS just reactivates it. That's the exact move someone makes
    /// when they think the app failed to start, so it has to show the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        FirstRunHint.dismiss()
        panelController.show()
        return true
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panelController.toggle()
        }
    }

    // Left click toggles the panel; the menu only appears on right/ctrl-click.
    // Assigning statusItem.menu permanently would hijack left click, so it's
    // attached just for the click and detached after.
    private func showMenu() {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "Toggle Mia", action: #selector(togglePanel), keyEquivalent: "")
        toggleItem.target = self
        // Shows the recorded global hotkey on the right, and keeps itself in
        // sync when the Recorder in Settings changes it.
        toggleItem.setShortcut(for: .toggleMia)
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // The one ambient surface for a new version. It appears only when there
        // IS one, so the menu is unchanged for everybody who is current.
        if let release = updateChecker.availableRelease {
            let updateItem = NSMenuItem(
                title: "Update available: \(release.version)…",
                action: #selector(openReleasePage), keyEquivalent: ""
            )
            updateItem.target = self
            menu.addItem(updateItem)
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Mia", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        // Delegate disables the global hotkey while the menu tracks — see the
        // NSMenuDelegate extension below.
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePanel() {
        panelController.toggle()
    }

    // MARK: - Services (P2: ask about selection)

    /// The "Ask Mia About Selection" Services item (Info.plist NSServices →
    /// NSMessage). The selection arrives on the pasteboard; a blank one still
    /// shows the panel — "ask, no quote" beats a menu item that does nothing.
    ///
    /// `show()`, not `toggle()`: the service always means "appear", never
    /// "dismiss" — a second invocation with the panel already up must add the
    /// quote, not eat the panel. And it is the same nonactivating path ⌥Space
    /// takes: the panel orders in over the source app without activating
    /// Mia, so the user's document keeps focus; the composer still becomes
    /// first responder (show() bumps focusBump), which is what makes the
    /// prefilled quote immediately editable.
    @objc func askWithSelection(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) {
        if !panelController.isPanelOnScreen {
            panelController.show()
        }
        // Services may deliver either the modern UTF8 type or the legacy
        // NSStringPboardType this app declares; either spelling is the text.
        let selection = pboard.string(forType: .string)
            ?? pboard.string(forType: NSPasteboard.PasteboardType(rawValue: "NSStringPboardType"))
            ?? ""
        let quote = SelectionQuote.quote(selection)
        guard !quote.isEmpty else { return }
        // The composer's draft is private to ComposerView by design (keystrokes
        // must never invalidate the transcript), so cross-boundary injections
        // go through the same one-shot NotificationCenter channel the
        // pasteboard-attachment path uses.
        NotificationCenter.default.post(name: .miaQuoteSelection, object: quote)
    }


    /// Mia never installs anything itself — this hands the user off to the
    /// release page, where the DMG they already know how to use is waiting.
    @objc private func openReleasePage() {
        guard let release = updateChecker.availableRelease else { return }
        NSWorkspace.shared.open(release.page)
    }

    /// Clicking into another app dismisses ALL of Mia — Settings included.
    /// Both windows float above whatever the user switched to (the panel by
    /// design, Settings because it must open over the floating panel), so
    /// anything left behind hovers ON TOP of the other app and reads as stuck.
    /// The Settings window is retained, so reopening it restores it exactly as
    /// left — that is the copy-an-API-key flow. Pinning is the explicit
    /// "keep it around" and exempts everything. Note the panel-only flow may
    /// never activate the app at all (nonactivating panel); its auto-hide is
    /// windowDidResignKey in PanelController, not this.
    func applicationDidResignActive(_ notification: Notification) {
        guard !panelController.isPinned, PanelController.hideOnFocusLoss else { return }
        settingsWindow?.close()
        panelController.hide()
    }

    /// ⌘A/⌘C/⌘V/⌘X/⌘Z are MENU key equivalents on macOS, not text-view built-ins.
    /// An LSUIElement app never shows a menu bar, but NSApp.mainMenu is still
    /// consulted for key equivalents — without this invisible Edit menu, none of
    /// the standard edit shortcuts work anywhere in the app.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        // ⌘W. No visible menu bar means no File/Window menu, so without this the
        // Settings window closes only via its traffic-light X — and the panel
        // ignores ⌘W entirely.
        let closeItem = NSMenuItem(title: "Close Window", action: #selector(closeKeyWindow), keyEquivalent: "w")
        closeItem.target = self
        appMenu.addItem(closeItem)
        // ⌘Q. Invisible in menubar-only mode (the status menu has its own Quit),
        // but load-bearing once the Dock-icon pref promotes us to `.regular`:
        // a frontmost regular app without a keyboard Quit is a dead end.
        let quitItem = NSMenuItem(title: "Quit Mia", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// ⌘W: hide the panel (a user dismissal, so Settings goes with it) or close
    /// whatever other closable window is key. Popover windows aren't closable
    /// and fall through to a no-op.
    @objc private func closeKeyWindow() {
        guard let key = NSApp.keyWindow else { return }
        if key is FloatingPanel {
            panelController.dismiss()
        } else if key.styleMask.contains(.closable) {
            key.performClose(nil)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = DismissOnEscWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Mia"
            // The tab strip sits on the (transparent) titlebar so window, strip
            // and form read as one panel; the title itself stays visible above
            // the tabs. `title` also feeds Exposé and accessibility.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
            window.contentView = NSHostingView(rootView: SettingsView(store: providerStore, shortcutStore: shortcutStore, personaStore: personaStore, updates: updateChecker))
            window.isReleasedWhenClosed = false
            // The chat panel floats (.floating level); a normal-level Settings
            // window would always open BEHIND it. Same level + orderFront wins.
            window.level = .floating
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    // While the status menu is tracking, the global hotkey can't fire — its key
    // events would just buffer up and dump into the panel the moment the menu
    // closes. Unregister for the menu session instead (KeyboardShortcuts'
    // documented pattern for shortcut-displaying menu items).
    func menuWillOpen(_ menu: NSMenu) {
        KeyboardShortcuts.disable(.toggleMia)
    }

    func menuDidClose(_ menu: NSMenu) {
        KeyboardShortcuts.enable(.toggleMia)
    }
}

/// Settings window for an LSUIElement app: no Window menu exists, so Esc has to
/// be handled by the window itself (⌘W comes from the invisible main menu).
/// Intercepted in `sendEvent`, not `cancelOperation`: a focused text field's
/// editor consumes Esc first — NSTextView turns it into the completion popup —
/// so the responder chain never reaches the window. The one Esc that must keep
/// its normal meaning is an in-progress IME composition (the Commands tab takes
/// CJK input), hence the marked-text guard.
private final class DismissOnEscWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == 53, // Esc
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           !((firstResponder as? NSTextView)?.hasMarkedText() ?? false) {
            close()
            return
        }
        super.sendEvent(event)
    }
}
