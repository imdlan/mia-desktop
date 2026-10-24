import Foundation

/// P1 conversation export: Markdown for reading, JSON for backup/migration.
/// Pure functions over already-resolved `Conversation`s — the history popover's
/// panels and the `--smoke-export` harness share them, so the byte format is
/// verifiable without a GUI. History pruning is silent (`maxStored`), which is
/// why this exists at all: the transcript must be able to leave the app.
enum ConversationExport {
    /// POSIX locale + a fixed pattern: the harness asserts exports against a
    /// golden string, so the stamp must never vary with the user's locale.
    /// (DateFormatter has been thread-safe since macOS 10.9, so one cached
    /// instance serves the Export All background write too.)
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// Reasoning renders behind a collapsed disclosure in the app; a
    /// blockquote keeps it visually secondary in the file too. Shared by the
    /// conversation and single-reply exports so the shape cannot drift.
    private static func reasoningBlock(_ reasoning: String) -> String {
        let quoted = reasoning
            .components(separatedBy: "\n")
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        return "> *Reasoning:*\n\(quoted)"
    }

    /// Title header, export stamp, then one block per message separated by
    /// blank lines. Message bodies are the stored markdown, verbatim — fenced
    /// code blocks survive because nothing here reflows them.
    static func markdown(conversation: Conversation, exportedAt: Date = Date()) -> String {
        let header = "# \(conversation.title)\n*Exported from Mia · "
            + stampFormatter.string(from: exportedAt) + "*"
        var blocks: [String] = []
        for message in conversation.messages {
            switch message.role {
            case .user:
                blocks.append("**You:**\n\n\(message.text)")
            case .assistant:
                var block = "**Assistant:**"
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    block += "\n\n" + reasoningBlock(reasoning)
                }
                block += "\n\n\(message.text)"
                blocks.append(block)
            case .error, .activity:
                // UI-only rows: kept for fidelity, demoted to an italic note.
                blocks.append("*\(message.text)*")
            }
        }
        return header + "\n\n" + blocks.joined(separator: "\n\n") + "\n"
    }

    /// One assistant reply, standalone: the conversation export's header shape
    /// and reasoning blockquote, then the reply verbatim — for the footer
    /// Export action, which points at a single message, not a whole chat.
    static func replyMarkdown(
        text: String,
        reasoning: String?,
        conversationTitle: String,
        exportedAt: Date = Date()
    ) -> String {
        let header = "# Reply — \(conversationTitle)\n*Exported from Mia · "
            + stampFormatter.string(from: exportedAt) + "*"
        var body = ""
        if let reasoning, !reasoning.isEmpty {
            body = reasoningBlock(reasoning) + "\n\n"
        }
        return header + "\n\n" + body + text + "\n"
    }

    /// The store's own on-disk encoding (JSONEncoder + iso8601), so a resolved
    /// export is byte-compatible with a stored conversation file and can be
    /// dropped back in as a backup.
    static func json(conversation: Conversation) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(conversation)
    }

    /// `<title slug>`: lowercased, non-alphanumerics → dashes, collapsed to
    /// single dashes. Shared by the conversation and reply file-name bases.
    private static func slug(_ title: String) -> String {
        let dashed = String(title.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return dashed.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    }

    /// Default file-name base: `<title slug>-<first 6 of the id>`. Readable
    /// AND unique — an export folder full of same-titled chats (and the forks
    /// sharing a prefix) must never overwrite each other.
    static func filenameBase(for conversation: Conversation) -> String {
        let base = slug(conversation.title)
        return (base.isEmpty ? "conversation" : base)
            + "-" + String(conversation.id.uuidString.prefix(6))
    }

    /// Reply file-name base: `<title slug>-reply-<first 6 of the message id>`,
    /// the same readable-AND-unique contract; "reply" when the title slugs
    /// away to nothing.
    static func replyFilenameBase(conversationTitle: String, messageID: UUID) -> String {
        let base = slug(conversationTitle)
        return (base.isEmpty ? "reply" : base + "-reply")
            + "-" + String(messageID.uuidString.prefix(6))
    }

    /// The Export All payload: one `<slug>.md` per conversation plus a merged
    /// `conversations.json` holding the full resolved array. File I/O lives
    /// here (not in the popover) so the summary the UI reports is the same
    /// outcome the write loop measured.
    static func exportAll(conversations: [Conversation], to directory: URL) -> (written: Int, failed: Int) {
        var written = 0
        var failed = 0
        for conversation in conversations {
            let body = Data(markdown(conversation: conversation).utf8)
            do {
                try body.write(
                    to: directory.appendingPathComponent(filenameBase(for: conversation) + ".md"),
                    options: [.atomic]
                )
                written += 1
            } catch {
                failed += 1
            }
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(conversations).write(
                to: directory.appendingPathComponent("conversations.json", isDirectory: false),
                options: [.atomic]
            )
        } catch {
            failed += 1
        }
        return (written, failed)
    }
}
