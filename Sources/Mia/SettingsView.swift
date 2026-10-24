import AppKit
import SwiftUI
import ApplicationServices
import KeyboardShortcuts
import ServiceManagement

/// System Settings-style window: toolbar tabs over a grouped form per tab.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, appearance, providers, chat, about

        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: "General"
            case .appearance: "Appearance"
            case .providers: "Providers"
            case .chat: "Chat"
            case .about: "About"
            }
        }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintpalette"
            case .providers: "key"
            case .chat: "message"
            case .about: "info.circle"
            }
        }
    }

    @ObservedObject var store: ProviderStore
    @ObservedObject var shortcutStore: ShortcutStore
    @ObservedObject var personaStore: PersonaStore
    @ObservedObject var updates: UpdateChecker
    @State private var tab: Tab
    @State private var searchKeyDraft = ""
    /// Seeds from the CUSTOM prompt, not the resolved one: with a persona
    /// active, seeding from ChatStore.systemPrompt would prefill the persona's
    /// text into the Custom editor, where a stray keystroke would adopt it as
    /// the user's own prompt.
    @State private var systemPromptDraft = UserDefaults.standard.string(forKey: "systemPrompt") ?? ChatStore.defaultSystemPrompt
    @AppStorage("searchEngine") private var searchEngine = SearchEngineChoice.duckduckgo.rawValue
    @AppStorage("webSearchEnabled") private var webEnabled = true
    /// Default ON via the @AppStorage default (never-written key reads true);
    /// ChatStore.autoTitleEnabled mirrors it with object(forKey:) for the same
    /// reason webSearchEnabled does — bool(forKey:) turns missing into false.
    @AppStorage("autoTitleEnabled") private var autoTitleEnabled = true
    /// P5 selection button switches. The controller reads both through its own
    /// object(forKey:) accessors — the AppStorage defaults keep the UI in step
    /// without either side owning a Bool(forKey:) trap (both default correctly:
    /// show = on, send = off).
    @AppStorage("selectionButtonEnabled") private var selectionButtonEnabled = true
    @AppStorage("selectionSendImmediately") private var selectionSendImmediately = false
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @AppStorage("customAccentColor") private var customAccentHex = ""
    @AppStorage("bubbleStyle") private var bubbleStyleRaw = BubbleStyle.accentTint.rawValue
    @AppStorage("streamingMode") private var streamingModeRaw = StreamingMode.perCharacter.rawValue
    @AppStorage("liquidGlass") private var liquidGlass = true
    @AppStorage("panelTint") private var panelTint = -1.0
    @AppStorage("appearance") private var appearanceRaw = AppearanceChoice.auto.rawValue
    /// Dock-icon mode: promotes the app to `.regular` (Dock + ⌘Tab) live.
    @AppStorage("showDockIcon") private var showDockIcon = false
    @AppStorage(UpdateChecker.automaticChecksKey) private var automaticUpdateChecks = true
    @AppStorage(CompletionNotifier.enabledKey) private var notifyOnCompletion = false
    @AppStorage(CompletionNotifier.soundKey) private var notifyCompletionSound = true
    @AppStorage(CodexAppServerClient.executablePathKey) private var codexExecutablePath = ""
    @FocusState private var focusedCommandName: UUID?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    // ChatGPT sign-in state. Auth itself lives in ChatGPTAuth (SecretStore-backed);
    // `chatGPTAuthTick` just forces re-render after sign-in/out completes.
    @State private var chatGPTSignInTask: Task<Void, Never>?
    @State private var chatGPTAuthError: String?
    @State private var chatGPTAuthTick = false
    // Bumped on every sign-in/cancel so a stale attempt can't clobber the shared
    // UI state of a newer one (cancel-then-reclick race).
    @State private var chatGPTSignInGeneration = 0
    /// Custom provider awaiting delete confirmation (removal drops its API key).
    @State private var providerPendingDeletion: UUID?
    /// P5: live Accessibility-trust state for the Selection section. Refreshed
    /// on appear and on the system's AX notification, because granting in
    /// System Settings happens in ANOTHER app — nothing local invalidates it.
    @State private var axTrusted = AXIsProcessTrusted()
    /// The one provider row disclosed for editing (delta 5, 7b). Nothing here
    /// touches `store.selectedID` — Settings is a catalog, the panel's pill owns
    /// what is live.
    @State private var editingID: UUID?
    /// Non-nil only from the design-QA harness, which needs a row already
    /// disclosed to render the editor band.
    private let initialEditingID: UUID?
    /// API-key draft, scoped to `editingID`. Reloaded on every expand; the old
    /// `apiKeyDraft` + `onChange(of: store.selectedID)` pair is exactly the
    /// coupling delta 5 removes.
    @State private var keyDraft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        store: ProviderStore, shortcutStore: ShortcutStore,
        personaStore: PersonaStore,
        updates: UpdateChecker, tab: Tab = .general, editing: UUID? = nil
    ) {
        self.store = store
        self.shortcutStore = shortcutStore
        self.personaStore = personaStore
        self.updates = updates
        _tab = State(initialValue: tab)
        initialEditingID = editing
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch tab {
                case .general: generalTab
                case .appearance: appearanceTab
                case .providers: providersTab
                case .chat: chatTab
                case .about: aboutTab
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 540, height: 620)
        // Paint the page color explicitly: the tab strip carries no background of
        // its own, so it otherwise shows whatever is BEHIND the view — the window
        // in the app, but the zeroed (black) buffer in the design-QA bitmap, which
        // sank the secondary tab labels in light-mode shots.
        .background(formPageBackground)
        // Let the page reach the window's top edge so the tab strip and the
        // traffic lights sit on one continuous panel. No-op in a plain titled
        // window (the design-QA harness), which has no titlebar inset.
        .ignoresSafeArea()
        .onAppear { searchKeyDraft = currentSearchKey() }
        .onChange(of: searchEngine) { _, _ in searchKeyDraft = currentSearchKey() }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 19))
                        Text(item.label)
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(width: 76, height: 52)
                    .background(
                        tab == item ? Color.primary.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .foregroundStyle(tab == item ? Color.accentColor : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        // Headroom for the traffic lights: the tab row is centered and the
        // close button sits top-left, so only the strip's top edge needs the
        // space once the content is full-bleed.
        .padding(.top, 28)
        .padding(.bottom, 8)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch Mia at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginItemError = nil
                        } catch {
                            loginItemError = "Couldn't update login item: \(error.localizedDescription)"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let error = loginItemError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                sectionHeader("Startup")
            }
            Section {
                updateRow
                Toggle("Check for updates automatically", isOn: $automaticUpdateChecks)
            } header: {
                sectionHeader("Updates")
            } footer: {
                sectionFooter("Mia checks GitHub Releases once a day and tells you when a newer version exists. It never downloads or installs anything — updating is opening the release page and dragging the new build to Applications, same as the first time.")
            }
            Section {
                KeyboardShortcuts.Recorder("Toggle Mia:", name: .toggleMia)
                Toggle("Show Dock icon", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, enabled in
                        // @AppStorage's write timing is opaque; the apply reads
                        // the default directly, so make the value land first.
                        UserDefaults.standard.set(enabled, forKey: AppDelegate.showDockIconKey)
                        AppDelegate.applyDockVisibility()
                    }
            } header: {
                sectionHeader("Show & Hide")
            } footer: {
                sectionFooter("If ⌥Space is taken by another app, unbind it there or record a different shortcut. The Dock icon is off by default: turn it on and Mia also appears in the Dock and ⌘Tab, with switching to it reopening the panel — the menu-bar icon and the instant no-focus panel stay exactly as they are.")
            }
            Section {
                Toggle("Notify when replies finish", isOn: $notifyOnCompletion)
                    .onChange(of: notifyOnCompletion) { _, enabled in
                        // The toggle turning on is the one moment the system's
                        // authorization prompt is welcome; denial falls back to
                        // the sound alone.
                        if enabled { CompletionNotifier.shared.requestAuthorization() }
                    }
                Toggle("Play a sound", isOn: $notifyCompletionSound)
                    .disabled(!notifyOnCompletion)
            } header: {
                sectionHeader("Notifications")
            } footer: {
                sectionFooter("The panel hides whenever you click away, so a reply finishing elsewhere would go unnoticed. When on, a banner and a sound mark turns that finish (or fail) while Mia isn't frontmost — click the banner to reopen the panel. If notifications are denied in System Settings, the sound still plays. Off by default.")
            }
        }
    }

    private var appearanceTab: some View {
        Form {
            Section {
                appearanceRow
                accentRow
                liquidGlassRow
                panelTintRow
            } header: {
                sectionHeader("Appearance")
            } footer: {
                sectionFooter("Panel tint defaults to the system glass appearance; the slider overrides it for Mia only. Reduce Transparency always wins.")
            }
            Section {
                Picker("Your message style", selection: $bubbleStyleRaw) {
                    ForEach(BubbleStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Streaming text", selection: $streamingModeRaw) {
                    ForEach(StreamingMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                previewRow
            } header: {
                sectionHeader("Messages")
            } footer: {
                sectionFooter("Applies to your messages in the panel. Custom opens a picker for any accent color; Accent fill flips its text between black and white for whichever reads better. Streaming text: Per-character fades in glyph by glyph, Per-sentence commits a sentence at a time. Defaults: Accent tint, Blue, Per-character streaming.")
            }
        }
    }

    private var updateRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mia \(UpdateChecker.currentVersion)")
                switch updates.state {
                case .idle:
                    EmptyView()
                case .checking:
                    Text("Checking…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                case .upToDate:
                    Text("Up to date")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                case .available(let release):
                    Text("Version \(release.version) is available")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.color(accentHex))
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let release = updates.availableRelease {
                Link("What's new…", destination: release.page)
                    .font(.system(size: 11))
            }
            Button("Check Now") { updates.check(userInitiated: true) }
                .disabled(updates.state == .checking)
        }
    }

    // MARK: - Appearance

    /// Auto / Light / Dark (4f). Applied through NSApp.appearance so every
    /// window flips together; Auto (nil) tracks the system live.
    private var appearanceRow: some View {
        Picker("Appearance", selection: $appearanceRaw) {
            ForEach(AppearanceChoice.allCases) { choice in
                Text(choice.label).tag(choice.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: appearanceRaw) { _, _ in
            AppearanceChoice.applyCurrent()
        }
    }

    /// Four presets, then the rainbow-ringed custom swatch (AccentPicker.swift)
    /// separated by a hairline so it reads as "or make your own" rather than as
    /// a fifth preset. The custom color lives in its own key, so selecting a
    /// preset and coming back doesn't lose it.
    private var accentRow: some View {
        HStack(spacing: 2) {
            Text("Accent color")
            Spacer()
            ForEach(Theme.accentOptions, id: \.self) { hex in
                accentSwatch(hex)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 7)
            CustomAccentSwatch(accentHex: $accentHex, customHex: $customAccentHex)
            Text("Custom")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 3)
        }
    }

    private func accentSwatch(_ hex: String) -> some View {
        let selected = hex == accentHex
        return Button {
            accentHex = hex
        } label: {
            Circle()
                .fill(Theme.color(hex))
                .frame(width: 18, height: 18)
                .padding(2)
                .overlay(
                    Circle()
                        .strokeBorder(Theme.color(hex), lineWidth: 2)
                        .opacity(selected ? 1 : 0)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(hex)
    }

    private var liquidGlassRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Liquid glass", isOn: reduceTransparency ? .constant(false) : $liquidGlass)
                .disabled(reduceTransparency)
            Text(reduceTransparency
                ? "Off because Reduce Transparency is enabled in System Settings."
                : "Turn off for a solid panel and lower GPU use")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // labelsHidden is load-bearing: a bare Slider reserves an EMPTY label slot
    // inside its frame, which squeezed the track and stranded "Clear" mid-row.
    private var panelTintRow: some View {
        let disabled = !liquidGlass || reduceTransparency
        return HStack(spacing: 8) {
            Text("Panel tint")
            Spacer()
            Text("Clear")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Slider(
                value: Binding(
                    get: { panelTint < 0 ? 0.5 : panelTint },
                    set: { panelTint = $0 }
                ),
                in: 0...1
            )
            .labelsHidden()
            .frame(width: 180)
            Text("Tinted")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private var previewRow: some View {
        let style = BubbleStyle(rawValue: bubbleStyleRaw) ?? .accentTint
        return HStack {
            Text("Preview")
                .foregroundStyle(.secondary)
            Spacer()
            Text("Looks good — ship it")
                .font(.system(size: 13))
                .foregroundStyle(Theme.bubbleForeground(style: style, accentHex: accentHex))
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .background(
                    Theme.bubbleFill(style: style, accentHex: accentHex, dark: scheme == .dark),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
    }

    // MARK: - Providers

    /// Pure catalog (delta 5, 7b): every provider, no radio, no selection. A row
    /// discloses in place; the live provider+model is chosen from the panel's pill.
    /// The old design made "click the row you want to paste a key into" silently
    /// switch what the next message used.
    /// Hand-built rather than a `Form`: the grouped Form owns the layout of every
    /// row it contains — it re-reads a label/field HStack as its own label/value
    /// row and sizes the control itself, so the 230pt fields and the full-bleed
    /// editor band are simply not expressible inside it (same family as the
    /// vertical-axis-TextField trap in Commands, delta 2 §4e). The card below
    /// reproduces the grouped chrome by hand.
    private var providersTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Providers")
                    // Matches the grouped Form's own header inset on the other
                    // tabs (they sit ~10pt in from the card edge).
                    .padding(.leading, 10)
                VStack(spacing: 0) {
                    ForEach(Array(store.providers.enumerated()), id: \.element.id) { offset, provider in
                        if offset > 0 {
                            Divider().padding(.leading, 32).opacity(0.7)
                        }
                        providerRow(provider)
                        if editingID == provider.id {
                            editorBand(provider)
                        }
                    }
                    Divider().padding(.leading, 10).opacity(0.7)
                    addProviderRow
                }
                .background(
                    formCardBackground,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: editingID)
                sectionFooter("The live provider and model are picked from the pill in the chat panel — this list only manages what shows up there. Keys are stored locally, never synced.")
                    .padding(.leading, 10)
                    .help("~/Library/Application Support/Mia/secrets.json, user-only permissions.")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .background(formPageBackground)
        .onExitCommand { collapseEditor() }
        .onAppear {
            if let id = initialEditingID { toggleEditor(id) }
        }
        .confirmationDialog(
            "Remove “\(store.providers.first { $0.id == providerPendingDeletion }?.name ?? "")”?",
            isPresented: Binding(get: { providerPendingDeletion != nil }, set: { if !$0 { providerPendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Provider", role: .destructive) {
                if let id = providerPendingDeletion { store.remove(id) }
                providerPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { providerPendingDeletion = nil }
        } message: {
            Text("Its API key and fetched model list are deleted too.")
        }
    }

    /// Matches the grouped `Form` on the neighbouring tabs: same page color, and a
    /// group box that is a relative overlay on it rather than an absolute gray —
    /// so the card tracks the page in both appearances instead of needing two
    /// hand-picked constants that drift with the system.
    private var formPageBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var formCardBackground: Color {
        Color.primary.opacity(scheme == .dark ? 0.040 : 0.038)
    }

    private func providerRow(_ provider: Provider) -> some View {
        let expanded = editingID == provider.id
        let ready = providerIsReady(provider)
        return HStack(spacing: 10) {
            Circle()
                .fill(ready ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    // One badge per row: "Free" states the more useful fact
                    // (template rows are custom too — still deletable).
                    if provider.freeTemplate != nil {
                        providerBadge("Free", tint: .green)
                    } else if !provider.isPreset {
                        providerBadge("Custom", tint: nil)
                    }
                }
                Text(providerSubtitle(provider))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.6))
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(expanded ? Color.primary.opacity(0.03) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { toggleEditor(provider.id) }
        .contextMenu {
            if !provider.isPreset {
                Button("Remove Provider…", role: .destructive) {
                    providerPendingDeletion = provider.id
                }
            }
        }
    }

    /// Gray "Custom" / green "Free" chip beside the provider name.
    private func providerBadge(_ text: String, tint: Color?) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                (tint ?? Color.primary).opacity(tint == nil ? 0.07 : 0.14),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
    }

    private var addProviderRow: some View {
        HStack {
            Menu {
                Button("Custom…") {
                    let id = store.addCustom()
                    keyDraft = ""
                    editingID = id
                }
                Section("Free tiers") {
                    ForEach(FreeProviderTemplate.all) { template in
                        Button(template.name) {
                            let id = store.addTemplate(template)
                            keyDraft = ""
                            editingID = id
                        }
                    }
                }
                Divider()
                Button("More free APIs…") {
                    NSWorkspace.shared.open(FreeProviderTemplate.directoryURL)
                }
            } label: {
                Text("Add Provider…")
            }
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Green-dot law (delta 5): identical predicate to `configuredProviders`, so a
    /// green row here is exactly a row the panel's switcher offers.
    private func providerIsReady(_ provider: Provider) -> Bool {
        _ = chatGPTAuthTick // re-read the dot when sign-in state changes
        return store.isConfigured(provider)
    }

    private func providerSubtitle(_ provider: Provider) -> String {
        if provider.kind == .chatGPT {
            _ = chatGPTAuthTick
            guard ChatGPTAuth.isSignedIn else { return "Not signed in · unofficial direct access" }
            return "Signed in · \(ChatGPTAuth.planLabel ?? "your ChatGPT plan") · unofficial"
        }
        if provider.kind == .codexAppServer {
            switch store.codexAppServerStatus {
            case .unknown: return "Not checked"
            case .checking: return "Checking installed Codex…"
            case .ready(let email, let plan):
                let detail = [email, plan].compactMap { $0 }.joined(separator: " · ")
                return detail.isEmpty ? "Installed Codex · signed in" : "Installed Codex · \(detail)"
            case .missing: return "Codex not found · install it yourself"
            case .notSignedIn: return "Codex installed · run codex login"
            case .failed: return "Codex app-server unavailable"
            }
        }
        let host = URL(string: provider.baseURL)?.host ?? provider.baseURL
        let isLocal = ["localhost", "127.0.0.1"].contains(host)
        guard store.isConfigured(provider) else {
            if provider.baseURL.isEmpty { return "Not set up" }
            // A local server needs no key, so "Needs API key" would send the user
            // looking for one that doesn't exist — it needs a model list instead.
            return isLocal ? "\(host) · no models fetched" : "Needs API key"
        }
        var parts = [host.isEmpty ? provider.baseURL : host]
        let count = store.knownModels[provider.id]?.count ?? 0
        if count > 0 {
            parts.append("\(count) model\(count == 1 ? "" : "s")")
        }
        if isLocal, store.key(for: provider.id).isEmpty {
            parts.append("no key needed")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Inline provider editor (7b)

    private func toggleEditor(_ id: UUID) {
        if editingID == id {
            collapseEditor()
        } else {
            // Drafts commit as they're typed (scoped to the expanded row), so
            // switching rows only has to reload the draft for the new one.
            keyDraft = store.key(for: id)
            editingID = id
            if store.providers.first(where: { $0.id == id })?.kind == .codexAppServer,
               store.codexAppServerStatus == .unknown {
                Task { await store.refreshCodexAppServer(includeModels: true) }
            }
        }
    }

    private func collapseEditor() {
        editingID = nil
        keyDraft = ""
    }

    /// The disclosed block under a row: a quaternary well band spanning the card,
    /// hairline top and bottom.
    @ViewBuilder
    private func editorBand(_ provider: Provider) -> some View {
        let index = store.providers.firstIndex { $0.id == provider.id }
        VStack(alignment: .leading, spacing: 8) {
            if provider.kind == .chatGPT {
                chatGPTAuthRows
            } else if provider.kind == .codexAppServer {
                codexAppServerRows
            } else if let index {
                if let template = FreeProviderTemplate.named(provider.freeTemplate) {
                    freeTierNotice(template)
                }
                if !provider.isPreset {
                    editorField("Name") {
                        TextField("", text: $store.providers[index].name)
                    }
                }
                editorField("Base URL") {
                    TextField("", text: $store.providers[index].baseURL)
                        .help("Include /v1 where the provider requires it; local servers (Ollama, LM Studio) need no key.")
                }
                editorField("API Key") {
                    SecureField("", text: $keyDraft)
                        .onChange(of: keyDraft) { _, newValue in
                            store.setKey(newValue, for: provider.id)
                        }
                }
                if !provider.isPreset {
                    pdfPassThroughRow(provider)
                }
            }
            modelRow(for: provider)
            Text("Used when this provider is picked for the first time; after that the pill remembers your last model per provider.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = store.modelFetchErrors[provider.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            capabilityRows(provider)
            if !provider.isPreset {
                Button("Remove Provider…", role: .destructive) {
                    providerPendingDeletion = provider.id
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .top) { Divider().opacity(0.7) }
        .overlay(alignment: .bottom) { Divider().opacity(0.7) }
    }

    /// The template row's slice of the free-APIs guide, stated where the key
    /// gets pasted: where to create one, plus the template's single caveat.
    /// Static facts only — limits and model lists rot, so they stay upstream
    /// (the Add Provider menu links the full catalog).
    private func freeTierNotice(_ template: FreeProviderTemplate) -> some View {
        let caveat = template.note.map { " — \($0)" } ?? ""
        return Text(.init("Free tier · [Get an API key](\(template.keyURL))\(caveat). Paste it below, then fetch the model list with ↻."))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Custom endpoints only: whether PDFs go over the wire as native `file`
    /// content parts. Endpoint-level, not per-model — the question it answers is
    /// "does this proxy forward file parts at all"; per-model refusals are
    /// handled by the exceptions below.
    private func pdfPassThroughRow(_ provider: Provider) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Send PDFs directly")
                    .font(.system(size: 12.5))
                Text("Sends the original PDF as a file content part instead of extracted text. Turn on only if this endpoint accepts file input — many proxies reject or strip it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { store.pdfPassThrough[provider.id] == true },
                set: { store.pdfPassThrough[provider.id] = $0 ? true : nil }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    /// The exception-based half of the capability design: a static one-liner
    /// saying where this provider's answers come from, plus ONLY the models with
    /// recorded deviations — never a table of the whole catalog.
    @ViewBuilder
    private func capabilityRows(_ provider: Provider) -> some View {
        Text(capabilityNotice(provider))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        let exceptions = (store.capabilityExceptions[provider.id] ?? [:]).sorted { $0.key < $1.key }
        if !exceptions.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Attachment exceptions")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(exceptions, id: \.key) { model, exception in
                    HStack(spacing: 6) {
                        Text(model)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(Self.exceptionLabel(exception))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button {
                            store.clearCapabilityException(providerID: provider.id, model: model)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Clear — Mia will try again on the next send")
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func capabilityNotice(_ provider: Provider) -> String {
        switch provider.kind {
        case .chatGPT, .codexAppServer:
            return "Images are sent to the model; PDFs go as extracted text (this route has no file upload)."
        case .openAICompatible:
            if provider.isPreset, provider.baseURL.contains("api.openai.com") {
                return "Images and PDFs are sent to the model directly; one that rejects them shows an explicit error."
            }
            if provider.isPreset, provider.baseURL.contains("openrouter.ai") {
                return "Image and PDF support is detected per model from OpenRouter's catalog."
            }
            if provider.isPreset {
                return "Image support is detected per model from Ollama; PDFs are sent as extracted text."
            }
            return "Images are sent optimistically — a model that rejects them shows an explicit error and is remembered below."
        }
    }

    private static func exceptionLabel(_ exception: CapabilityException) -> String {
        var refusals: [String] = []
        if exception.images == false { refusals.append("no images") }
        if exception.files == false { refusals.append("no direct PDFs") }
        let source = exception.source == .learned ? "recorded" : "manual"
        return "\(refusals.joined(separator: ", ")) · \(source)"
    }

    /// Label left, 230pt field right — the Form's own label/value row can't be
    /// used here because the band sits inside a single full-bleed list row.
    private func editorField<Content: View>(_ label: String, @ViewBuilder _ field: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12.5))
            Spacer(minLength: 8)
            // The width has to be pinned on a CONTAINER, not the control: a
            // grouped Form lays a bare TextField out as its own label/value row
            // and sizes it from the text, ignoring `.frame` on the field itself.
            HStack(spacing: 0) {
                field()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            .frame(width: 230)
            .fixedSize()
        }
    }

    /// Sign-in UI for the ChatGPT provider — replaces the Base URL/API key fields.
    /// Uses your ChatGPT Plus/Pro subscription via the same OAuth flow as Codex CLI.
    @ViewBuilder
    private var chatGPTAuthRows: some View {
        let _ = chatGPTAuthTick // re-evaluate when sign-in state changes
        if ChatGPTAuth.isSignedIn {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Signed in with ChatGPT")
                        let detail = [ChatGPTAuth.accountEmail, ChatGPTAuth.planLabel]
                            .compactMap { $0 }.joined(separator: " · ")
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Sign Out", role: .destructive) {
                    ChatGPTAuth.signOut()
                    chatGPTAuthTick.toggle()
                }
            }
        } else if chatGPTSignInTask != nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for the browser sign-in…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    chatGPTSignInGeneration += 1
                    chatGPTSignInTask?.cancel()
                    chatGPTSignInTask = nil
                }
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Use your ChatGPT subscription")
                    Text("Opens chatgpt.com to authorize. Works with Plus/Pro; usage counts against your plan's limits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sign in with ChatGPT") {
                    chatGPTAuthError = nil
                    chatGPTSignInGeneration += 1
                    let generation = chatGPTSignInGeneration
                    chatGPTSignInTask = Task {
                        do {
                            try await ChatGPTAuth.signIn()
                        } catch is CancellationError {
                            // user cancelled — no error row
                        } catch let error as URLError where error.code == .cancelled {
                            // cancelled during the token-exchange request (URLSession
                            // throws URLError, not CancellationError) — also silent
                        } catch {
                            if generation == chatGPTSignInGeneration {
                                chatGPTAuthError = error.localizedDescription
                            }
                        }
                        // Only the latest attempt owns the shared UI state.
                        guard generation == chatGPTSignInGeneration else { return }
                        chatGPTSignInTask = nil
                        chatGPTAuthTick.toggle()
                        if ChatGPTAuth.isSignedIn {
                            store.applyChatGPTCatalog()
                        }
                    }
                }
            }
        }
        if let error = chatGPTAuthError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
        Label {
            Text("Risk warning: this direct subscription route is unofficial. It calls a ChatGPT/Codex backend that is not documented for third-party apps, so it may stop working and may carry account or terms risk. Prefer the separate Codex app-server provider when possible.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Local Codex bridge. Authentication and installation belong to Codex, not
    /// Mia, so there is deliberately no install or sign-in button here.
    @ViewBuilder
    private var codexAppServerRows: some View {
        editorField("Codex path") {
            HStack(spacing: 6) {
                TextField("Auto-detect", text: $codexExecutablePath)
                    .help("Leave empty to auto-detect (Mia checks common install locations, then asks your login shell), or enter the path `which codex` prints in Terminal.")
                    .onChange(of: codexExecutablePath) { _, _ in
                        // Not just a status reset: this also bumps the generation so a
                        // check already running against the OLD path cannot publish
                        // over this, and clears the once-per-launch auto-fetch flag so
                        // the switcher will actually re-probe the corrected path.
                        store.invalidateCodexAppServer()
                    }
                Button("Locate…") { locateCodexExecutable() }
                    .help("Choose the codex executable — the file `which codex` points at.")
            }
        }
        HStack(spacing: 8) {
            switch store.codexAppServerStatus {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Starting codex app-server and checking the account…")
                    .foregroundStyle(.secondary)
            case .ready(let email, let plan):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                let detail = [email, plan].compactMap { $0 }.joined(separator: " · ")
                Text(detail.isEmpty ? "Signed in with ChatGPT" : detail)
            case .missing:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                // The user's next question is always "then what path do I enter?"
                // — answer it here, where the field is.
                Text("Codex not found — run `which codex` in Terminal and paste the result above, or click Locate…")
                    .lineLimit(3)
            case .notSignedIn:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text("Codex is not signed in with ChatGPT")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(message).lineLimit(2)
            case .unknown:
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                Text("Not checked yet").foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Check Again") {
                Task { await store.refreshCodexAppServer(includeModels: true) }
            }
            .disabled(store.codexAppServerStatus == .checking)
        }
        .font(.caption)

        Label {
            Text("You must install and maintain Codex yourself, then run `codex login` in Terminal. Mia does not install Codex or copy its credentials; it only starts your local `codex app-server` process. The app-server protocol is experimental, so a Codex update may occasionally be required.")
        } icon: {
            Image(systemName: "info.circle.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Text("Chat-only safety: Mia requests ephemeral read-only threads with approval policy Never, and launches Codex with shell/exec, MCP, plugins/connectors, subagents, and other machine tools disabled. Managed Codex policy may override client settings, so app-server remains a local process you should trust and maintain.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Text("Web search: Codex runs its own web search, switched by the globe in the chat input. The engine choice and round cap in Settings → Web Search don't apply to this provider.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// File-picker alternative to typing a path — for the user who has codex
    /// installed somewhere auto-detect missed and doesn't live in a terminal.
    private func locateCodexExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // codex usually lives in a hidden directory (~/.nvm, ~/.local, /usr/local).
        panel.showsHiddenFiles = true
        panel.message = "Select the codex executable (the path `which codex` prints in Terminal)."
        let current = codexExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            // Assigning the binding runs the field's onChange, which invalidates
            // the cached status and re-arms the on-demand check.
            codexExecutablePath = url.path
        }
    }

    // MARK: - Chat

    // Hand-built page, not a Form (providersTab's rationale, which the persona
    // rows re-proved brutally): the grouped Form re-composes custom rows at the
    // AppKit layer — a field kept its box but PAINTED NO TEXT, the trash button
    // grew a "Delete Persona" form label, captions were displaced — while every
    // probe reported the SwiftUI-side geometry as correct. Standard SwiftUI in
    // plain cards renders exactly as written; the card chrome below reproduces
    // the grouped look with the shared page/card colors.
    private var chatTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                chatSection("System Prompt",
                            footer: personaStore.activeID == nil
                                ? "Sent with every conversation. The default teaches the model Mia's pasteable-block format; clear it to send no system prompt."
                                : "A persona is active, so its prompt — not this one — is sent. Switch to Custom above to edit here.",
                            footerHelp: "Content the model wraps in <pasteable title=\"…\"> … </pasteable> tags is rendered as a copyable card in the transcript.") {
                    VStack(alignment: .leading, spacing: 8) {
                        editorWell {
                            TextEditor(text: $systemPromptDraft)
                                .font(.system(size: 12))
                                .scrollContentBackground(.hidden)
                                .frame(height: 148)
                        }
                        Button("Reset to Default") {
                            systemPromptDraft = ChatStore.defaultSystemPrompt
                        }
                        .disabled(systemPromptDraft == ChatStore.defaultSystemPrompt)
                    }
                    .disabled(personaStore.activeID != nil)
                    .onChange(of: systemPromptDraft) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "systemPrompt")
                    }
                }
                chatSection("Personas",
                            footer: "The active persona's prompt is sent with every conversation. Custom uses the free-text system prompt.",
                            footerHelp: "Deleting the active persona switches back to Custom.") {
                    VStack(alignment: .leading, spacing: 10) {
                        chatRow("Active persona") {
                            Picker("Active persona", selection: $personaStore.activeID) {
                                Text("Custom").tag(String?.none)
                                ForEach(personaStore.personas) { persona in
                                    Text(persona.name).tag(String?.some(persona.id.uuidString))
                                }
                            }
                            .labelsHidden()
                            // Menu popups stretch to the proposed width;
                            // fixedSize wraps the selected value like the
                            // Providers model menu, leaving the row's trailing
                            // placement (chatRow) untouched.
                            .fixedSize()
                        }
                        ForEach(Array($personaStore.personas.enumerated()), id: \.element.id) { offset, $persona in
                            // Hairline between rows only — not after the last one.
                            if offset > 0 {
                                Divider()
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    fieldCaption("Name")
                                    TextField("", text: $persona.name)
                                        .textFieldStyle(.plain)
                                        .multilineTextAlignment(.leading)
                                        .font(.system(size: 13, weight: .medium))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(
                                            Color.primary.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                                        )
                                        .frame(width: 140)
                                    Spacer(minLength: 8)
                                    Button(role: .destructive) {
                                        personaStore.remove(id: persona.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24, height: 24)
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete persona")
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    fieldCaption("Prompt")
                                    editorWell {
                                        TextEditor(text: $persona.prompt)
                                            .font(.system(size: 12))
                                            .scrollContentBackground(.hidden)
                                            .frame(height: 56)
                                            .overlay(alignment: .topLeading) {
                                                if persona.prompt.isEmpty {
                                                    Text("System prompt this persona sends")
                                                        .font(.system(size: 12))
                                                        .foregroundStyle(.tertiary)
                                                        .padding(.leading, 5)
                                                        .allowsHitTesting(false)
                                                }
                                            }
                                    }
                                }
                            }
                        }
                        Button("Add Persona…") {
                            personaStore.add()
                        }
                    }
                }
                chatSection("Slash Commands",
                            footer: "Type “/name your text” in the chat field.",
                            footerHelp: "The compact form is shown in the transcript; the expanded template is what the model receives.") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array($shortcutStore.shortcuts.enumerated()), id: \.element.id) { offset, $shortcut in
                            // Same hairline rhythm as the persona rows.
                            if offset > 0 {
                                Divider()
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    fieldCaption("Name")
                                    Text("/")
                                        .foregroundStyle(.secondary)
                                    TextField("", text: $shortcut.name)
                                        .textFieldStyle(.plain)
                                        .multilineTextAlignment(.leading)
                                        .font(.system(size: 13, weight: .medium))
                                        .focused($focusedCommandName, equals: shortcut.id)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(
                                            Color.primary.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                                        )
                                        .frame(width: 140)
                                    Spacer(minLength: 8)
                                    Button(role: .destructive) {
                                        shortcutStore.remove(id: shortcut.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24, height: 24)
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete command")
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    fieldCaption("Template")
                                    editorWell {
                                        TextEditor(text: $shortcut.template)
                                            .font(.system(size: 12))
                                            .scrollContentBackground(.hidden)
                                            .frame(height: 56)
                                            .overlay(alignment: .topLeading) {
                                                if shortcut.template.isEmpty {
                                                    Text("Prompt template — {input} marks where your text goes")
                                                        .font(.system(size: 12))
                                                        .foregroundStyle(.tertiary)
                                                        .padding(.leading, 5)
                                                        .allowsHitTesting(false)
                                                }
                                            }
                                    }
                                }
                            }
                        }
                        Button("Add Command…") {
                            shortcutStore.add()
                            // Focus lands after the new row exists in the hierarchy.
                            let newID = shortcutStore.shortcuts.last?.id
                            DispatchQueue.main.async { focusedCommandName = newID }
                        }
                    }
                }
                chatSection("Titles",
                            footer: "After a reply lands, the current provider is asked once for a short title (≤24 tokens). Failures are silent; OpenAI-compatible providers only.",
                            footerHelp: "The title replaces the truncated first message in history once the first reply completes. A conversation is asked at most once.") {
                    chatRow("Auto-name new chats") {
                        Toggle("Auto-name new chats", isOn: $autoTitleEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            // Form switches render at the compact ~15pt size
                            // (General measured 30px@2x); a plain-context switch
                            // defaults to regular (25pt tall) — mini matches.
                            .controlSize(.mini)
                    }
                }
                chatSection("Selection",
                            footer: "Select text in any app and a small Mia button appears below it — click to quote the selection into the panel. Needs Accessibility access.",
                            footerHelp: "The button borrows the clipboard for a momentary ⌘C in the source app and restores it. Keyboard-only selections are not detected; the Services menu (P2) covers those.") {
                    VStack(alignment: .leading, spacing: 10) {
                        chatRow("Show selection button") {
                            Toggle("Show selection button", isOn: $selectionButtonEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.mini)
                        }
                        chatRow("Send selection immediately") {
                            Toggle("Send selection immediately", isOn: $selectionSendImmediately)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.mini)
                                .disabled(!selectionButtonEnabled)
                        }
                        if axTrusted {
                            Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Text("The selection button needs Accessibility access.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Grant Access…") {
                                    // Deep link into the Accessibility pane; the
                                    // user drops Mia onto the list themselves
                                    // (that drag cannot be automated by design).
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                        }
                    }
                }
                chatSection("Web Search",
                            footer: "The model decides when to search (max 5 tool rounds).",
                            footerHelp: "web_search + fetch_url tools. Provider-native uses OpenRouter's server-side plugin and only applies when OpenRouter is the active provider; other choices fall back to DuckDuckGo with a visible notice.") {
                    VStack(alignment: .leading, spacing: 10) {
                        chatRow("Web access available to the model") {
                            Toggle("Web access available to the model", isOn: $webEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.mini)
                        }
                        chatRow("Search engine") {
                            Picker("Search engine", selection: $searchEngine) {
                                ForEach(SearchEngineChoice.allCases) { choice in
                                    Text(choice.label).tag(choice.rawValue)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        if let account = SearchEngineChoice(rawValue: searchEngine)?.apiKeyAccount {
                            SecureField("Search API Key", text: $searchKeyDraft)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: searchKeyDraft) { _, newValue in
                                    SecretStore.set(newValue, account: account)
                                }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .background(formPageBackground)
        .onAppear { axTrusted = AXIsProcessTrusted() }
        // The distributed broadcast above is not posted on every macOS version
        // (this machine grants AX without it — verified: the button works while
        // the row still says "Grant Access…"). The reliable complement: re-read
        // trust whenever the app becomes active again, which is precisely when
        // the user returns from System Settings after flipping the toggle.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            axTrusted = AXIsProcessTrusted()
        }
        // Granting or revoking happens in System Settings — another app — so
        // nothing local invalidates our copy. This is the system's broadcast
        // that trust changed, landing exactly while the user is looking at
        // the row that reports it.
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name("com.apple.accessibility.api")
        )) { _ in
            axTrusted = AXIsProcessTrusted()
        }
    }

    /// One grouped-card section of the hand-built Chat page: header, card,
    /// footer — the same chrome rhythm the grouped Form gives the other tabs.
    private func chatSection<Content: View>(
        _ title: String, footer: String, footerHelp: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(title)
                .padding(.leading, 10)
            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    formCardBackground,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            sectionFooter(footer)
                .help(footerHelp)
                .padding(.leading, 10)
        }
    }

    /// One settings row of the hand-built Chat page: label leading, control
    /// hugging the card's trailing edge — the geometry the grouped Form gives
    /// the other tabs (accentRow/panelTintRow are the in-file precedents).
    /// The control keeps its native size; only its position is pinned.
    private func chatRow<Content: View>(
        _ label: String, @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer(minLength: 12)
            control()
        }
    }

    /// Quaternary well the fixed-height prompt editors sit in.
    private func editorWell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }

    // MARK: - About

    /// Centered identity block (Apple-About style) on the same page background
    /// as the other tabs. Credits sit under the description in small centered
    /// type — deliberately NOT the ⓘ footer style used by the other tabs, which
    /// reads as "settings fine print" rather than an about page.
    /// The bundle icon comes from AppIcon.icns; the bare-binary harness falls
    /// back to the generic app icon.
    private var aboutTab: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 48)
            VStack(spacing: 10) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text("Mia")
                    .font(.system(size: 20, weight: .semibold))
                Text("A mini AI chat app for quick, small (and usually temporary) chats.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30)
            }
            VStack(spacing: 4) {
                // Attribution is a courtesy AND the MIT obligation made visible:
                // this app is a renamed continuation of someone else's project.
                Link("Based on PopChat by Le Chen · MIT", destination: URL(string: "https://github.com/lec77/PopChat")!)
                Text("Copyright © 2026 Le Chen & David · Version \(UpdateChecker.currentVersion)")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 30)
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(formPageBackground)
    }

    // MARK: - Helpers

    /// Section caption shared by every tab — the Providers page's title style,
    /// promoted to the whole window.
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(.secondary)
    }

    /// Tiny uppercase label for the persona/command rows' editable areas —
    /// inline beside the single-line name field, above the multi-line editor
    /// well. The shared vocabulary that makes the boxed name field and the
    /// editor well read as labeled inputs, not stray static text.
    private func fieldCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(.secondary)
    }

    /// Section footnote shared by every tab: left-aligned, with a small info
    /// glyph by the text. The 8pt symbol still carries ~1pt of side bearing,
    /// so spacing 3 lands the visual gap at 4pt.
    private func sectionFooter(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "info.circle")
                .font(.system(size: 8))
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Default model for the EDITED provider — never the selected one. Settings
    /// no longer has a selection to piggyback on (delta 5).
    private func modelRow(for provider: Provider) -> some View {
        let id = provider.id
        let models = store.knownModels[id] ?? []
        return editorField("Default model") {
            HStack(spacing: 6) {
                TextField("", text: Binding(
                    get: { store.rememberedModel(id) },
                    set: { store.setModel($0, for: id) }
                ))
                Menu {
                    ForEach(models, id: \.self) { model in
                        Button(model) { store.setModel(model, for: id) }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden) // the label IS the indicator
                .fixedSize()
                .disabled(models.isEmpty)
                .help(models.isEmpty ? "Fetch the model list first" : "Pick from fetched models")
                Button {
                    Task { await store.fetchModels(for: id) }
                } label: {
                    if store.isFetching(id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .fixedSize()
                .help("Fetch model list from the provider")
            }
        }
    }

    private func currentSearchKey() -> String {
        guard let account = SearchEngineChoice(rawValue: searchEngine)?.apiKeyAccount else { return "" }
        return SecretStore.get(account: account) ?? ""
    }
}
