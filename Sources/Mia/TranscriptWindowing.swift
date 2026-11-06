import SwiftUI

// Lane A: transcript windowing. The transcript is a plain VStack that used to
// materialize EVERY message — one NSTextField per text segment (SelectableText),
// and in a layer-backed window every NSTextField owns a CABackingStore — so long
// conversations accumulated hundreds of megabytes of CoreAnimation memory. These
// types keep the plain VStack (NEVER LazyVStack: its height re-estimation fed an
// infinite layout loop that froze the app) while rendering only a scrolling
// WINDOW of real rows; everything else collapses to a height-preserving
// placeholder that holds no NSTextField at all.
//
// IRON RULES (hard-won from the freeze regression — do not break):
// 1. A degraded row's placeholder uses its MEASURED height from the cache
//    (an estimate only for rows never materialized). A row entering or leaving
//    the window must not change the content height, or the scroll position
//    drifts and layout thrashes — the LazyVStack death spiral.
// 2. Materialize/degrade swaps are never animated (placeholders use
//    .transition(.identity)); an animated swap would fight NSScrollView's
//    position adjustments exactly the way LazyVStack's re-estimates did.
// 3. The streaming row, the waiting row, the rerun row, the bottom 3 rows and
//    the jump target row are ALWAYS materialized (ChatView.forcedIDs).
// 4. The SelectableText/MessageRow internals, the .equatable() gating and the
//    per-row gating lets in the ForEach are untouched.
// 5. Window-set math lives in the Coordinator's notification callbacks, never
//    in `body` — body stays O(n) at worst, never O(n²).
// 6. macOS 14 has no onScrollGeometryChange: everything below is
//     NSViewRepresentable + NotificationCenter. No dual paths.

/// Reference-shared row-height cache: message id → height measured by the row's
/// own GeometryReader while materialized. Written from the SwiftUI preference
/// callback in ChatView (via `mergeMeasured`, which also compensates the scroll
/// offset for estimate corrections above the viewport), read by the viewport
/// tracker and by placeholder rows. A class on purpose — writing it never
/// re-evaluates a body.
final class TranscriptLayoutBox {
    var rowHeights: [UUID: CGFloat] = [:]
    /// One-shot estimates for rows never measured at the current width. Kept
    /// HERE, not in the tracker's coordinator, so body's placeholder branch
    /// and the coordinator's window math read strictly the same numbers
    /// (P2-1: the estimate walks the full text — cached, it runs once per row
    /// per width instead of on every body evaluation).
    var estimates: [UUID: CGFloat] = [:]
    /// Width the caches below were taken at; nil until the first report.
    private(set) var cachedWidth: CGFloat?
    /// True once any measured height has merged for this conversation — the
    /// probe's activation gate is grace AND this flag (P1-1 double guard: a
    /// giant restore must finish measuring before windowing starts, or the
    /// first window would be computed over all-estimate tops).
    private(set) var hasMeasuredHeights = false
    /// Messages snapshot refreshed on every transcriptZone evaluation —
    /// `mergeMeasured` runs inside the Sendable onPreferenceChange closure,
    /// which must not reach into @MainActor store state (the ContentHeightKey
    /// warning is the cautionary example). Body evaluation always precedes
    /// layout, hence every preference callback.
    var currentMessages: [ChatMessage] = []
    /// The scroll probe this box compensates through; the tracker's
    /// coordinator re-points it on every update. Weak on purpose.
    weak var probe: TranscriptProbeView?

    /// Must match the VStack(spacing:) the transcript renders its rows in
    /// (transcriptZone). The tracker accumulates row tops with it.
    static let rowSpacing: CGFloat = 14

    /// Width determines height: every cached measurement and estimate belongs
    /// to the width it was taken at. THE single clearing point (P1-1/P2-1) —
    /// ChatView's onChange(of: transcriptWidth) calls this and nothing else;
    /// the tracker's coordinator holds no width state of its own.
    func widthDidChange(_ width: CGFloat) {
        guard cachedWidth != width else { return }
        cachedWidth = width
        rowHeights.removeAll(keepingCapacity: true)
        estimates.removeAll(keepingCapacity: true)
    }

    /// Conversation swap (P2-2): drop everything measured and estimated so
    /// the next conversation's windowing starts from real measurements, and
    /// estimates from the previous conversation can never leak across (also
    /// bounds both tables — they only ever grow within one conversation).
    func resetForNewConversation() {
        rowHeights.removeAll(keepingCapacity: true)
        estimates.removeAll(keepingCapacity: true)
        hasMeasuredHeights = false
    }

    /// THE single source of a row's layout height: measured cache first, else
    /// the (cached) estimate. The placeholder branch in ChatView and the
    /// coordinator's window math MUST both go through this — two independent
    /// height values for one row are how content shifts under the viewport.
    func heightForPlacement(_ id: UUID, fallback: () -> CGFloat) -> CGFloat {
        if let measured = rowHeights[id] { return measured }
        if let estimate = estimates[id] { return estimate }
        let value = fallback()
        estimates[id] = value
        return value
    }

    /// Box-side convenience for callers holding messages (the coordinator,
    /// the compensation pass): estimate with the cached width when the row
    /// has never been measured.
    func placementHeight(for message: ChatMessage) -> CGFloat {
        heightForPlacement(message.id) {
            Self.estimatedHeight(of: message, width: cachedWidth ?? 680)
        }
    }

    /// Shared row-top enumeration (P1-1: compensation and windowing must
    /// accumulate identically). Walks `messages` top-down from `regionTop`,
    /// handing each row's message, top and height to `visit`.
    func enumerateRowTops(
        _ messages: [ChatMessage], regionTop: CGFloat, _ visit: (ChatMessage, CGFloat, CGFloat) -> Void
    ) {
        var top = regionTop
        for message in messages {
            let height = placementHeight(for: message)
            visit(message, top, height)
            top = top + height + Self.rowSpacing
        }
    }

    /// Merges one cohort of measured heights and compensates the scroll
    /// offset for estimate corrections ABOVE the viewport (P1-1): a row that
    /// materializes for the first time replaces its estimate h_est with the
    /// real h_real; if it sits above the visible rect, everything below —
    /// including the visible content — shifts by Δ, so the origin moves by
    /// the summed Δ of all such rows (one setBoundsOrigin for the whole
    /// same-frame cohort). Standard NSScrollView practice.
    ///
    /// Only rows with NO prior measured height compensate: organic growth of
    /// a measured row above the viewport (the streaming reply once it
    /// outgrows the screen — its top sits above the viewport top) keeps
    /// today's behavior on purpose; compensating it would fight the
    /// follow-the-bottom pin with a per-tick offset war.
    func mergeMeasured(_ measured: [UUID: CGFloat]) {
        guard !measured.isEmpty else { return }
        let firstMeasurements = !hasMeasuredHeights
        hasMeasuredHeights = true
        // Deltas taken BEFORE the merge overwrites the old values.
        var corrections: [UUID: CGFloat] = [:]
        for (id, measuredHeight) in measured {
            if rowHeights[id] == nil, let estimate = estimates[id],
               abs(measuredHeight - estimate) > 0.5 {
                corrections[id] = measuredHeight - estimate
            }
            rowHeights[id] = measuredHeight
        }
        // P1-1 grace double-guard support: the FIRST merge ever (or after a
        // conversation reset) is what makes windowing eligible — nudge the
        // probe so a slow restore reports its window the moment measuring
        /// finishes, instead of waiting for the next scroll.
        if firstMeasurements { probe?.probeNow() }
        guard !corrections.isEmpty,
              let probe,
              let scrollView = probe.enclosingScrollView,
              let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let offset = clip.bounds.origin.y
        let container = clip.bounds.height
        guard container > 0 else { return }
        let regionTop = probe.convert(.zero, to: document).y
        // Row tops with POST-merge heights — the geometry the next layout
        // pass commits. A row counts only when its top is ABOVE the visible
        // top: below it, the correction pushes content the reader cannot see.
        var shift: CGFloat = 0
        enumerateRowTops(currentMessages, regionTop: regionTop) { message, top, _ in
            if let delta = corrections[message.id], top < offset {
                shift += delta
            }
        }
        guard shift != 0 else { return }
        // Timing: the preference callback lands after the layout commit, so
        // the shift is visible for one frame before the origin pins it back —
        // the smallest flicker achievable in the SwiftUI/AppKit mix, and far
        // better than the persistent misalignment it replaces.
        let maxOffset = max(0, document.frame.height - container)
        let target = min(max(offset + shift, 0), maxOffset)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
        // setBoundsOrigin posts boundsDidChange → the probe fires → the
        // coordinator recomputes — an origin tweak never changes the window
        // SET, so nothing reports and nothing loops.
    }

    /// Coarse one-shot estimate for a row that was never materialized at this
    /// width. Only ever a placeholder's stand-in: the row's first
    /// materialization replaces it with the measured value, and the window
    /// hysteresis (materialize two screens early) means the correction lands
    /// off-screen. Deliberately cheap — accuracy is not the goal.
    static func estimatedHeight(of message: ChatMessage, width: CGFloat) -> CGFloat {
        let base: CGFloat
        switch message.role {
        case .user, .assistant: base = 48 // bubble padding / footer / stall line
        case .activity, .error: base = 28 // one-line label
        }
        // User text wraps at the bubble's max width; assistant text at full width.
        let bubble = max(220, (width - 32) * 0.78)
        let usable = max(120, message.role == .user ? bubble - 28 : width - 32)
        let charsPerLine = max(24, Int(usable / 7.5))
        let lines = max(1, (message.text.count + charsPerLine - 1) / charsPerLine)
        var height = base + CGFloat(lines) * 16
        if !message.attachments.isEmpty { height += CGFloat(message.attachments.count) * 22 + 6 }
        if let reasoning = message.reasoning, !reasoning.isEmpty { height += 30 } // collapsed disclosure
        if message.text.contains("```") { height += 64 } // code-block padding allowance
        return height
    }
}

/// Per-row measured heights, merged up from every materialized row's
/// GeometryReader background. Reduce merges dictionaries so the VStack-level
/// `.onPreferenceChange` sees the whole cohort in one callback.
struct TranscriptRowHeightKey: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { _, measured in measured }
    }
}

/// AppKit scroll observer for the transcript's ScrollView (macOS 14 has no
/// onScrollGeometryChange, hence NSViewRepresentable + NotificationCenter).
///
/// The probe view rides as a `.background` of the rows' UNPADDED VStack, so its
/// bounds origin sits exactly at the first row's top edge and
/// `convert(.zero, to: documentView)` yields the rows' region origin in
/// document coordinates — the window math below carries no hardcoded insets.
struct TranscriptViewportTracker: NSViewRepresentable {
    var messages: [ChatMessage]
    var box: TranscriptLayoutBox
    /// Reports the new materialization window ONLY when it differs from the
    /// last reported one — scrolling must not re-evaluate ChatView's body per
    /// frame, only on actual window membership changes.
    var onWindowChange: (Set<UUID>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TranscriptProbeView {
        let probe = TranscriptProbeView()
        probe.onViewportChange = { [weak coordinator = context.coordinator] in
            coordinator?.recompute()
        }
        return probe
    }

    func updateNSView(_ probe: TranscriptProbeView, context: Context) {
        let coordinator = context.coordinator
        probe.onViewportChange = { [weak coordinator] in coordinator?.recompute() }
        coordinator.probe = probe
        coordinator.messages = messages
        coordinator.box = box
        coordinator.onWindowChange = onWindowChange
        box.probe = probe // the box's compensation path reaches the clip view through this
        // Content changed shape (rows added/removed): recompute membership off
        // the notification path. Async'd because updateNSView runs inside a
        // view update and the report writes @State upstream.
        guard coordinator.contentCount != messages.count else { return }
        coordinator.contentCount = messages.count
        DispatchQueue.main.async { coordinator.recompute() }
    }

    final class Coordinator {
        var messages: [ChatMessage] = []
        var box: TranscriptLayoutBox?
        var onWindowChange: ((Set<UUID>) -> Void)?
        weak var probe: TranscriptProbeView?

        /// Last reported window; nil until the first report. The first report
        /// uses the ENTER threshold for every row (see TranscriptProbeView's
        /// activation grace for why everything is materialized before it).
        private var lastWindow: Set<UUID>?
        var contentCount = -1

        /// The window math (iron rule 5: never in `body`). Walks row tops via
        /// the box's shared enumeration (the same accumulation the estimate
        /// compensation uses) and keeps every row intersecting the viewport,
        /// with hysteresis: a row materializes once it comes within ENTER
        /// screens of the viewport and stays until it is fully EXIT screens
        /// away. That makes the estimate→measured correction land well
        /// off-screen, and a degrade height-preserving (cached value), so
        /// membership churn can never oscillate the layout.
        ///
        /// Activation is grace AND `box.hasMeasuredHeights` (P1-1 double
        /// guard): until real heights have merged, the row tops below are all
        /// estimates and the window would be computed over fiction.
        func recompute() {
            guard let probe, let box, probe.windowingActive, box.hasMeasuredHeights,
                  let scrollView = probe.enclosingScrollView else { return }
            let clip = scrollView.contentView
            let offset = clip.bounds.origin.y
            let container = clip.bounds.height
            guard container > 0, !messages.isEmpty else { return }
            // Rows' region top in document coordinates. SwiftUI's hosting
            // document view is flipped, so y grows down like the accumulation.
            let regionTop = scrollView.documentView.map { probe.convert(.zero, to: $0).y } ?? 0

            let enter = container * 2 // materialize two screens early
            let exit = container * 3 // degrade only past three screens
            let enterTop = offset - enter
            let enterBottom = offset + container + enter
            let exitTop = offset - exit
            let exitBottom = offset + container + exit

            var window = Set<UUID>(minimumCapacity: messages.count)
            let last = lastWindow
            box.enumerateRowTops(messages, regionTop: regionTop) { message, top, height in
                let bottom = top + height
                if let last, last.contains(message.id) {
                    if bottom > exitTop, top < exitBottom { window.insert(message.id) }
                } else {
                    if bottom > enterTop, top < enterBottom { window.insert(message.id) }
                }
            }
            guard window != lastWindow else { return }
            lastWindow = window
            let report = onWindowChange
            // Hop out of whatever layout pass posted the notification; the
            // write lands in ChatView's @State on the next runloop tick.
            DispatchQueue.main.async { report?(window) }
        }
    }
}

/// The NSView half of the tracker: a zero-cost marker inside the scroll content
/// that subscribes to the clip view's bounds changes (scrolling) and the
/// document view's frame changes (content growth), and hands each to the
/// coordinator. Unsubscribes when removed from the window.
final class TranscriptProbeView: NSView {
    var onViewportChange: (() -> Void)?

    /// Mount-time grace: when the transcript subtree first appears (a
    /// conversation restore, the draft editor closing) ChatView's window is
    /// nil, meaning EVERY row materializes — so the initial layout, the
    /// pre-scroll to the bottom and the reveal all land on MEASURED heights.
    /// Windowing engages only after this grace expires AND the box reports
    /// at least one measured height (`hasMeasuredHeights`, checked in the
    /// coordinator — P1-1 double guard); degrades then swap rows for
    /// height-identical placeholders (iron rule 1), so the settled scroll
    /// position never moves.
    private(set) var windowingActive = false

    /// Seconds after attach before windowing engages.
    private static let grace: TimeInterval = 0.3

    private var observers: [NSObjectProtocol] = []
    private var clip: NSView?
    private var document: NSView?
    private var clipPostsBounds = true
    private var documentPostsFrame = false
    private var activation: DispatchWorkItem?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    deinit { detach() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attach() } else { detach() }
    }

    /// Cheap self-healing: if viewDidMoveToWindow fired before the scroll view
    /// was wired up (nil enclosingScrollView), attach on the next draw pass
    /// instead of windowing never engaging at all.
    override func viewWillDraw() {
        super.viewWillDraw()
        if observers.isEmpty, window != nil { attach() }
    }

    private func attach() {
        detach()
        guard let scrollView = enclosingScrollView,
              let documentView = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        clip = clipView
        document = documentView
        clipPostsBounds = clipView.postsBoundsChangedNotifications
        documentPostsFrame = documentView.postsFrameChangedNotifications
        clipView.postsBoundsChangedNotifications = true
        documentView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: nil
        ) { [weak self] _ in self?.fire() })
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification, object: documentView, queue: nil
        ) { [weak self] _ in self?.fire() })
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil else { return }
            self.windowingActive = true
            self.fire()
        }
        activation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace, execute: work)
    }

    private func detach() {
        activation?.cancel()
        activation = nil
        windowingActive = false
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        clip?.postsBoundsChangedNotifications = clipPostsBounds
        document?.postsFrameChangedNotifications = documentPostsFrame
        clip = nil
        document = nil
    }

    private func fire() {
        guard windowingActive else { return }
        onViewportChange?()
    }

    /// External nudge used by TranscriptLayoutBox when its activation flag
    /// (`hasMeasuredHeights`) first flips true after the grace already
    /// expired — windowing becomes eligible at that exact moment instead of
    /// waiting for the next scroll or frame-change notification.
    func probeNow() { fire() }
}
