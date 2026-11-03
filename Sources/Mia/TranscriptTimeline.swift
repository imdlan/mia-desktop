import SwiftUI

/// Right-edge question timeline: one rounded bar per user question, floating
/// vertically centered over the transcript's trailing edge. Magnification is
/// driven by the CONTINUOUS pointer position (`onContinuousHover`), Dock-style:
/// the bar nearest the pointer is widest, neighbors taper with distance, all
/// right edges stay on one axis so growth extends leftward. The bar nearest
/// the pointer pops a thumbnail of that question's text; clicking a bar jumps
/// the transcript to the question (same `ScrollViewReader` anchor the find bar
/// uses). Hidden below two questions — a single-question timeline is noise.
///
/// Deliberately animation-free: two rounds of testing showed that animating
/// these values (springs on discrete hover events, animated collapse) made the
/// bars seesaw and could drop hover re-entry, and every fix stacked more state
/// on top. The pointer-driven values are already continuous while the pointer
/// moves, so the tracking reads smoothly without any animation; state changes
/// on entry/leave are instant.
///
/// The bars live in the trailing margin the bubbles never enter (bubble max
/// width is 78% of the transcript), so the hover strip never blocks content.
///
/// Layout is driven by the REAL container height: a GeometryReader reads the
/// transcript overlay's height each frame and the per-row pitch is
/// `clamp(available / count, floors, defaults)` — gap compresses first, then
/// row height, then bar height, each with a floor; beyond the floors the pitch
/// stays exactly `available / count` so the column can never exceed the
/// container at any turn count. Bar centers derive from rowHeight/2, never a
/// hardcoded offset, so hover math stays correct as rows compress.
struct TranscriptTimeline: View {
    let questions: [ChatMessage]
    /// Jump callback — ChatView owns the `ScrollViewReader` proxy.
    let onJump: (UUID) -> Void

    /// Pointer Y inside the column, nil while the pointer is elsewhere.
    @State private var pointerY: CGFloat?
    /// The bar nearest the pointer — owns the tooltip and the accent tint.
    @State private var hovered: UUID?
    /// Resting state: after 2s of the pointer being away, the whole column
    /// drops to 40% opacity so a bright affordance doesn't sit permanently in
    /// the margin.
    @State private var dimmed = false
    @State private var dimWork: DispatchWorkItem?
    /// Natural single-line width of each question's text, measured offscreen.
    /// The tooltip needs this because an overlay proposes its CONTAINER's
    /// width — 24pt — to the bubble, which would wrap the text vertically.
    @State private var naturalWidths: [UUID: CGFloat] = [:]

    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { Theme.color(accentHex) }

    var body: some View {
        GeometryReader { container in
            strip(availableHeight: container.size.height)
        }
        .background(naturalWidthMeasurements)
        .onPreferenceChange(TooltipWidthKey.self) { naturalWidths = $0 }
    }

    /// The bar column. Sized to its own resolved metrics and re-centered in
    /// the container (GeometryReader top-aligns children; the hover strip and
    /// thumbnail overlay must attach to the COLUMN's bounds — the strip's
    /// pointer math is relative to the column's top, and the tooltip anchors
    /// to the column's vertical center — not to the container's).
    private func strip(availableHeight: CGFloat) -> some View {
        let metrics = Metrics.resolve(count: questions.count, available: availableHeight)
        return VStack(spacing: metrics.gap) {
            ForEach(questions.indices, id: \.self) { index in
                markerRow(questions[index], index: index, metrics: metrics)
            }
        }
        .frame(width: 24, height: metrics.columnHeight(for: questions.count))
        // Interactions attach to the COLUMN's bounds, before the expansion
        // frame below widens the view to the container: the tracking strip's
        // pointer math is column-relative (top = first bar's row), and an
        // NSView spanning the whole transcript would swallow content clicks
        // and fire hover magnification from anywhere over the chat.
        .opacity(dimmed ? 0.4 : 1)
        .overlay {
            // AppKit-native hover tracking. SwiftUI's onHover/onContinuousHover
            // proved unreliable here (dropped re-entry after an exit, twice,
            // across two implementations) — NSTrackingArea with .activeAlways
            // is the canonical mechanism and does not miss events.
            HoverTrackingStrip(
                onMove: { y in
                    if let y {
                        activate(at: y, metrics: metrics)
                    } else {
                        deactivate()
                    }
                },
                onClick: { y in
                    onJump(nearestQuestion(at: y, metrics: metrics))
                }
            )
        }
        .overlay(alignment: .trailing) {
            if let index = hoveredIndex {
                thumbnail(questions[index])
                    .offset(x: -32, y: tooltipOffsetY(index, metrics: metrics))
                    // Fade only — no scale/fly-in.
                    .transition(.opacity)
            }
        }
        // Re-center VERTICALLY only; trailing stays pinned to the overlay's
        // trailing edge (a bare maxWidth/maxHeight frame would center
        // horizontally too and park the strip mid-window). LAST, so everything
        // above stays sized to the column.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    // MARK: - Hover state machine (no animation)

    private func activate(at y: CGFloat, metrics: Metrics) {
        dimWork?.cancel()
        dimWork = nil
        dimmed = false
        pointerY = y
        hovered = nearestQuestion(at: y, metrics: metrics)
    }

    private func deactivate() {
        pointerY = nil
        hovered = nil
        dimWork?.cancel()
        let work = DispatchWorkItem { dimmed = true }
        dimWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - Layout

    /// Metrics resolved from the real container height. The ladder compresses
    /// in three stages before giving up any height at all:
    /// 1. defaults — row 6 / gap 2 (8pt pitch, ruler-density: the column is a
    ///    marginal overview, not content, so ~60 turns fit uncompressed);
    /// 2. gap-only — gap slides 2 → 1 with the row still 6;
    /// 3. row-only — gap pinned at 1, row shrinks 6 → 3.5, and the bar thins
    ///    3 → 2 once rows drop under 4.5pt so the capsule never fills the row;
    /// 4. beyond the floors — pitch stays exactly `available / count` (split
    ///    75/25 row/gap, bar at its 2pt floor), so the column mathematically
    ///    never exceeds the container at ANY turn count.
    private struct Metrics {
        let rowHeight: CGFloat
        let gap: CGFloat
        let barHeight: CGFloat

        /// Distance between consecutive bar centers.
        var pitch: CGFloat { rowHeight + gap }

        func columnHeight(for count: Int) -> CGFloat {
            guard count > 0 else { return 0 }
            return CGFloat(count) * rowHeight + CGFloat(count - 1) * gap
        }

        static let defaultRowHeight: CGFloat = 6
        static let defaultGap: CGFloat = 2
        static let idleBarHeight: CGFloat = 3
        static let minRowHeight: CGFloat = 3.5
        static let minGap: CGFloat = 1
        static let minBarHeight: CGFloat = 2
        /// Breathing room kept clear at the container's top/bottom (6pt each).
        static let verticalInset: CGFloat = 12

        static func resolve(count: Int, available: CGFloat) -> Metrics {
            let usable = max(0, available - verticalInset)
            let n = CGFloat(max(count, 1))
            if n * (defaultRowHeight + defaultGap) <= usable {
                return Metrics(rowHeight: defaultRowHeight, gap: defaultGap, barHeight: idleBarHeight)
            }
            let pitch = usable / n
            if pitch >= defaultRowHeight + minGap {
                return Metrics(rowHeight: defaultRowHeight, gap: pitch - defaultRowHeight, barHeight: idleBarHeight)
            }
            if pitch >= minRowHeight + minGap {
                let row = pitch - minGap
                return Metrics(
                    rowHeight: row,
                    gap: minGap,
                    barHeight: row < 9 ? minBarHeight : idleBarHeight
                )
            }
            let row = max(minBarHeight, pitch * 0.75)
            return Metrics(rowHeight: row, gap: max(0.5, pitch - row), barHeight: minBarHeight)
        }
    }

    private var hoveredIndex: Int? {
        hovered.flatMap { id in questions.firstIndex { $0.id == id } }
    }

    private func nearestQuestion(at y: CGFloat, metrics: Metrics) -> UUID {
        // Bar centers sit at rowHeight/2 + i * pitch from the column top.
        let index = min(max(0, Int((y - metrics.rowHeight / 2).rounded() / metrics.pitch)), questions.count - 1)
        return questions[index].id
    }

    /// Vertical offset that centers the tooltip on the hovered bar, relative
    /// to the column's vertical center (the overlay's `.trailing` anchor).
    private func tooltipOffsetY(_ index: Int, metrics: Metrics) -> CGFloat {
        let barCenter = metrics.rowHeight / 2 + CGFloat(index) * metrics.pitch
        return barCenter - metrics.columnHeight(for: questions.count) / 2
    }

    /// Dock falloff from the pointer's distance to each bar's center: full
    /// magnification at the bar, smooth (smoothstep) taper across ~2 rows
    /// (fixed 30pt radius — at compressed pitches more bars share the taper,
    /// which reads like the Dock at high icon counts). Reduce Motion keeps
    /// every bar idle-sized; the hovered one still tints.
    private func magnification(for index: Int, metrics: Metrics) -> CGFloat {
        guard let pointerY, !reduceMotion else { return 0 }
        let distance = abs(pointerY - (metrics.rowHeight / 2 + CGFloat(index) * metrics.pitch))
        let t = max(0, 1 - distance / 30)
        return t * t * (3 - 2 * t)
    }

    private func markerRow(_ question: ChatMessage, index: Int, metrics: Metrics) -> some View {
        let magnify = magnification(for: index, metrics: metrics)
        let hoveredHere = hovered == question.id
        // Height grows barHeight → barHeight + 2, clamped to the row pitch so
        // a popped bar can never overlap its neighbors in a compressed column
        // (never engages at the 8pt default — 5pt max in an 8pt pitch; the
        // 9→15pt width taper and the accent tint keep hover unmistakable at
        // any density). Widths stay on one right axis, so only height can
        // collide.
        let magnifiedHeight = min(
            metrics.barHeight + 2 * magnify,
            max(metrics.barHeight, metrics.pitch)
        )
        return ZStack(alignment: .trailing) {
            Capsule()
                .fill(hoveredHere ? AnyShapeStyle(accent) : AnyShapeStyle(barColor))
                // 9→15pt wide, 3→5pt tall at full magnification — the taper
                // is proportional (a third shorter than the original 14→22).
                .frame(
                    width: 9 + 6 * magnify,
                    height: magnifiedHeight
                )
        }
        // The fixed row frame is what keeps the column's height stable while
        // bar heights change inside it — no jitter for the neighbors.
        .frame(width: 24, height: metrics.rowHeight, alignment: .trailing)
    }

    /// Idle bar color — quiet by default; hovering does the highlighting (the
    /// hovered bar turns accent and magnifies).
    private var barColor: Color {
        Color.primary.opacity(scheme == .dark ? 0.18 : 0.28)
    }

    /// The question's first lines, floating to the LEFT of the bars. Width is
    /// the measured natural single-line width clamped to 240 — with a 2-line
    /// fallback for long questions — plus the 18pt of horizontal padding the
    /// frame must include (padding is applied INSIDE the width, so the text
    /// area is `width - 18`: sizing the frame to the text width alone is what
    /// wrapped two-character questions). Hit-testing is off: the bubble is a
    /// passive overlay, and letting it intercept hover caused a flicker loop
    /// at the bubble/strip boundary.
    private func thumbnail(_ question: ChatMessage) -> some View {
        let natural = naturalWidths[question.id] ?? 240
        let textWidth = min(natural + 4, 240)
        let dark = scheme == .dark
        return Text(question.text)
            .font(.system(size: 11.5))
            .foregroundStyle(dark ? Theme.color("#f5f5f7") : Theme.color("#1d1d1f"))
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(width: textWidth + 18, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                (dark ? Theme.color("#2a2a2c") : Color.white).opacity(0.92),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(dark ? 0.4 : 0.15), radius: 4, y: 2)
            .allowsHitTesting(false)
    }

    // MARK: - Natural text measurement

    /// One hidden fixed-size Text per question, reporting its single-line
    /// width through a preference. Lives in a `.background` so it never
    /// affects the strip's layout; hit-testing is disabled and it is fully
    /// transparent, so it neither paints nor intercepts.
    private var naturalWidthMeasurements: some View {
        HStack(spacing: 0) {
            ForEach(questions) { question in
                Text(question.text)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .fixedSize()
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: TooltipWidthKey.self,
                                value: [question.id: geo.size.width]
                            )
                        }
                    )
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Per-question natural text widths from the offscreen measurement row.
private struct TooltipWidthKey: PreferenceKey {
    nonisolated static var defaultValue: [UUID: CGFloat] { [:] }
    nonisolated static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - AppKit hover tracking

/// An NSView filling the timeline strip that forwards pointer position through
/// NSTrackingArea — the canonical macOS hover mechanism. SwiftUI's
/// `onHover`/`onContinuousHover` dropped re-entry events in this context
/// (NSPanel + NSHostingView + overlays + opacity changes), which left the
/// timeline stuck dimmed; tracking areas do not.
private struct HoverTrackingStrip: NSViewRepresentable {
    /// Pointer Y in the strip's coordinate space (bottom-up), nil on exit.
    let onMove: (CGFloat?) -> Void
    /// Click Y — the whole strip is tappable, gaps included.
    let onClick: (CGFloat) -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onMove = onMove
        view.onClick = onClick
        view.setAccessibilityLabel("Question timeline")
        return view
    }

    func updateNSView(_ view: TrackingNSView, context: Context) {
        view.onMove = onMove
        view.onClick = onClick
    }
}

private final class TrackingNSView: NSView {
    var onMove: ((CGFloat?) -> Void)?
    var onClick: ((CGFloat) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // .inVisibleRect keeps the area synced to bounds changes; .activeAlways
        // tracks even while the floating panel is not key.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { forward(event) }
    override func mouseMoved(with event: NSEvent) { forward(event) }
    override func mouseDragged(with event: NSEvent) { forward(event) }

    override func mouseExited(with event: NSEvent) {
        onMove?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(topDownY(of: event))
    }

    /// SwiftUI math above treats the strip top-down (bar centers at
    /// `rowHeight/2 + i * pitch` from the TOP); NSView reports bottom-up, so
    /// flip Y here once at the boundary.
    private func topDownY(of event: NSEvent) -> CGFloat {
        bounds.height - convert(event.locationInWindow, from: nil).y
    }

    private func forward(_ event: NSEvent) {
        onMove?(topDownY(of: event))
    }
}
