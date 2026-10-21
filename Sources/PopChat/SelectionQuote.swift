import Foundation

/// P2 "ask about selection": the blockquote the composer is prefilled with when
/// the Services handler (`askWithSelection`) hands PopChat text selected in
/// another app. A pure function so the format is smoke-testable without GUI —
/// the Services plumbing around it can't be driven headlessly.
enum SelectionQuote {
    /// Markdown blockquote of the selection: every line prefixed "> " (blank
    /// lines become a bare ">" so the quote stays one continuous block),
    /// followed by ONE blank line so the user's question starts below the
    /// quote with the caret already there. Outer whitespace is trimmed —
    /// editor selections routinely carry a trailing newline, which would
    /// otherwise open with an empty quote line. Inner content (indentation
    /// included) is preserved verbatim. Returns "" for blank input; the
    /// handler then shows the panel WITHOUT prefilling rather than injecting
    /// an empty quote.
    static func quote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let quoted = trimmed
            .components(separatedBy: "\n")
            .map { line in
                line.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> " + line
            }
            .joined(separator: "\n")
        return quoted + "\n\n"
    }
}
