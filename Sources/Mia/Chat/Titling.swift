import Foundation

/// P3 auto-naming: after a conversation's first real reply, ask the current
/// provider once for a short title. Everything decidable offline — the prompt,
/// the request wire shape, the guard laws, the result cleanup — lives here as
/// pure functions; only the one-shot network call (`fetchTitle`) touches the
/// wire, and only for `.openAICompatible` providers (see `shouldTitle`).
enum Titling {
    /// ≤6 words is the request; the enforcement that matters (no quotes, no
    /// trailing punctuation) is stated because models ignore word limits far
    /// less reliably than formatting rules — and `sanitize` backstops both.
    static let systemPrompt = """
    You name chat conversations. Reply with ONLY a title for the user's \
    message: at most 6 words, no quotes, no trailing punctuation, no preamble \
    or explanation.
    """

    /// First-user-message truncation guard. The title only has to identify
    /// the topic; anything past this is tokens spent on nothing.
    static let maxInputLength = 500

    /// The longest title kept. Matches the derived-title convention
    /// (`ChatStore.title(for:)`): 40 characters, "…" appended when cut.
    static let maxTitleLength = 40

    /// The exact messages of a naming request: one system instruction, one
    /// user message carrying (a bounded slice of) the first prompt. A fresh
    /// conversation, deliberately — sending the transcript would cost more
    /// than the answer it could improve.
    static func requestMessages(firstUserText: String) -> [OpenAIChatClient.WireMessage] {
        let trimmed = firstUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = trimmed.count > maxInputLength ? String(trimmed.prefix(maxInputLength)) : trimmed
        return [
            OpenAIChatClient.WireMessage(role: "system", content: .text(systemPrompt)),
            OpenAIChatClient.WireMessage(role: "user", content: .text("Name this conversation:\n\n" + capped)),
        ]
    }

    /// The whole trigger decision as one pure law, so the "at most once, only
    /// while the title is still the derived default, only after a real answer,
    /// only where a cheap standalone call exists" contract is assertable
    /// offline (`--smoke-titling`). `chatGPT` (OAuth adapter) and
    /// `codexAppServer` (a driven interactive turn) have no cheap one-shot
    /// request path, so those kinds are silently skipped — a missing title
    /// never beats a broken turn.
    static func shouldTitle(
        enabled: Bool,
        hasCustomTitle: Bool,
        alreadyAttempted: Bool,
        producedAnswer: Bool,
        kind: ProviderKind
    ) -> Bool {
        enabled && !hasCustomTitle && !alreadyAttempted && producedAnswer && kind == .openAICompatible
    }

    /// Model output → display title. Quotes are stripped wherever they appear
    /// (models wrap despite the prompt), newlines flatten to spaces, whitespace
    /// runs collapse, and anything past 40 characters is cut with the same "…"
    /// convention the derived titles use. Empty in, empty out — the caller
    /// treats that as "no title" and leaves the derived default alone.
    static func sanitize(_ raw: String) -> String {
        let quotes: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "「", "」", "『", "』"]
        let flattened = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        var title = String(flattened.filter { !quotes.contains($0) })
        title = title.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !title.isEmpty else { return "" }
        if title.count > maxTitleLength {
            let cut = String(title.prefix(maxTitleLength)).trimmingCharacters(in: .whitespaces)
            title = cut + "…"
        }
        return title
    }

    // MARK: - One-shot request

    /// The chat-completions body for a naming call: non-streaming, max_tokens
    /// 24, temperature 0. Built as a dictionary for the same reason
    /// `OpenAIChatClient.streamOneRound` does it — typed messages mixed with
    /// plain schema values. Pure so the wire contract itself is assertable.
    static func requestBody(model: String, messages: [OpenAIChatClient.WireMessage]) throws -> [String: Any] {
        [
            "model": model,
            "stream": false,
            "max_tokens": 24,
            "temperature": 0,
            "messages": try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages)),
        ]
    }

    /// One naming call. Same URL/auth conventions as the streaming client
    /// (`chat/completions` appended to the base URL, Bearer when a key
    /// exists), but a plain non-streaming POST — the agentic streaming loop
    /// drags in tools, reasoning assembly and SSE parsing that a 6-word
    /// answer will never use. Throws on transport/HTTP/decode failure; the
    /// one caller swallows everything silently by design.
    static func fetchTitle(messages: [OpenAIChatClient.WireMessage], config: ProviderConfig) async throws -> String {
        guard var url = URL(string: config.baseURL) else {
            throw NSError(domain: "Titling", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid base URL: \(config.baseURL)"])
        }
        url.append(path: "chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // A title is a few hundred bytes either way; a stalled endpoint must
        // not hold the slot open for the streaming turn's 300s budget.
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(model: config.model, messages: messages))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Titling", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"])
        }

        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { var content: String? }
                var message: Message
            }
            var choices: [Choice]
        }
        return try JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content ?? ""
    }
}
