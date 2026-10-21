import SwiftUI

/// Right-edge question timeline: one rounded bar per user question, floating
/// vertically centered over the transcript's trailing edge. Hover magnifies
/// the bar and pops a thumbnail of that question's text; clicking jumps the
/// transcript to the question (same `ScrollViewReader` anchor the find bar
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

    @State private var hovered: UUID?
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { Theme.color(accentHex) }

    var body: some View {
        VStack(spacing: gap) {
            ForEach(questions) { question in
                markerRow(question)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
        // A quiet rail behind the bars: wide user bubbles can reach the
        // trailing gutter, and a bare 25%-opacity bar legibility would depend
        // on what happened to sit under it. The rail fixes the contrast in
        // both appearances and reads as an intentional affordance.
        .background(
            (scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
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

    private func markerRow(_ question: ChatMessage) -> some View {
        let hoveredHere = hovered == question.id
        return ZStack(alignment: .trailing) {
            Capsule()
                .fill(
                    hoveredHere
                        ? AnyShapeStyle(accent)
                        : AnyShapeStyle(Color.primary.opacity(scheme == .dark ? 0.28 : 0.38))
                )
                .frame(width: hoveredHere ? 22 : 14, height: hoveredHere ? 5 : 3)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        }
        .frame(width: 24, height: 14)
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

    /// The question's first lines, floating to the LEFT of the bars. An
    /// overlay, so it never widens the hover strip or shifts the column.
    private func thumbnail(_ question: ChatMessage) -> some View {
        let dark = scheme == .dark
        return Text(question.text)
            .font(.system(size: 11.5))
            .foregroundStyle(dark ? Theme.color("#f5f5f7") : Theme.color("#1d1d1f"))
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: 240, alignment: .leading)
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
}
