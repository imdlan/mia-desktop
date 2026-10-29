import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let miaOpenSettings = Notification.Name("MiaOpenSettings")
    /// Posted by FloatingPanel when ⌘V carries files/an image to attach.
    static let miaAttachPasteboard = Notification.Name("MiaAttachPasteboard")
    /// Posted by the Services handler (AppDelegate.askWithSelection) with the
    /// quoted selection as the object, for the composer to append.
    static let miaQuoteSelection = Notification.Name("MiaQuoteSelection")
}

/// The "Glass" panel: translucent rounded shell, header chrome as overlay pills
/// the transcript scrolls under, and a floating capsule input at the bottom.
///
/// Performance shape (do not regress): typing state lives entirely inside
/// ComposerView, so keystrokes never invalidate the transcript; transcript rows
/// are Equatable-gated so streaming ticks re-render only the active row.
struct ChatView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: ChatStore
    @ObservedObject var providerStore: ProviderStore
    @ObservedObject var shortcutStore: ShortcutStore
    var onClose: () -> Void
    /// Reports the natural content height while the chat is empty, so the panel
    /// can shrink to just chrome + input.
    var onCompactHeightChange: (CGFloat) -> Void = { _ in }

    @State private var composerModel = ComposerModel()
    @State private var draftEditorShown = false
    @State private var dropTargeted = false
    @State private var historyShown = false
    @State private var modelPillHovered = false
    /// 7c switcher popover — the pill shows a pressed state while it's open.
    @State private var switcherShown = false
    @State private var actionPillHovered = false
    @State private var transcriptWidth: CGFloat = 680
    /// Width of the header pills row — the model pill caps at 46% of it (4a).
    @State private var headerWidth: CGFloat = 680
    /// Streaming follows the bottom only while the user is there; an upward
    /// scroll disengages so streaming never yanks the view.
    @State private var pinnedToBottom = true
    @State private var showNewMessagesPill = false
    // ⌘F find-in-chat. Hits are counted over DISPLAYED text and painted in
    // place (Find.swift); the transcript scrolls to the matched characters, not
    // to the message. Only rows that contain a hit get a MessageFind, so every
    // other row stays Equatable-gated while the query is typed, and highlights
    // add only .backgroundColor — never a re-measure (see SelectableText).
    @State private var findShown = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    @State private var findFocusBump = 0
    /// 5d: a restored conversation arrives as ONE group once the panel has begun
    /// growing — no per-row stagger, this is a restore, not new content. False
    /// only for the frame or two between the restore and its reveal.
    @State private var transcriptRevealed = true
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { Theme.color(accentHex) }

    var body: some View {
        VStack(spacing: 0) {
            mainContent
            if store.messages.isEmpty, !draftEditorShown {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { PanelGlassBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.panelBorder(dark: scheme == .dark), lineWidth: 0.5)
        )
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(accent, lineWidth: 3)
                    .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        // No SwiftUI min frame here: the window enforces minimums (PanelController
        // windowWillResize). A root larger than the window would render CENTERED
        // in it, clipping the pills and composer off the top/bottom edges.
        // AppKit drop target, NOT `.dropDestination(for: URL.self)`: the
        // screenshot thumbnail's drag carries a file PROMISE, no URL — see
        // PanelDrop.swift. Guarded by --smoke-drop.
        .background { PanelDropCatcher(targeted: $dropTargeted, model: composerModel) }
        .onExitCommand { onClose() }
        // While the history popover is key, ITS ⌘F wins (popovers get their own
        // window), which is what "⌘F in history searches the histories" means.
        .keyCommand("f") { toggleFind() }
        .onChange(of: draftEditorShown) { _, shown in
            // The editor needs real height even when the chat is empty; the
            // compact preference resumes reporting when the editor closes.
            if store.messages.isEmpty, shown {
                onCompactHeightChange(440)
            }
        }
        // Lives on the root, not in transcriptZone: restoring into an EMPTY panel
        // builds that subtree fresh, and .onChange never fires on first appearance.
        .onChange(of: store.restoreTick) { _, _ in revealRestoredTranscript() }
    }

    /// Hide, let one layout pass land (that's where the transcript pre-scrolls to
    /// the bottom), then bring it in as a group ~60ms into the panel's growth so
    /// text never pops in mid-resize.
    private func revealRestoredTranscript() {
        let intoEmptyPanel = store.restoredIntoEmptyPanel
        transcriptRevealed = false
        let delay = reduceMotion || !intoEmptyPanel ? 0.016 : 0.06
        let reveal = reduceMotion || !intoEmptyPanel ? 0.15 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.easeOut(duration: reveal)) { transcriptRevealed = true }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if store.isLoadingConversation {
                // A history pick decodes detached (see ChatStore.loadConversation),
                // and the panel must say the pick was received rather than idle on
                // the outgoing transcript: the pills stay (drag strip + identity),
                // the transcript area becomes the loading placeholder until the
                // adopt lands. The animation below crossfades the swap both ways —
                // the outgoing chat dims out under the dots, and the dots dim out
                // under the restored transcript's own reveal.
                pillsRow
                    .padding(12)
                    .background(WindowDragStrip())
                    .transition(.opacity)
                ChatLoadingIndicator()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else if store.messages.isEmpty || draftEditorShown {
                // The ⌘E editor keeps the header pills visible (4d); only the
                // transcript hides while it's open.
                pillsRow
                    .padding(12)
                    .background(WindowDragStrip())
                    .transition(.opacity)
            } else {
                transcriptZone
                    .transition(.opacity)
            }
            ComposerView(
                model: composerModel,
                providerStore: providerStore,
                shortcutStore: shortcutStore,
                isStreaming: store.isStreaming,
                steerQueued: store.steerPendingText,
                onSteerInsert: { store.insertSteer() },
                onSteerDiscard: { store.discardSteer() },
                onQueue: { text, attachments in store.queueSteer(text, attachments: attachments) },
                focusBump: state.focusBump,
                editorMode: $draftEditorShown,
                onSend: { text, attachments in store.send(text, attachments: attachments) },
                onStop: { store.stop() },
                onFocusRequest: { state.focusBump += 1 },
                onClose: onClose
            )
        }
        // Scoped to the loading flag alone: nothing else this subtree renders
        // (message ticks, pill hovers) inherits this animation.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: store.isLoadingConversation)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { height in
            if store.messages.isEmpty, !draftEditorShown {
                onCompactHeightChange(height)
            }
        }
    }

    // MARK: - Header pills

    // Model pill caps at 46% of the row and truncates the id; the action
    // cluster is fixedSize — it never compresses (4a).
    private var pillsRow: some View {
        HStack(spacing: 10) {
            modelPill
            Spacer(minLength: 0)
            actionPill
                .fixedSize()
        }
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: HeaderWidthKey.self, value: geometry.size.width)
            }
        )
        .onPreferenceChange(HeaderWidthKey.self) { headerWidth = $0 }
    }

    // Delta 5 (7c): a cascading provider→model→effort popover, not a Menu.
    // Effort appears only for models with explicit capability metadata; browsing
    // any lane must not switch what the next message uses until a row commits.
    private var modelPill: some View {
        Button {
            switcherShown.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(switcherLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .layoutPriority(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            // Whole pill is clickable — plain-style controls only hit-test
            // opaque pixels without an explicit content shape.
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Switch provider & model — applies to your next message")
        .fixedSize(horizontal: false, vertical: true)
        .pillBackground(hovered: modelPillHovered, pressed: switcherShown)
        .onHover { modelPillHovered = $0 }
        .popover(isPresented: $switcherShown, arrowEdge: .bottom) {
            ProviderSwitcher(store: providerStore)
        }
        // Invisible cap: the visible pill hugs its content, but never exceeds
        // 46% of the header row (the label truncates instead).
        .frame(maxWidth: max(headerWidth * 0.46, 140), alignment: .leading)
    }

    // Icon grid (4b): 14pt symbols in fixed 20×20 slots, 8pt gap, 4×8 padding
    // ≙ 28pt capsule height; active states are plain circular fills over the
    // slot — no negative margins.
    private var actionPill: some View {
        HStack(spacing: 8) {
            Button {
                historyShown.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14))
                    .frame(width: 20, height: 20)
                    .background(historyShown ? Color.primary.opacity(0.14) : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("y", modifiers: .command)
            .help("Recent chats (⌘Y)")
            .popover(isPresented: $historyShown, arrowEdge: .bottom) {
                HistoryPopover(store: store)
            }
            Button {
                store.newChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14))
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help("New chat (⌘N)")
            Button {
                state.pinned.toggle()
            } label: {
                Image(systemName: state.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 14))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 20, height: 20)
                    .background(state.pinned ? Color.primary.opacity(0.14) : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("p", modifiers: .command)
            .help(state.pinned ? "Unpin — hide when clicking away (⌘P)" : "Keep on top (⌘P)")
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.pinned)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .pillBackground(hovered: actionPillHovered)
        .onHover { actionPillHovered = $0 }
    }

    private var switcherLabel: String {
        // A fresh install has a selection (selectedID is non-optional) but no
        // configured provider — naming one here reads as "ready to chat" and the
        // user only learns otherwise from an error after typing. Say what the
        // next step actually is; the click lands in the switcher, whose footer
        // opens Settings › Providers. hasSetupEvidence, NOT isConfigured: a
        // transient failed Codex check must not rename a set-up provider mid-
        // conversation. (Cheap per render: secrets and tokens are memory-cached,
        // the rest are dictionary lookups.)
        guard let provider = providerStore.selectedProvider,
              providerStore.hasSetupEvidence(provider) else { return "Set up a provider…" }
        let model = providerStore.currentModel
        let effort = providerStore.currentReasoningEffort.map { " · \($0)" } ?? ""
        return "\(provider.name) · \(model.isEmpty ? "no model" : model)\(effort)"
    }

    // MARK: - Transcript

    private var transcriptZone: some View {
        let streamingID = store.isStreaming ? store.messages.last(where: { $0.role == .assistant })?.id : nil
        let revealingID: UUID? = store.reveal?.messageID
        let revealFade: TextReveal? = store.reveal?.fade
        let bubbleMaxWidth = max(220, (transcriptWidth - 32) * 0.78)
        let hits = findShown ? findHits : []
        let activeHit = hits.indices.contains(findIndex) ? hits[findIndex] : nil
        let matchedIDs = Set(hits.map(\.messageID))
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // The question timeline's markers: one per user turn, in order.
        let timelineQuestions = store.messages.filter { $0.role == .user }
        // Retry / Edit prompt ride the last row that can host them (same
        // one-row gating trick as `find`): they re-run the last turn, so the end
        // of the transcript is both where they apply and where the eye already
        // is. Trailing activity rows are skipped — a turn whose reply came back
        // EMPTY has its row removed by the streamTask tail, which can leave a
        // gray "searched the web" line last, and that is precisely the moment
        // the user needs Retry.
        let rerunID: UUID? = store.canRerunLastTurn
            ? store.messages.last(where: { $0.role != .activity })?.id
            : nil
        return ScrollViewReader { proxy in
            trackingBottomPin(
                ScrollView {
                    // Plain VStack, deliberately: LazyVStack re-estimates row heights as
                    // items load during scrolling, and with variable-height text rows the
                    // fluctuating content height fights NSScrollView's position
                    // adjustments — an infinite re-layout loop that froze the app.
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.messages) { message in
                            // Hoisted out of the initializer: inline ternaries here
                            // tipped the type-checker over its time limit.
                            let id: UUID = message.id
                            let revealing: Bool = id == revealingID
                            // Nil for messages with no hit, so every other row
                            // stays Equatable-gated while typing.
                            let rowFind: MessageFind? = matchedIDs.contains(id)
                                ? MessageFind(
                                    query: query,
                                    activeOccurrence: activeHit?.messageID == id ? activeHit?.occurrence : nil
                                )
                                : nil
                            // Nil for every row but the still-empty streaming one
                            // (same gating trick as `find`), so status updates
                            // repaint exactly one row.
                            let waiting: String? = id == streamingID && message.text.isEmpty
                                ? (store.pendingStatus ?? "Thinking…")
                                : nil
                            // Nil for every row but that same one, so the
                            // thinking arriving at wire rate repaints exactly
                            // one row (the `find` gating trick again).
                            let waitingReasoning: String? = waiting == nil
                                ? nil
                                : store.pendingReasoning
                            // Nil for every row but the one unattributed-failure
                            // error row (same gating trick again).
                            let capabilityAction: MessageRow.CapabilityAction? =
                                store.capabilityFailure?.errorMessageID == id
                                    ? store.capabilityFailure.map {
                                        MessageRow.CapabilityAction(
                                            model: $0.model, images: $0.sentImages, files: $0.sentFiles
                                        )
                                    }
                                    : nil
                            MessageRow(
                                message: message,
                                rerunnable: id == rerunID,
                                // The caret rides the fade head (Delta 4), so it
                                // outlives the NETWORK turn that streamingID
                                // tracks — the reveal can still be typing.
                                showCaret: id == streamingID || revealing,
                                bubbleMaxWidth: bubbleMaxWidth,
                                find: rowFind,
                                reveal: revealing ? revealFade : nil,
                                waitingStatus: waiting,
                                waitingReasoning: waitingReasoning,
                                capabilityAction: capabilityAction,
                                onFork: { store.fork(at: id) },
                                onExport: { exportReply(id) },
                                onRetry: { store.retryLastTurn() },
                                onEditPrompt: editLastPrompt,
                                fullText: { store.fullText(of: id) },
                                onRecordException: { store.recordManualCapabilityException($0) }
                            )
                            .equatable()
                            .transition(rowTransition(for: message.role))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.top, 56)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    // 5d: the restore reveal. Opacity/offset on the group only —
                    // it cannot change any row's metrics, so nothing re-measures.
                    .opacity(transcriptRevealed ? 1 : 0)
                    .offset(y: transcriptRevealed || reduceMotion ? 0 : 8)
                }
            )
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: TranscriptWidthKey.self, value: geometry.size.width)
                }
            )
            .onPreferenceChange(TranscriptWidthKey.self) { transcriptWidth = $0 }
            .mask(topFade)
            // Thinking-phase follow: the text/count onChanges below can't see
            // the waiting indicator's height jumps (text stays "", count stays
            // put) nor the send-moment compact→full container animation.
            .followingWaitingGrowth(
                proxy,
                pinned: $pinnedToBottom,
                pendingStatus: store.pendingStatus,
                pendingReasoning: store.pendingReasoning
            )
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    pillsRow
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        // The bar tucks up under the pills (5a): the row's bottom
                        // inset drops to 4 while it's open.
                        .padding(.bottom, findShown ? 4 : 12)
                        .background(WindowDragStrip())
                    if findShown {
                        findBar(matchCount: hits.count)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                            .transition(.opacity)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: findShown)
            // Recompute from state rather than closing over `currentMatch`: the
            // captured value belongs to the body evaluation that installed the
            // closure, which is not guaranteed to be the post-change one.
            .onChange(of: findIndex) { _, index in
                let hits = findHits
                scrollToMatch(hits.indices.contains(index) ? hits[index] : nil, proxy)
            }
            .onChange(of: findQuery) { _, _ in
                findIndex = 0
                scrollToMatch(findHits.first, proxy)
            }
            .overlay(alignment: .bottom) {
                if showNewMessagesPill {
                    newMessagesPill(proxy)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .trailing) {
                // Question timeline (TranscriptTimeline.swift): bars hover and
                // jump via the same proxy the find bar scrolls with. The
                // trailing alignment centers the column vertically, clear of
                // the pills row above and the composer below.
                if timelineQuestions.count > 1 {
                    TranscriptTimeline(questions: timelineQuestions) { id in
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    // Matches the composer's 12pt trailing margin.
                    .padding(.trailing, 12)
                }
            }
            .animation(.easeOut(duration: 0.15), value: showNewMessagesPill)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.18), value: store.messages.count)
            // Text ticks arrive many times per second while streaming: the
            // follow-scroll must NOT be animated, or each tick restarts an
            // animation and layout never goes idle (this froze the app).
            // Animate only on new rows.
            .onChange(of: store.messages.last?.text) { _, _ in
                if pinnedToBottom {
                    proxy.scrollTo("bottom", anchor: .bottom)
                } else {
                    showNewMessagesPill = true
                }
            }
            .onChange(of: store.messages.count) { old, new in
                // A USER message being appended IS a send — the author's own
                // action. Whatever the pin's current state (disengaged by an
                // upward read, a ⌘F jump, a timeline jump), sending must
                // re-engage following: otherwise the new bubble lands below the
                // viewport, half-hidden behind the composer, and neither this
                // gate nor the text-tick one follows the reply (the reported
                // "bubble covered by the input" regression).
                //
                // Diff the APPENDED SLICE, not `last?.role`: send() appends the
                // user row AND the empty assistant placeholder in one
                // synchronous turn, so this onChange fires once with count +2
                // and an ASSISTANT row last — the old `last?.role == .user`
                // test never fired on the normal send path (why the regression
                // survived its first fix). preflight appends the user row on
                // every send shape (send, retry, idle-steer, mid-stream steer).
                if new > old, old < store.messages.count,
                   store.messages[old...].contains(where: { $0.role == .user }) {
                    pinnedToBottom = true
                    // A send's first scrollTo races the row-insert
                    // transitions and the panel's own animations; one call
                    // can stop short with nothing left to re-fire it
                    // (contentSize doesn't change again, so the geometry
                    // follower stays silent). Re-assert the pin over the
                    // next few ticks — each is a no-op once actually at the
                    // bottom, and none run while the user reads upward (the
                    // send just re-engaged the pin).
                    Task { @MainActor in
                        for _ in 0..<3 {
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                if pinnedToBottom {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                } else {
                    showNewMessagesPill = true
                }
            }
            .onChange(of: pinnedToBottom) { _, pinned in
                if pinned { showNewMessagesPill = false }
            }
            // Pre-scroll a restored transcript to the bottom while it is still
            // invisible, so the reveal shows the end of the conversation with no
            // visible scroll jump (5d). onAppear covers the empty→loaded case
            // (this subtree is new); onChange covers replacing an open chat.
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.restoreTick) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Pull the last question back into the composer to reword and send again.
    /// The transcript loses that turn immediately (Retry's twin), so the panel
    /// never shows a question the next send is about to replace.
    private func editLastPrompt() {
        guard let taken = store.takeLastUserMessageForEditing() else { return }
        composerModel.pendingAttachments = taken.attachments
        composerModel.injectedDraft = taken.text
    }

    /// One assistant reply to a Markdown file the user names (HistoryPopover's
    /// `export` flow). Text resolves at click time — same semantics as Copy:
    /// the typewriter may still be revealing the row, but the export promises
    /// the whole response. Silent on success AND failure: ChatView has no
    /// export-note surface, and a missing file is its own feedback.
    private func exportReply(_ id: UUID) {
        guard let message = store.messages.first(where: { $0.id == id }),
              message.role == .assistant else { return }
        // The stored file carries the auto title; before the first persist
        // (mid-turn export) fall back to the same derivation persist() uses.
        let title = ConversationStore.load(id: store.conversationID)?.title
            ?? ChatStore.title(for: store.messages)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = ConversationExport.replyFilenameBase(
            conversationTitle: title, messageID: id
        ) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(
            ConversationExport.replyMarkdown(
                text: store.fullText(of: id),
                reasoning: message.reasoning,
                conversationTitle: title
            ).utf8
        ).write(to: url, options: [.atomic])
    }

    // MARK: - Find in chat (⌘F)

    /// Every occurrence in the transcript, in reading order. Counted over
    /// DISPLAYED text (markdown syntax stripped, code/table content as rendered)
    /// so hit N is exactly the range the transcript paints as active.
    private var findHits: [FindHit] {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var hits: [FindHit] = []
        for message in store.messages {
            let count = MarkdownRenderer.searchableStrings(for: message)
                .reduce(0) { $0 + FindHighlight.count(in: $1, query: query) }
            for occurrence in 0..<count {
                hits.append(FindHit(messageID: message.id, occurrence: occurrence))
            }
        }
        return hits
    }

    private func toggleFind() {
        if findShown {
            closeFind()
        } else {
            guard !store.messages.isEmpty else { return } // nothing to search
            findShown = true
            findIndex = 0
            findFocusBump += 1
        }
    }

    private func closeFind() {
        findShown = false
        findQuery = ""
        findIndex = 0
        state.focusBump += 1 // hand the caret back to the composer
    }

    private func stepMatch(_ delta: Int) {
        let count = findHits.count
        guard count > 0 else { return }
        findIndex = ((findIndex + delta) % count + count) % count // wraps both ways
    }

    /// Coarse fallback only. Rows that render real text views scroll themselves
    /// to the matched characters (`SelectableText.reveal`) — scrolling to the
    /// message here as well would fight that with a second, less precise jump.
    private func scrollToMatch(_ hit: FindHit?, _ proxy: ScrollViewProxy) {
        guard let hit,
              let message = store.messages.first(where: { $0.id == hit.messageID }),
              message.role == .activity || message.role == .error else { return }
        proxy.scrollTo(hit.messageID, anchor: .center)
    }

    private func findBar(matchCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            KeyRoutingTextField(
                text: $findQuery,
                placeholder: "Find in chat",
                focusBump: findFocusBump,
                onMoveUp: {
                    stepMatch(-1)
                    return true
                },
                onMoveDown: {
                    stepMatch(1)
                    return true
                },
                onReturn: { shift in
                    stepMatch(shift ? -1 : 1)
                    return true
                },
                onEscape: {
                    closeFind()
                    return true
                }
            )
            .frame(height: 16)
            Text(matchLabel(matchCount))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
            findStepButton("chevron.up", modifiers: [.command, .shift], enabled: matchCount > 0) { stepMatch(-1) }
            findStepButton("chevron.down", modifiers: .command, enabled: matchCount > 0) { stepMatch(1) }
            Button(action: closeFind) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            // Dimmer than the steppers (5a): stepping is the bar's job, ✕ isn't.
            .foregroundStyle(.secondary.opacity(0.78))
            .help("Close find (⎋)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .pillBackground()
    }

    private func matchLabel(_ count: Int) -> String {
        if findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        guard count > 0 else { return "No matches" }
        return "\(min(findIndex + 1, count)) of \(count)"
    }

    private func findStepButton(
        _ symbol: String,
        modifiers: EventModifiers,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .keyboardShortcut("g", modifiers: modifiers)
        .help(symbol == "chevron.up" ? "Previous match (⇧⌘G)" : "Next match (⌘G)")
    }

    /// Transcript scrolls under the pills; the top 44pt fades out beneath them.
    private var topFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 44)
            Color.black
        }
    }

    private func rowTransition(for role: ChatRole) -> AnyTransition {
        guard !reduceMotion, role == .user else { return .opacity }
        return .opacity.combined(with: .move(edge: .bottom))
    }

    /// Disengage following only on an actual upward scroll (offset decrease) —
    /// content growth also increases the bottom distance, and reacting to that
    /// would break following on every big streamed chunk. Re-engage within 40pt
    /// of the bottom. State writes happen only on transitions.
    @ViewBuilder
    private func trackingBottomPin(_ content: some View) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: ScrollPin.self, of: { geometry in
                ScrollPin(
                    offset: geometry.contentOffset.y.rounded(),
                    bottomDistance: (geometry.contentSize.height - geometry.containerSize.height - geometry.contentOffset.y).rounded()
                )
            }, action: { old, new in
                if new.bottomDistance <= 40 {
                    if !pinnedToBottom { pinnedToBottom = true }
                } else if new.offset < old.offset - 4 {
                    if pinnedToBottom { pinnedToBottom = false }
                }
            })
        } else {
            content // macOS 14: always follow (previous behavior)
        }
    }

    private func newMessagesPill(_ proxy: ScrollViewProxy) -> some View {
        let dark = scheme == .dark
        return Button {
            showNewMessagesPill = false
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                Text("New messages")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(dark ? Theme.color("#f5f5f7") : Theme.color("#1d1d1f"))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 13)
            .background(
                dark ? Theme.color("#2C2C30").opacity(0.95) : Theme.color("#FCFCFE").opacity(0.97),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(
                dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10),
                lineWidth: 0.5
            ))
            .shadow(
                color: dark ? .black.opacity(0.4) : Theme.color("#282850").opacity(0.18),
                radius: 12, y: 8
            )
        }
        .buttonStyle(.plain)
    }

    private struct ScrollPin: Equatable {
        var offset: CGFloat
        var bottomDistance: CGFloat
    }
}

/// Layout identity for the growth-following scroll: heights only, rounded so
/// sub-pixel layout jitter never spins the action.
private struct GrowthPin: Equatable {
    var contentHeight: CGFloat
    var containerHeight: CGFloat
}

private extension View {
    /// Keeps the transcript pinned through layout GROWTH that the text/count
    /// onChanges cannot see: while the reply is still empty, its text stays ""
    /// and the row count stays put, yet the waiting indicator's height jumps
    /// (status line → 3-line reasoning window → timer) and the send-moment
    /// compact→full panel animation re-sizes the container mid-scrollTo.
    ///
    /// Iron rule: this follow-scroll must NEVER be animated — every streaming
    /// tick would restart the animation and layout would never go idle (this
    /// froze the app; see the text onChange in transcriptZone). Scrolling
    /// itself changes neither content nor container size, so this fires on
    /// layout growth only and never yanks an upward read: `pinned` gates it.
    @ViewBuilder
    func followingWaitingGrowth(
        _ proxy: ScrollViewProxy,
        pinned: Binding<Bool>,
        pendingStatus: String?,
        pendingReasoning: String?
    ) -> some View {
        if #available(macOS 15.0, *) {
            onScrollGeometryChange(for: GrowthPin.self, of: { geometry in
                GrowthPin(
                    contentHeight: geometry.contentSize.height.rounded(),
                    containerHeight: geometry.containerSize.height.rounded()
                )
            }, action: { _, _ in
                if pinned.wrappedValue {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            })
        } else {
            // macOS 14: no geometry hook; the indicator's driving @Published
            // values stand in for its height changes (this branch always
            // follows anyway — trackingBottomPin pins nothing below 15).
            onChange(of: pendingStatus) { _, _ in
                if pinned.wrappedValue { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: pendingReasoning) { _, _ in
                if pinned.wrappedValue { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TranscriptWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 680
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HeaderWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 680
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Equatable so unchanged rows skip body re-evaluation entirely during
/// streaming ticks and keystrokes — no markdown segmentation, no
/// attributed-string rebuilds, no measurement.
private struct MessageRow: View, Equatable {
    let message: ChatMessage
    /// True for the LAST row only, and only while the last turn can be re-run:
    /// it carries Retry / Edit prompt. Part of == like `find`, so the rest of
    /// the transcript stays gated when a turn ends.
    var rerunnable = false
    let showCaret: Bool
    let bubbleMaxWidth: CGFloat
    /// Nil unless this message contains a ⌘F hit. Part of ==, so a row repaints
    /// when its own highlights change and stays gated otherwise.
    var find: MessageFind?
    /// Delta 4 streaming fade. Also part of ==: the fade advances on ticks where
    /// `message.text` does NOT change (running out after the last commit), and
    /// without this the row would stay gated and the head would never settle.
    var reveal: TextReveal?
    /// Non-nil only for the streaming row while it has NO text yet: the label the
    /// waiting indicator pulses ("Thinking…", or the provider's latest `.status`).
    /// Part of == so a status change repaints exactly this row.
    var waitingStatus: String?
    /// Non-nil only for that same row once thinking has arrived: the text the
    /// waiting indicator scrolls. Part of == so it repaints only this row.
    var waitingReasoning: String?
    /// Non-nil only for the error row of an unattributed send failure that
    /// carried image/file parts: the "don't send X to this model again" manual
    /// exception, offered where the problem appeared. Part of ==.
    struct CapabilityAction: Equatable {
        var model: String
        var images: Bool
        var files: Bool
    }
    var capabilityAction: CapabilityAction?
    /// Ignored by ==: it captures only stable references (store + message id).
    var onFork: () -> Void = {}
    /// Likewise ignored by == (same shape as `onFork`).
    var onExport: () -> Void = {}
    /// Likewise ignored by ==.
    var onRetry: () -> Void = {}
    var onEditPrompt: () -> Void = {}
    /// Likewise ignored by ==. Resolves at click time to the text that has
    /// ARRIVED, which differs from `message.text` while the typewriter is still
    /// revealing this row — Copy promises the whole response.
    var fullText: () -> String = { "" }
    /// Likewise ignored by ==.
    var onRecordException: (ContentCapability) -> Void = { _ in }

    @AppStorage("bubbleStyle") private var bubbleStyleRaw = BubbleStyle.accentTint.rawValue
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false
    /// Reveals the user bubble's timestamp while the pointer is over it —
    /// transient UI state, deliberately outside the Equatable gate.
    @State private var hovered = false

    /// "2026-10-23 13:03:42" — fixed POSIX-pinned format: a logged timestamp
    /// must never re-spell itself with the device locale.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Single-text-view rows (user bubble, activity, error) render one string,
    /// so the message's occurrence numbering IS the view's.
    private var textFind: TextFind? {
        find.map { TextFind(query: $0.query, active: $0.activeOccurrence) }
    }

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.rerunnable == rhs.rerunnable
            && lhs.showCaret == rhs.showCaret
            && lhs.find == rhs.find
            && lhs.reveal == rhs.reveal
            && lhs.waitingStatus == rhs.waitingStatus
            && lhs.waitingReasoning == rhs.waitingReasoning
            && lhs.capabilityAction == rhs.capabilityAction
            && abs(lhs.bubbleMaxWidth - rhs.bubbleMaxWidth) < 0.5
    }

    var body: some View {
        switch message.role {
        case .user:
            let style = BubbleStyle(rawValue: bubbleStyleRaw) ?? .accentTint
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        if !message.attachments.isEmpty {
                            ForEach(message.attachments) { attachment in
                                Label(attachment.filename, systemImage: "paperclip")
                                    .font(.system(size: 11))
                                    .foregroundStyle(style == .accentFill
                                        ? Theme.contrastingForeground(on: accentHex).opacity(0.75)
                                        : Color.secondary)
                            }
                        }
                        if !message.text.isEmpty {
                            SelectableText(
                                attributed: MarkdownRenderer.plain(
                                    message.text,
                                    color: Theme.bubbleForegroundNSColor(style: style, accentHex: accentHex)
                                ),
                                find: textFind
                            )
                        }
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 14)
                    .background(
                        Theme.bubbleFill(style: style, accentHex: accentHex, dark: scheme == .dark),
                        // Square bottom-trailing corner: the bubble "speaks"
                        // downward from the trailing edge, chat-app style,
                        // against the trailing alignment.
                        in: UnevenRoundedRectangle(
                            cornerRadii: RectangleCornerRadii(
                                topLeading: 18, bottomLeading: 18, bottomTrailing: 0, topTrailing: 18
                            ),
                            style: .continuous
                        )
                    )
                    .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
                    .onHover { hovered = $0 }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                // The question's timestamp: hidden until the pointer rests on
                // the bubble, then a small right-aligned line under it. The
                // assistant rows carry no stamp — one side timestamps each
                // exchange, and the reply visibly follows its question.
                if let createdAt = message.createdAt {
                    Text(Self.timestampFormatter.string(from: createdAt))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .opacity(hovered ? 1 : 0)
                        .animation(.easeInOut(duration: 0.15), value: hovered)
                }
                // Only when this bubble is the last thing in the transcript, i.e.
                // the reply came back empty and left nothing else to hang them on.
                if rerunnable { rerunRow() }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            // Before the first token the row has nothing but a caret to show, and
            // a Codex cold start plus silent reasoning can hold that state for
            // tens of seconds — which reads as a frozen app. Pulse a status
            // instead until real text arrives.
            if let waitingStatus, message.text.isEmpty {
                WaitingIndicator(status: waitingStatus, reasoning: waitingReasoning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    // Only reachable once the answer has text, because the empty
                    // streaming row takes the branch above — so a reasoning
                    // stream never re-measures a text view while it arrives, and
                    // collapsed (the default) this renders no text view at all.
                    if let reasoning = message.reasoning, !reasoning.isEmpty {
                        ReasoningDisclosure(text: reasoning)
                    }
                    AssistantMessageView(
                        text: message.text, showCaret: showCaret, find: find, reveal: reveal
                    )
                    // Always visible once the response is complete; occupies its
                    // space during streaming (opacity only) so finishing never
                    // reflows the transcript.
                    if !message.text.isEmpty {
                        HStack(spacing: 12) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(fullText(), forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                            } label: {
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                            }
                            .help("Copy the whole response")
                            Button(action: onFork) {
                                Label("Fork", systemImage: "arrow.triangle.branch")
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                            }
                            .help("Start a new conversation from this point")
                            Button(action: onExport) {
                                Label("Export", systemImage: "square.and.arrow.up")
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                            }
                            .help("Export this reply as Markdown…")
                            if rerunnable {
                                rerunButtons
                            }
                            // "62518 tokens · 5m 42s · 51.6 tok/s" — total
                            // (incl. prompt) · network time · output rate.
                            // Providers that report no usage leave the token
                            // counts nil and only the duration renders.
                            Spacer(minLength: 16)
                            if let stats = message.stats {
                                Text(stats.displayLine)
                                    .font(.system(size: 10.5).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                                    .help("Total tokens (prompt included) · network time · output tokens per second")
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .opacity(showCaret ? 0 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button("Copy Message") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fullText(), forType: .string)
                    }
                    Button("Fork Here", action: onFork)
                    Button("Export Reply…", action: onExport)
                    if rerunnable {
                        Divider()
                        Button("Retry", action: onRetry)
                        Button("Edit Prompt…", action: onEditPrompt)
                    }
                }
            }
        case .activity:
            Label { Text(FindHighlight.paint(message.text, find: textFind)) } icon: {
                Image(systemName: "sparkles")
            }
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            VStack(alignment: .leading, spacing: 6) {
                Label { Text(FindHighlight.paint(message.text, find: textFind)) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if let action = capabilityAction {
                    HStack(spacing: 12) {
                        if action.images {
                            Button {
                                onRecordException(.images)
                            } label: {
                                Text("Don't send images to \(action.model) again")
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                        }
                        if action.files {
                            Button {
                                onRecordException(.files)
                            } label: {
                                Text("Don't send PDFs directly to \(action.model) again")
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
                }
                // A failed send is the moment retry matters most — the fix
                // (add a key, switch model) happens elsewhere and the user
                // comes back needing exactly this.
                if rerunnable { rerunRow(leadingPadding: 22) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The rerun actions as their own row, for the branches that have no action
    /// cluster to join (the assistant row folds `rerunButtons` into its existing
    /// Copy/Fork HStack instead, which is where this styling comes from).
    private func rerunRow(leadingPadding: CGFloat = 0) -> some View {
        HStack(spacing: 12) { rerunButtons }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .padding(.leading, leadingPadding)
    }

    /// Re-run the last turn: same question to whatever the pill now names, or
    /// the question back in the composer to reword.
    @ViewBuilder
    private var rerunButtons: some View {
        Button(action: onRetry) {
            Label("Retry", systemImage: "arrow.clockwise")
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .help("Ask again — switch the model in the pill first to retry with a different one")
        Button(action: onEditPrompt) {
            Label("Edit prompt", systemImage: "pencil")
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .help("Put your last message back in the composer to edit and resend")
    }
}

/// The model's thinking, collapsed by default: a chat panel is for the answer,
/// and reasoning summaries routinely run longer than the reply they precede.
///
/// Expansion is local state, so opening one row never touches another; and the
/// row only reaches this view once the answer has text (an empty streaming row
/// renders the waiting indicator instead), so nothing here re-measures while
/// reasoning is still arriving.
private struct ReasoningDisclosure: View {
    let text: String

    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: "brain")
                        .font(.system(size: 10))
                    Text("Reasoning")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the model's thinking" : "Show the model's thinking")
            if expanded {
                SelectableText(attributed: MarkdownRenderer.attributedReasoning(text))
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Theme.liftedBorder(dark: scheme == .dark))
                            .frame(width: 1)
                    }
                    // The rule ends where the thinking does; without this the
                    // last line butts straight into the answer below it.
                    .padding(.bottom, 6)
            }
        }
    }
}

/// What the transcript area shows while a picked history conversation decodes:
/// three accent dots pulsing in a staggered wave — the app's waiting language,
/// with no label. The pulses are CA-driven repeatForever opacity (the caret
/// rule), which matters twice here: the main actor stays free while the decode
/// runs off-thread, and when the adopted transcript's first (heavy) layout pass
/// does block it, the wave keeps animating on the render server instead of
/// freezing — which is the whole white-screen fix.
private struct ChatLoadingIndicator: View {
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @State private var waving = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Theme.color(accentHex))
                    .frame(width: 7, height: 7)
                    .opacity(waving ? 0.2 : 1)
                    .animation(
                        // The stagger is start-delay only: repeatForever never
                        // re-applies it, so the phase offset between dots — the
                        // wave — survives every cycle.
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.18),
                        value: waving
                    )
            }
        }
        .onAppear { waving.toggle() }
    }
}

/// What an empty streaming row shows while the network turn has produced no text
/// yet: a pulsing status plus, once the wait is long enough to read as a hang,
/// an elapsed counter. The pulse is a repeatForever opacity animation — CA-driven
/// per the caret rule, so no tick ever re-evaluates SwiftUI. Replaced by the
/// normal caret/text rendering the moment the first characters commit.
struct WaitingIndicator: View {
    let status: String
    /// The model's thinking so far. When it is present the row shows a scrolling
    /// window onto it instead of the bare status — a reasoning model can spend a
    /// minute here, and one truncated line wastes the most interesting thing on
    /// screen.
    var reasoning: String?

    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @State private var pulsing = false
    @State private var startedAt = Date()
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Visible lines of thinking, collapsed and expanded. Both are FIXED — the
    /// text scrolls inside the window rather than growing it, which is what
    /// keeps a token arriving from reflowing the transcript. (The old
    /// single-line status relied on `lineLimit(1)` for the same reason; a fixed
    /// window gets it structurally, and shows two more lines.)
    static let collapsedLines = 3
    static let expandedLines = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.color(accentHex))
                    .frame(width: 7, height: 7)
                    .opacity(pulsing ? 0.25 : 1)
                Text(thinking ? "Thinking" : status)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(pulsing ? 0.55 : 1)
                ElapsedLabel(since: startedAt)
                    .fixedSize()
                if thinking {
                    Spacer(minLength: 4)
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                            expanded.toggle()
                        }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Show less thinking" : "Show more thinking")
                }
            }
            if let reasoning, thinking {
                ThinkingScroller(
                    text: reasoning,
                    lines: expanded ? Self.expandedLines : Self.collapsedLines
                )
                // Same top fade the transcript uses under the pills: a window
                // onto scrolling text otherwise cuts the line above in half.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.22),
                            .init(color: .black, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }

    private var thinking: Bool {
        !(reasoning ?? "").isEmpty
    }
}

/// A fixed-height window onto text that is still arriving, which follows the
/// end as it grows.
///
/// AppKit-backed for the same reason the composer is: this updates at wire rate
/// (50–150 chunks/s from a reasoning model), and a SwiftUI `Text` would re-measure
/// the whole accumulated string every time. Here the height is a constant the
/// caller picks, so SwiftUI never measures the content at all — and the text
/// view is APPENDED to rather than rebuilt, since each update carries the same
/// string plus a suffix.
struct ThinkingScroller: NSViewRepresentable {
    let text: String
    var lines: Int

    static let font = NSFont.systemFont(ofSize: 11.5)
    /// The exact height `lines` of this font occupy — the harness pins the view
    /// to it, since a window that grows with its content is the whole bug.
    static func height(lines: Int) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font)) * CGFloat(lines) + 4
    }

    final class Coordinator {
        var shown = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Model thinking")

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // Drops fall through to the panel-wide attachment target.
        textView.unregisterDraggedTypes()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        let shown = context.coordinator.shown
        guard text != shown else { return }

        // Whether to follow is decided BEFORE the append: a user who scrolled up
        // to read is reading, and yanking them back is the transcript's own rule.
        let following = context.coordinator.shown.isEmpty || isAtBottom(scroll)
        if text.hasPrefix(shown) {
            textView.textStorage?.append(rendered(String(text.dropFirst(shown.count))))
        } else {
            textView.textStorage?.setAttributedString(rendered(text))
        }
        context.coordinator.shown = text
        // Unanimated, per the follow-scroll rule: at this update rate an
        // animation would restart every tick and layout would never settle.
        if following { textView.scrollToEndOfDocument(nil) }
    }

    private func isAtBottom(_ scroll: NSScrollView) -> Bool {
        let visible = scroll.contentView.bounds
        let total = scroll.documentView?.frame.height ?? 0
        return total <= visible.height || visible.maxY >= total - 8
    }

    /// Emphasis markers are dropped as the text arrives — reasoning summaries
    /// arrive with `**bold**` section headings, and a live feed showing the
    /// asterisks looks broken.
    ///
    /// Stripped per APPENDED CHUNK, not over the whole trace: this runs at wire
    /// rate, so anything O(accumulated text) here is O(n²) over a turn. That
    /// rules out a real markdown pass (the settled copy gets one — see
    /// `MarkdownRenderer.attributedReasoning`, which the disclosure uses once
    /// the answer arrives) and it is why `_` is left alone: character-wise
    /// stripping cannot tell emphasis from an identifier, and `snake_case` in a
    /// thought is likelier than underscore emphasis.
    static func stripEmphasis(_ chunk: String) -> String {
        String(chunk.filter { $0 != "*" && $0 != "`" && $0 != "#" })
    }

    private func rendered(_ string: String) -> NSAttributedString {
        NSAttributedString(string: Self.stripEmphasis(string), attributes: [
            .font: Self.font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: Self.height(lines: lines))
    }
}

/// "24s" beside the waiting status — appears only after 8 s, when slow starts
/// needing reassurance separate from ordinary latency. A 1 Hz TimelineView on
/// its own leaf view: seeded from a stable @State date, never `.now` (which
/// would re-create the schedule on every evaluation — the trap the caret rule
/// exists for), so a tick re-evaluates nothing but this label.
private struct ElapsedLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = Int(context.date.timeIntervalSince(since))
            if seconds >= 8 {
                Text("\(seconds)s")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
