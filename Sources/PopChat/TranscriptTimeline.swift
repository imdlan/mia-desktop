import SwiftUI

/// Right-edge question timeline: one rounded bar per user question, floating
/// vertically centered over the transcript's trailing edge. Hovering magnifies
/// bars Dock-style (right edges stay aligned, bars grow leftward, neighbors
/// taper with distance) and pops a thumbnail of that question's text; clicking
/// jumps the transcript to the question (same `ScrollViewReader` anchor the
/// find bar uses). Hidden below two questions — a single-question timeline is
/// noise.
///
/// The bars live in the trailing margin the bubbles never enter (bubble max
/// width is 78% of the transcript), so the hover strip never blocks content.
/// The view re-evaluates on every stream tick like the rest of the overlay
/// chrome; it renders a handful of capsules and no text while idle, so it
/// stays out of the row-repaint budget the Equatable-gated rows own.
struct TranscriptTimeline: View {
    let questions: [ChatMessage]
    /// Jump callback — ChatView owns the `ScrollViewReader` proxy.
    let onJump: (UUID) -> Void

    @State private var hovered: UUID?
    /// Natural single-line width of each question's text, measured offscreen.
    /// The tooltip needs this because an overlay proposes its CONTAINER's
    /// width — 24pt — to the bubble, which would wrap the text vertically.
    @State private var naturalWidths: [UUID: CGFloat] = [:]

    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { Theme.color(accentHex) }

    var body: some View {
        VStack(spacing: gap) {
            ForEach(questions.indices, id: \.self) { index in
                markerRow(questions[index], index: index)
            }
        }
        .animation(magnifyAnimation, value: hovered)
        .background(naturalWidthMeasurements)
        .onPreferenceChange(TooltipWidthKey.self) { naturalWidths = $0 }
    }

    /// Dock-style spring; instant for Reduce Motion.
    private var magnifyAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7)
    }

    // MARK: - Layout

    /// Spacing between bars, compressed as the count grows so the column stays
    /// within ~300pt even for long conversations.
    private var gap: CGFloat {
        let count = questions.count
        guard count > 1 else { return 6 }
        let needed = CGFloat(count) * 3 + CGFloat(count - 1) * 6
        guard needed > 300 else { return 6 }
        return max(1, (300 - CGFloat(count) * 3) / CGFloat(count - 1))
    }

    // MARK: - One bar + its hover chrome

    private var hoveredIndex: Int? {
        hovered.flatMap { id in questions.firstIndex { $0.id == id } }
    }

    /// Dock falloff: the hovered bar is widest, its ±1 neighbors taper halfway,
    /// ±2 taper a quarter, everything else stays idle. All bars keep their
    /// RIGHT edges on one vertical axis (`.trailing` alignment below), so
    /// growth always extends leftward.
    private func magnification(for index: Int) -> CGFloat {
        guard let hoveredIndex else { return 0 }
        let distance = abs(index - hoveredIndex)
        return max(0, 1 - CGFloat(distance) / 3)
    }

    private func markerRow(_ question: ChatMessage, index: Int) -> some View {
        let magnify = magnification(for: index)
        let hoveredHere = hovered == question.id
        return ZStack(alignment: .trailing) {
            Capsule()
                .fill(hoveredHere ? AnyShapeStyle(accent) : AnyShapeStyle(barColor))
                // 14→22pt wide, 3→5pt tall at full magnification.
                .frame(
                    width: 14 + 8 * magnify,
                    height: 3 + 2 * magnify
                )
                .animation(magnifyAnimation, value: hovered)
        }
        // The fixed row frame is what keeps the column's height stable while
        // bar heights animate inside it — no jitter for the neighbors.
        .frame(width: 24, height: 14, alignment: .trailing)
        .overlay(alignment: .trailing) {
            if hoveredHere {
                thumbnail(question)
                    .offset(x: -32)
                    .transition(reduceMotion
                        ? AnyTransition.opacity
                        : AnyTransition.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .contentShape(Rectangle())
        .onHover { entering in
            if entering {
                hovered = question.id
            } else if hovered == question.id {
                hovered = nil
            }
        }
        .onTapGesture {
            onJump(question.id)
            hovered = nil
        }
    }

    /// Idle bar color, slightly stronger per appearance to hold its own over
    /// the glass panel now that there is no rail behind it.
    private var barColor: Color {
        Color.primary.opacity(scheme == .dark ? 0.30 : 0.42)
    }

    /// The question's first lines, floating to the LEFT of the bars. Width is
    /// the measured natural single-line width clamped to 240 — with a 2-line
    /// fallback for long questions — so the bubble never wraps inside the
    /// strip's 24pt proposal and never grows past a readable width.
    private func thumbnail(_ question: ChatMessage) -> some View {
        let natural = naturalWidths[question.id] ?? 240
        let width = min(natural + 4, 240)
        let dark = scheme == .dark
        return Text(question.text)
            .font(.system(size: 11.5))
            .foregroundStyle(dark ? Theme.color("#f5f5f7") : Theme.color("#1d1d1f"))
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(width: width, alignment: .leading)
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
