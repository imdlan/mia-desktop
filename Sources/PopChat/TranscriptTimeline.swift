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
/// The bars live in the trailing margin the bubbles never enter (bubble max
/// width is 78% of the transcript), so the hover strip never blocks content.
/// The view re-evaluates on every stream tick like the rest of the overlay
/// chrome; it renders a handful of capsules and no text while idle, so it
/// stays out of the row-repaint budget the Equatable-gated rows own.
struct TranscriptTimeline: View {
    let questions: [ChatMessage]
    /// Jump callback — ChatView owns the `ScrollViewReader` proxy.
    let onJump: (UUID) -> Void

    /// Pointer Y inside the column, nil while the pointer is elsewhere.
    @State private var pointerY: CGFloat?
    /// The bar nearest the pointer — owns the tooltip and the accent tint.
    @State private var hovered: UUID?
    /// Resting state: 2s after the pointer leaves, the whole column fades to
    /// 40% so a bright affordance doesn't sit permanently in the margin.
    @State private var dimmed = false
    @State private var dimTask: Task<Void, Never>?
    /// Natural single-line width of each question's text, measured offscreen.
    /// The tooltip needs this because an overlay proposes its CONTAINER's
    /// width — 24pt — to the bubble, which would wrap the text vertically.
    @State private var naturalWidths: [UUID: CGFloat] = [:]

    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { Theme.color(accentHex) }

    /// Layout metrics shared by hover math and marker layout.
    private var rowPitch: CGFloat { 14 + gap }
    private var columnHeight: CGFloat {
        CGFloat(questions.count) * 14 + CGFloat(questions.count - 1) * gap
    }

    var body: some View {
        VStack(spacing: gap) {
            ForEach(questions.indices, id: \.self) { index in
                markerRow(questions[index], index: index)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                // Direct assignment — the widths are already continuous in the
                // pointer position, so tracking needs no animation (animating
                // each event is what made the bars seesaw).
                pointerY = location.y
                hovered = nearestQuestion(at: location.y)
                wake()
            case .ended:
                // Springy collapse when the pointer leaves the strip.
                withAnimation(magnifyAnimation) {
                    pointerY = nil
                    hovered = nil
                }
                sleepThenDim()
            @unknown default:
                break
            }
        }
        .opacity(dimmed ? 0.4 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: dimmed)
        .overlay(alignment: .trailing) {
            if let index = hoveredIndex {
                thumbnail(questions[index])
                    // Slide between bars as the nearest one changes.
                    .offset(x: -32, y: tooltipOffsetY(index))
                    .transition(reduceMotion
                        ? AnyTransition.opacity
                        : AnyTransition.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                    .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: hovered)
            }
        }
        .background(naturalWidthMeasurements)
        .onPreferenceChange(TooltipWidthKey.self) { naturalWidths = $0 }
    }

    /// Dock-style spring; instant for Reduce Motion.
    private var magnifyAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7)
    }

    /// Full opacity on entry; dims back after 2s of the pointer being away.
    private func wake() {
        dimTask?.cancel()
        dimTask = nil
        dimmed = false
    }

    private func sleepThenDim() {
        dimTask?.cancel()
        dimTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            dimmed = true
        }
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

    // MARK: - Continuous magnification

    private var hoveredIndex: Int? {
        hovered.flatMap { id in questions.firstIndex { $0.id == id } }
    }

    private func nearestQuestion(at y: CGFloat) -> UUID {
        let index = min(max(0, Int((y - 7).rounded() / rowPitch)), questions.count - 1)
        return questions[index].id
    }

    /// Vertical offset that centers the tooltip on the hovered bar, relative
    /// to the column's vertical center (the overlay's `.trailing` anchor).
    private func tooltipOffsetY(_ index: Int) -> CGFloat {
        let barCenter = 7 + CGFloat(index) * rowPitch
        return barCenter - columnHeight / 2
    }

    /// Dock falloff from the pointer's distance to each bar's center: full
    /// magnification at the bar, smooth (smoothstep) taper across ~2 rows.
    /// Reduce Motion keeps every bar idle-sized; the hovered one still tints.
    private func magnification(for index: Int) -> CGFloat {
        guard let pointerY, !reduceMotion else { return 0 }
        let distance = abs(pointerY - (7 + CGFloat(index) * rowPitch))
        let t = max(0, 1 - distance / 30)
        return t * t * (3 - 2 * t)
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
        }
        // The fixed row frame is what keeps the column's height stable while
        // bar heights animate inside it — no jitter for the neighbors.
        .frame(width: 24, height: 14, alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture {
            onJump(question.id)
        }
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
    /// wrapped two-character questions).
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
