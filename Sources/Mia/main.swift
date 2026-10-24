import AppKit
import SwiftUI
import MiaBundleShim
import KeyboardShortcuts
import SwiftMath

// First, before any dependency can touch its resources: inside the .app, the SPM
// dependencies' Bundle.module would otherwise trap (see MiaBundleShim.m).
MiaInstallResourceBundleRedirect()

// One-time migration from the PopChat era (pre-rename bundle ID/data dir),
// before anything reads settings, secrets or conversations. Only on a real
// app launch: the harness invocations below (any "--" flag) run against
// scratch fixtures, while this call's defaults are the REAL user domain —
// running it from a harness would migrate the developer's actual data.
if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) {
    BrandMigration.migrate()
}

// Headless streaming checks (no UI):
//   MIA_API_KEY=… .build/debug/Mia --smoke          plain streaming
//   MIA_API_KEY=… .build/debug/Mia --smoke-search   agentic loop w/ DuckDuckGo
let smokePlain = CommandLine.arguments.contains("--smoke")
let smokeSearch = CommandLine.arguments.contains("--smoke-search")
// Verifies the default system prompt actually elicits <pasteable> blocks.
let smokePasteable = CommandLine.arguments.contains("--smoke-pasteable")
if smokePlain || smokeSearch || smokePasteable {
    Task {
        let env = ProcessInfo.processInfo.environment
        let config = ProviderConfig(
            baseURL: env["MIA_BASE_URL"] ?? ProviderConfig.defaultBaseURL,
            apiKey: env["MIA_API_KEY"] ?? "",
            model: env["MIA_MODEL"] ?? ProviderConfig.defaultModel
        )
        let prompt = smokeSearch
            ? "What is the latest stable release version of the Zed editor? Use web_search to check — do not answer from memory. Reply with just the version number and the source URL."
            : smokePasteable
                ? "Give me a reusable conventional-commit message template for bug fixes, ready to copy."
                : "Reply with exactly: Mia streaming OK"
        print("smoke: \(config.baseURL) model=\(config.model) search=\(smokeSearch) pasteable=\(smokePasteable)")
        var chunks = 0
        var reasoningChars = 0
        var history = [OpenAIChatClient.WireMessage(role: "user", content: .text(prompt))]
        if smokePasteable {
            history.insert(
                OpenAIChatClient.WireMessage(role: "system", content: .text(ChatStore.defaultSystemPrompt)),
                at: 0
            )
        }
        for await event in OpenAIChatClient.run(
            history: history,
            config: config,
            webAccess: smokeSearch ? .localTools(.duckduckgo) : nil
        ) {
            switch event {
            case .partial:
                chunks += 1
            case .usage:
                break
            case .activity(let text):
                print("[activity] \(text)")
            case .status(let text):
                print("[status] \(text)")
            case .reasoning(let text):
                reasoningChars = text.count
            case .done(let text):
                print("chunks=\(chunks) reasoningChars=\(reasoningChars)\nfinal=\(text)")
                if smokePasteable {
                    let blocks = MarkdownRenderer.segments(text).compactMap { segment -> String? in
                        if case .pasteable(let title, let content) = segment {
                            return "title=\(title ?? "-") chars=\(content.count)"
                        }
                        return nil
                    }
                    print("pasteableBlocks=\(blocks.count) \(blocks.joined(separator: " | "))")
                    exit(blocks.isEmpty ? 1 : 0)
                }
                exit(text.isEmpty ? 1 : 0)
            case .error(let message):
                print("ERROR: \(message)")
                exit(1)
            case .contentRejected(let capability, let message):
                print("ERROR (\(capability.rawValue) rejected): \(message)")
                exit(1)
            }
        }
        exit(1)
    }
    RunLoop.main.run()
}

// Typewriter pacing (no network, no UI): replays the drain's step law against a
// synthetic fast provider. Guards the invariant that regressed once — while the
// answer is still arriving the reveal must run at a fixed rate and FALL BEHIND;
// a backlog-proportional step settles at reveal-rate == arrival-rate, which made
// "Per-character" render identically to "By chunk".
if CommandLine.arguments.contains("--smoke-typewriter") {
    // (total chars, provider chars/sec, max seconds the reveal may trail arrival)
    let cases: [(total: Int, arrival: Double, slack: Double)] = [
        (600, 900, 8), (3_000, 900, 10), (20_000, 1_500, 12),
    ]
    var failures: [String] = []
    for probe in cases {
        let arrivalMs = Int(Double(probe.total) / probe.arrival * 1000)
        var revealed = 0, elapsed = 0, revealedAtArrival = -1
        while revealed < probe.total, elapsed < 300_000 {
            if revealedAtArrival < 0, elapsed >= arrivalMs { revealedAtArrival = revealed }
            let arrived = min(probe.total, Int(probe.arrival * Double(elapsed) / 1000))
            let backlog = arrived - revealed
            if backlog > 0 {
                revealed += ChatStore.typewriterStep(
                    backlog: backlog,
                    interval: ChatStore.typewriterInterval(forLength: arrived),
                    finished: elapsed >= arrivalMs
                )
            }
            elapsed += ChatStore.typewriterInterval(forLength: arrived)
        }
        if revealedAtArrival < 0 { revealedAtArrival = revealed }
        let trail = Double(elapsed - arrivalMs) / 1000
        // THE assertion: how fast text appeared while the model was still producing.
        // Not the tail — the old backlog/12 catch-up also kept typing ~1s past the
        // end, yet during the answer it ran at the provider's rate, which is exactly
        // what made it look like .byChunk. Anything near the arrival rate is a mirror,
        // not a typewriter. (A short answer can pass this trivially: it ends before
        // the lag has room to build. The 3k/20k probes are the ones that discriminate.)
        let displayRate = Double(revealedAtArrival) / (Double(arrivalMs) / 1000)
        let paced = displayRate <= probe.arrival * 0.75
        let bounded = revealed == probe.total && trail <= probe.slack
        print(String(format: "%6d chars @%.0f/s → arrival %.1fs, reveal %.1fs (trail %.1fs), shown while streaming %.0f chars/s %@",
                     probe.total, probe.arrival, Double(arrivalMs) / 1000, Double(elapsed) / 1000,
                     trail, displayRate, paced && bounded ? "ok" : "BAD"))
        if !paced {
            failures.append(String(format: "%d: reveal mirrors arrival (%.0f of %.0f chars/s)",
                                   probe.total, displayRate, probe.arrival))
        }
        if !bounded { failures.append("\(probe.total): reveal trails \(trail)s / revealed \(revealed)") }
    }
    // Delta 4 / 6b: the per-sentence commit law. Replays the same synthetic
    // provider through ChatStore.sentenceCommitLength and checks the three things
    // the mode promises — commits land on sentence boundaries, never inside an
    // open code fence, and are paced (≥140 ms apart while arriving, ≥60 ms after)
    // without blowing the 6 s drain ceiling on a long answer.
    let unit = """
    Margins held through Q2, but two suppliers now carry most of the risk. Acme and \
    Delta both feed final assembly, so a stall at either blocks shipments.

    Here is the check:

    ```swift
    let ratio = 1.5 // note. a period mid-fence, and no boundary may land here
    print(ratio)
    ```

    I'd dual-source the top parts before Q3. That is the whole recommendation!

    """

    /// Independent of the implementation: is `index` a legal commit point?
    func isBoundary(_ chars: [Character], _ index: Int) -> Bool {
        if index == chars.count { return true }
        guard index > 0 else { return false }
        let prev = chars[index - 1]
        if prev == "\n" { return true }
        if prev == "." || prev == "!" || prev == "?" { return chars[index].isWhitespace }
        return false
    }

    /// Number of ``` fence lines before `index` — odd means the fence is open.
    func fencesBefore(_ chars: [Character], _ index: Int) -> Int {
        var count = 0, i = 0, atLineStart = true
        while i < index {
            if atLineStart, chars[i...].starts(with: ["`", "`", "`"]) { count += 1 }
            atLineStart = chars[i] == "\n"
            i += 1
        }
        return count
    }

    // The third probe ends INSIDE a fence the model never closed: no boundary is
    // legal there, so the drain must still finish rather than spin — and the
    // streamTask tail awaits that drain, so spinning would hang the turn.
    for probe in [(copies: 1, arrival: 900.0, truncated: false),
                  (copies: 24, arrival: 1_500.0, truncated: false),
                  (copies: 1, arrival: 900.0, truncated: true)] {
        var reply = String(repeating: unit, count: probe.copies)
        if probe.truncated { reply += "```swift\nlet unfinished = " }
        let chars = Array(reply)
        let arrivalMs = Int(Double(chars.count) / probe.arrival * 1000)
        var revealed = 0, elapsed = 0, sinceCommit = Int.max
        var commits: [(at: Int, gap: Int, finished: Bool)] = []
        while revealed < chars.count, elapsed < 300_000 {
            let arrived = min(chars.count, Int(probe.arrival * Double(elapsed) / 1000))
            let finished = elapsed >= arrivalMs
            let gap = finished ? ChatStore.sentenceTailGapMs : ChatStore.sentenceGapMs
            if revealed < arrived, sinceCommit >= gap {
                let commit = ChatStore.sentenceCommitLength(
                    in: String(chars.prefix(arrived)), revealed: revealed, finished: finished
                )
                if commit > revealed {
                    commits.append((at: commit, gap: sinceCommit, finished: finished))
                    revealed = commit
                    sinceCommit = 0
                }
            }
            let interval = ChatStore.typewriterInterval(forLength: max(arrived, 1))
            sinceCommit = sinceCommit >= Int.max - interval ? Int.max : sinceCommit + interval
            elapsed += interval
        }

        let offBoundary = commits.filter { !isBoundary(chars, $0.at) }
        // End-of-text is exempt: a finished reply must commit even if the model
        // left a fence open.
        let inFence = commits.filter { $0.at < chars.count && fencesBefore(chars, $0.at) % 2 == 1 }
        // The SPEC's numbers, deliberately literal: the loop above is driven by
        // ChatStore's constants, so asserting against those same constants would
        // be tautological — retuning them has to fail here.
        let tooEager = commits.dropFirst().filter { $0.gap < ($0.finished ? 60 : 140) }
        let trail = Double(elapsed - arrivalMs) / 1000
        let ok = offBoundary.isEmpty && inFence.isEmpty && tooEager.isEmpty
            && revealed == chars.count && trail <= 7
        print(String(format: "%6d chars @%.0f/s → %d commits, arrival %.1fs, reveal %.1fs (trail %.1fs) %@",
                     chars.count, probe.arrival, commits.count, Double(arrivalMs) / 1000,
                     Double(elapsed) / 1000, trail, ok ? "ok" : "BAD"))
        if let bad = offBoundary.first {
            let around = String(chars[max(0, bad.at - 12)..<min(chars.count, bad.at + 4)])
            failures.append("sentence: commit at \(bad.at) is mid-sentence (…\(around.debugDescription))")
        }
        if let bad = inFence.first { failures.append("sentence: commit at \(bad.at) is inside an open code fence") }
        if let bad = tooEager.first { failures.append("sentence: commit only \(bad.gap)ms after the previous one") }
        if revealed != chars.count { failures.append("sentence: revealed \(revealed)/\(chars.count)") }
        if trail > 7 { failures.append(String(format: "sentence: reveal trails arrival by %.1fs", trail)) }
    }

    // Delta 4 / 6a: the fade ramp is a spatial function of the drain's step, so
    // it must cover the head, stay monotonic towards opaque, and never extend
    // past what has actually been revealed.
    let ramp = TextReveal.ramp(head: 48)
    let covered = ramp.stops.reduce(0) { $0 + $1.length }
    let monotonic = zip(ramp.stops, ramp.stops.dropFirst()).allSatisfy { $0.alpha < $1.alpha }
    print("fade ramp: \(ramp.stops.count) bands over \(covered) chars, "
          + String(format: "alpha %.2f→%.2f %@", ramp.stops.first?.alpha ?? -1,
                   ramp.stops.last?.alpha ?? -1, covered == 48 && monotonic ? "ok" : "BAD"))
    if covered != 48 { failures.append("fade ramp covers \(covered) of 48 chars") }
    if !monotonic { failures.append("fade ramp alphas are not monotonic toward opaque") }
    if TextReveal.ramp(head: 0).stops.isEmpty == false { failures.append("fade ramp with no head is not empty") }

    // And that the ramp lands on the right characters when painted: the tail
    // fades, the settled text keeps its ORIGINAL attributes (so it can't drift
    // off the dynamic system colors), and the caret glyph stays solid.
    let sample = NSMutableAttributedString(
        string: String(repeating: "x", count: 60) + "▍",
        attributes: [.foregroundColor: NSColor.labelColor]
    )
    let painted = RevealFade.paint(sample, reveal: TextReveal(stops: ramp.stops, trailingSkip: 1))
    func alpha(at index: Int) -> CGFloat {
        (painted.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)?.alphaComponent ?? -1
    }
    let settled = painted.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    let caretColor = painted.attribute(.foregroundColor, at: 60, effectiveRange: nil) as? NSColor
    // Note labelColor is itself 85% opaque — the fade MULTIPLIES into whatever
    // alpha a run already had, so everything here is relative to that base.
    let base = NSColor.labelColor.alphaComponent
    let paintOK = settled === NSColor.labelColor       // untouched, not a copy
        && caretColor === NSColor.labelColor           // caret rides the head, never fades
        && alpha(at: 59) < base * 0.3                  // newest text is nearly invisible
        && alpha(at: 30) > alpha(at: 55)               // ramps toward opaque
    print(String(format: "fade paint: settled %@, caret %@, head %.2f, mid %.2f (base %.2f) %@",
                 settled === NSColor.labelColor ? "original" : "REWRITTEN",
                 caretColor === NSColor.labelColor ? "original" : "FADED",
                 alpha(at: 59), alpha(at: 30), base, paintOK ? "ok" : "BAD"))
    if !paintOK { failures.append("fade paint landed on the wrong characters") }

    print(failures.isEmpty ? "PASS" : "FAIL: " + failures.joined(separator: "; "))
    exit(failures.isEmpty ? 0 : 1)
}

// User-installed Codex app-server check (no UI, no model turn/quota use):
//   .build/debug/Mia --check-codex-app-server
if CommandLine.arguments.contains("--check-codex-app-server") {
    Task {
        do {
            let inspection = try await CodexAppServerClient.inspect(includeModels: true)
            print("codex=ready account=\(inspection.email ?? "?") plan=\(inspection.plan ?? "?")")
            print("models=\(inspection.models.joined(separator: ",")) default=\(inspection.defaultModel ?? "?")")
            let effortModels = inspection.models.compactMap { model -> String? in
                guard let efforts = inspection.supportedEfforts[model], !efforts.isEmpty else { return nil }
                return "\(model):\(efforts.joined(separator: "/"))"
            }
            print("efforts=\(effortModels.joined(separator: ","))")
            exit(0)
        } catch {
            print("CODEX-APP-SERVER-ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

// LIVE check that the globe toggle actually reaches Codex's own web_search —
// needs the user's real Codex, signed in. `web_search` is a config ENUM and
// Codex REFUSES TO START on an unknown variant, so a wrong value here breaks
// every turn rather than just search; probe A therefore fails loudly if the
// variant Mia sends stops being accepted. Probe B is the gate itself.
//   .build/debug/Mia --smoke-codex-app-server-search
if CommandLine.arguments.contains("--smoke-codex-app-server-search") {
    Task {
        func turn(webSearch: Bool, model: String) async -> (text: String, searched: Bool, emptyQuery: Bool, error: String?) {
            let config = ProviderConfig(baseURL: "", apiKey: "", model: model, kind: .codexAppServer)
            let history = [OpenAIChatClient.WireMessage(
                role: "user",
                content: .text("Search the web: what is the current stable version of Swift? Answer in one line.")
            )]
            var text = ""
            var searched = false
            var emptyQuery = false
            var failure: String?
            for await event in CodexAppServerClient.run(
                history: history, config: config, webSearch: webSearch, inactivityTimeout: 120
            ) {
                switch event {
                case .partial(let value), .done(let value): text = value
                case .usage: break
                case .activity(let value):
                    if value.contains("searched the web") {
                        searched = true
                        // A row ending in a bare colon is the started-time
                        // labeling bug: the begin event has no query.
                        if value.trimmingCharacters(in: .whitespaces).hasSuffix(":") { emptyQuery = true }
                    }
                case .status, .reasoning: break
                case .error(let value): failure = value
                case .contentRejected(_, let value): failure = value
                }
            }
            return (text, searched, emptyQuery, failure)
        }

        let model: String
        do {
            let inspection = try await CodexAppServerClient.inspect(includeModels: true)
            model = inspection.defaultModel ?? inspection.models.first ?? "gpt-5.1-codex"
        } catch {
            print("CODEX-APP-SERVER-ERROR: \(error.localizedDescription)")
            exit(1)
        }

        let on = await turn(webSearch: true, model: model)
        print("globe=on searched=\(on.searched) emptyQuery=\(on.emptyQuery) error=\(on.error ?? "none") text=\(on.text.prefix(120))")
        let off = await turn(webSearch: false, model: model)
        print("globe=off searched=\(off.searched) error=\(off.error ?? "none") text=\(off.text.prefix(120))")

        // Search FIRING is model-discretionary, so the pass condition is the
        // config being accepted (no error, an answer arrives) plus the gate
        // holding: with the globe off the tool must not exist to be called.
        // Any search row that DID fire must name its query.
        let passed = on.error == nil && !on.text.isEmpty && !on.emptyQuery
            && off.error == nil && !off.text.isEmpty
            && !off.searched
        print(passed ? "PASS" : "FAIL")
        exit(passed ? 0 : 1)
    }
    RunLoop.main.run()
}

// Deterministic transport regression harness. Pass a fake app-server executable
// (Tools/fake-codex-stream) that sends a delta before acknowledging turn/start,
// REPLAYS an item/completed, and fails mid-item with a willRetry error before
// re-delivering under a new item id. Laws, in order: the first partial must not
// wait for the turn/start acknowledgement; both completed items must survive;
// the replayed completion must not duplicate its item; the retryable error must
// drop the aborted in-flight partial (never glue the re-stream onto it) and
// surface a transient retry status instead of silence:
//   .build/debug/Mia --smoke-codex-app-server-streaming /path/to/fake-codex
if let flag = CommandLine.arguments.firstIndex(of: "--smoke-codex-app-server-streaming"),
   CommandLine.arguments.count > flag + 1 {
    let executable = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    Task {
        let started = Date()
        var firstPartialDelay: TimeInterval?
        var final = ""
        var failure: String?
        var sawAborted = false
        var sawGlued = false
        var sawRetryStatus = false
        var reasoning = ""
        let config = ProviderConfig(
            baseURL: "", apiKey: "", model: "fake-model",
            kind: .codexAppServer
        )
        let history = [OpenAIChatClient.WireMessage(role: "user", content: .text("stream"))]
        for await event in CodexAppServerClient.run(
            history: history,
            config: config,
            executableOverride: executable
        ) {
            switch event {
            case .partial(let text):
                if firstPartialDelay == nil { firstPartialDelay = Date().timeIntervalSince(started) }
                if text.contains("half-answer") { sawAborted = true }
                if text.contains("replacesC") { sawGlued = true }
                final = text
            case .usage:
                break
            case .done(let text):
                final = text
            case .status(let text):
                if text.localizedCaseInsensitiveContains("retrying") { sawRetryStatus = true }
            case .reasoning(let text):
                reasoning = text
            case .activity:
                break
            case .error(let message):
                failure = message
            case .contentRejected(_, let message):
                failure = message
            }
        }
        let delay = firstPartialDelay ?? .infinity
        let lead = Date().timeIntervalSince(started) - delay
        // Reasoning, all three laws in one string: the two summary PARTS of one
        // item stay separate thoughts (keyed by itemId alone they would run
        // together as "options.Now"), the raw-reasoning delta loses to the
        // summary, and the pre-retry thought was dropped like the answer half.
        let expectedReasoning = "Weighing options.\n\nNow answering."
        let reasoningOK = reasoning == expectedReasoning
        // final == exactly the three items: the replayed completion of B would
        // make it four, and the aborted "half-answer…" partial must have been
        // streamed (sawAborted) but dropped rather than glued to C (sawGlued).
        let passed = failure == nil && final == "A\n\nB\n\nC" && lead > 1.0
            && sawAborted && !sawGlued && sawRetryStatus && reasoningOK
        print(String(
            format: "first-partial=%.3fs lead=%.3fs aborted=%@ glued=%@ retry-status=%@ reasoning=%@ final=%@ %@",
            delay, lead,
            sawAborted ? "yes" : "no", sawGlued ? "yes" : "no", sawRetryStatus ? "yes" : "no",
            reasoning.replacingOccurrences(of: "\n", with: "\\n"),
            final.replacingOccurrences(of: "\n", with: "\\n"),
            passed ? "PASS" : "FAIL"
        ))
        if let failure { print("ERROR: \(failure)") }
        exit(passed ? 0 : 1)
    }
    RunLoop.main.run()
}

// A fake executable for this harness acknowledges setup, then stays silent after
// turn/start. The adapter must terminate it and surface the inactivity error:
//   .build/debug/Mia --smoke-codex-app-server-timeout /path/to/fake-codex
if let flag = CommandLine.arguments.firstIndex(of: "--smoke-codex-app-server-timeout"),
   CommandLine.arguments.count > flag + 1 {
    let executable = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    Task {
        let started = Date()
        var failure: String?
        let config = ProviderConfig(
            baseURL: "", apiKey: "", model: "fake-model",
            kind: .codexAppServer
        )
        let history = [OpenAIChatClient.WireMessage(role: "user", content: .text("stall"))]
        for await event in CodexAppServerClient.run(
            history: history,
            config: config,
            executableOverride: executable,
            inactivityTimeout: 0.25
        ) {
            if case .error(let message) = event { failure = message }
        }
        let elapsed = Date().timeIntervalSince(started)
        let passed = failure?.contains("stopped responding") == true && elapsed < 2
        print(String(format: "timeout=%.3fs %@ %@", elapsed, failure ?? "no error", passed ? "PASS" : "FAIL"))
        exit(passed ? 0 : 1)
    }
    RunLoop.main.run()
}

// Back-pressure regression. A fake executable that ACKNOWLEDGES setup and then
// stops draining its stdin must not be able to wedge Mia: the adapter blocks
// inside a large `thread/inject_items` write, and stop() — the watchdog's and the
// Stop button's only exit — must still be able to terminate the child. Holding a
// lock across that write made stop() block on the lock the blocked write owned,
// and this harness never returned:
//   .build/debug/Mia --smoke-codex-app-server-backpressure /path/to/fake-codex
if let flag = CommandLine.arguments.firstIndex(of: "--smoke-codex-app-server-backpressure"),
   CommandLine.arguments.count > flag + 1 {
    let executable = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    Task {
        let started = Date()
        var failure: String?
        let config = ProviderConfig(
            baseURL: "", apiKey: "", model: "fake-model",
            kind: .codexAppServer
        )
        // Well past a ~64 KB pipe buffer: one downscaled image attachment is
        // about this big, so any real conversation carrying one reaches here.
        let filler = String(repeating: "x", count: 20_000)
        var history: [OpenAIChatClient.WireMessage] = (0..<40).map { index in
            OpenAIChatClient.WireMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: .text(filler)
            )
        }
        history.append(OpenAIChatClient.WireMessage(role: "user", content: .text("go")))
        for await event in CodexAppServerClient.run(
            history: history,
            config: config,
            executableOverride: executable,
            inactivityTimeout: 0.5
        ) {
            if case .error(let message) = event { failure = message }
        }
        // The assertion is that the stream ENDS AT ALL, with the inactivity error
        // rather than a hang — and that the EPIPE from terminating the child mid
        // write is thrown, not delivered as a fatal SIGPIPE.
        let elapsed = Date().timeIntervalSince(started)
        let passed = failure?.contains("stopped responding") == true && elapsed < 10
        print(String(
            format: "backpressure=%.3fs %@ %@",
            elapsed, failure ?? "no error", passed ? "PASS" : "FAIL"
        ))
        exit(passed ? 0 : 1)
    }
    RunLoop.main.run()
}

// ChatGPT-subscription auth + streaming checks (no UI):
//   .build/debug/Mia --chatgpt-login    interactive: opens the browser OAuth flow
//   .build/debug/Mia --smoke-chatgpt    requires a prior login; one streaming turn
if CommandLine.arguments.contains("--chatgpt-login") {
    Task { @MainActor in
        do {
            try await ChatGPTAuth.signIn()
            print("signed in: \(ChatGPTAuth.accountEmail ?? "?") plan=\(ChatGPTAuth.planLabel ?? "?")")
            exit(0)
        } catch {
            print("LOGIN-ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--smoke-chatgpt") {
    Task {
        guard ChatGPTAuth.isSignedIn else {
            print("SKIP: not signed in — run --chatgpt-login first")
            exit(1)
        }
        let model = ProcessInfo.processInfo.environment["MIA_MODEL"] ?? ChatGPTAuth.defaultModel
        let config = ProviderConfig(baseURL: "", apiKey: "", model: model, kind: .chatGPT)
        let useSearch = CommandLine.arguments.contains("--with-search")
        print("smoke-chatgpt: model=\(model) account=\(ChatGPTAuth.accountEmail ?? "?") search=\(useSearch)")
        let prompt = useSearch
            ? "What is the latest stable release version of the Zed editor? Use web_search to check — do not answer from memory. Reply with just the version number and the source URL."
            : "Reply with exactly: Mia ChatGPT OK"
        var chunks = 0
        let history = [OpenAIChatClient.WireMessage(role: "user", content: .text(prompt))]
        for await event in CodexResponsesClient.run(
            history: history,
            config: config,
            webAccess: useSearch ? .localTools(.duckduckgo) : nil
        ) {
            switch event {
            case .partial:
                chunks += 1
            case .usage:
                break
            case .activity(let text):
                print("[activity] \(text)")
            case .status(let text):
                print("[status] \(text)")
            case .reasoning(let text):
                print("[reasoning] \(text.count) chars")
            case .done(let text):
                print("chunks=\(chunks)\nfinal=\(text)")
                exit(text.isEmpty ? 1 : 0)
            case .error(let message):
                print("ERROR: \(message)")
                exit(1)
            case .contentRejected(let capability, let message):
                print("ERROR (\(capability.rawValue) rejected): \(message)")
                exit(1)
            }
        }
        exit(1)
    }
    RunLoop.main.run()
}

// Conversation persistence round-trip check (no network, no UI).
if CommandLine.arguments.contains("--smoke-persist") {
    let conversation = Conversation(
        id: UUID(),
        title: "Persistence test",
        updatedAt: Date(),
        messages: [
            ChatMessage(role: .user, text: "hello"),
            ChatMessage(role: .assistant, text: "world"),
        ]
    )
    ConversationStore.save(conversation)
    let list = ConversationStore.listRecent()
    let loaded = ConversationStore.load(id: conversation.id)
    print("listCount=\(list.count) firstTitle=\(list.first?.title ?? "-") loadedMessages=\(loaded?.messages.count ?? -1) roundTripText=\(loaded?.messages.last?.text ?? "-")")
    ConversationStore.delete(id: conversation.id)
    print("afterDelete=\(ConversationStore.listRecent().filter { $0.id == conversation.id }.count)")

    // Fork tree round-trip: tail-only storage, chain resolution, and
    // materialization of children when the parent is deleted.
    let sharedTip = ChatMessage(role: .assistant, text: "shared tip")
    let parent = Conversation(
        id: UUID(), title: "Fork parent", updatedAt: Date(),
        messages: [ChatMessage(role: .user, text: "root q"), sharedTip,
                   ChatMessage(role: .user, text: "parent-only followup")]
    )
    let child = Conversation(
        id: UUID(), title: "Fork child", updatedAt: Date(),
        messages: [ChatMessage(role: .user, text: "diverged")],
        parentID: parent.id, forkMessageID: sharedTip.id
    )
    ConversationStore.save(parent)
    ConversationStore.save(child)
    let resolved = ConversationStore.loadResolved(id: child.id)
    print("forkResolved=\(resolved?.messages.count ?? -1) missingParent=\(resolved?.missingParent ?? true) tailOnDisk=\(ConversationStore.load(id: child.id)?.messages.count ?? -1)")
    ConversationStore.deleteMaterializingChildren(id: parent.id)
    let materialized = ConversationStore.load(id: child.id)
    print("afterParentDelete standalone=\(materialized?.parentID == nil) messages=\(materialized?.messages.count ?? -1)")
    ConversationStore.delete(id: child.id)
    exit(0)
}

// Re-running the last turn (no network, no UI): Retry and Edit prompt both
// truncate the transcript, and truncation is where the fork tree can break.
if CommandLine.arguments.contains("--smoke-rerun") {
    MainActor.assumeIsolated {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mia-rerun-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        ConversationStore.overrideDirectory = scratch
        var log = CheckLog()

        // No provider is configured in this binary's defaults domain, so send()
        // takes its explicit-warning path: the user message is appended and an
        // error row follows. That is enough to prove a retry RE-SENT — and it
        // keeps the harness off the network.
        let store = ChatStore(providerStore: ProviderStore(), shortcutStore: ShortcutStore())
        store.send("first question")
        let afterFirst = store.messages.map(\.role)
        log.check("send appends the turn", afterFirst.first == .user && store.messages.count >= 2,
              "roles=\(afterFirst)")
        let conversationID = store.conversationID

        // A fork of this conversation must survive its parent being truncated:
        // it resolves against messages that are about to stop existing.
        let forkPoint = store.messages[0].id
        let forkID = UUID()
        ConversationStore.save(Conversation(
            id: forkID, title: "child", updatedAt: Date(),
            messages: [ChatMessage(role: .user, text: "diverged")],
            parentID: conversationID, forkMessageID: forkPoint
        ))

        log.check("canRerunLastTurn", store.canRerunLastTurn)
        store.retryLastTurn()
        let texts = store.messages.filter { $0.role == .user }.map(\.text)
        log.check("retry re-sends the same question once", texts == ["first question"], "users=\(texts)")
        log.check("retry drops the previous outcome",
              store.messages.filter { $0.role == .user }.count == 1
                  && store.messages.firstIndex(where: { $0.role == .user }) == 0,
              "roles=\(store.messages.map(\.role))")
        let childAfter = ConversationStore.load(id: forkID)
        log.check("truncation materializes forks", childAfter?.parentID == nil,
              "parentID=\(String(describing: childAfter?.parentID))")
        log.check("materialized fork keeps the shared prefix",
              (childAfter?.messages.count ?? 0) > 1, "messages=\(childAfter?.messages.count ?? -1)")

        // Edit hands the text back and leaves the transcript without that turn.
        let taken = store.takeLastUserMessageForEditing()
        log.check("edit returns the question", taken?.text == "first question",
              "taken=\(String(describing: taken?.text))")
        log.check("edit empties the transcript", store.messages.isEmpty,
              "roles=\(store.messages.map(\.role))")
        log.check("edit removes the stored file too", ConversationStore.load(id: conversationID) == nil)
        log.check("nothing left to re-run", !store.canRerunLastTurn)
        log.check("edit on an empty transcript is a no-op", store.takeLastUserMessageForEditing() == nil)

        // ↑ recall's storage: newest first, deduplicated, capped.
        let savedHistory = PromptHistory.entries
        UserDefaults.standard.removeObject(forKey: "promptHistory")
        PromptHistory.record("one")
        PromptHistory.record("two")
        PromptHistory.record("one")
        log.check("recall is newest-first and deduplicated", PromptHistory.entries == ["one", "two"],
              "entries=\(PromptHistory.entries)")
        PromptHistory.record("   ")
        log.check("recall ignores blank prompts", PromptHistory.entries == ["one", "two"])
        for index in 0..<PromptHistory.maxEntries + 10 { PromptHistory.record("p\(index)") }
        log.check("recall is capped", PromptHistory.entries.count == PromptHistory.maxEntries,
              "count=\(PromptHistory.entries.count)")
        UserDefaults.standard.set(savedHistory, forKey: "promptHistory")

        try? FileManager.default.removeItem(at: scratch)
        log.finish()
    }
}

// Steering a streaming reply (no network, no UI): the chip's
// queue/replace/discard lifecycle, the idle insert (a plain send), and the
// streaming insert + auto-answer pair — driven directly against the state
// machine, which is why the steer API doesn't gate on isStreaming.
if CommandLine.arguments.contains("--smoke-steer") {
    MainActor.assumeIsolated {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mia-steer-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        ConversationStore.overrideDirectory = scratch

        // Both halves build ProviderStores, and a ProviderStore persists itself
        // into this binary's defaults domain on construction/assignment —
        // including the dead provider below, which would poison every later
        // harness run's "no provider configured" assumption. Snapshot the
        // domain and restore it before finish() exits.
        let touchedKeys = [
            "providersJSON", "selectedProviderID", "knownModelsJSON", "selectedModelsJSON",
            "knownModelEffortsJSON", "defaultModelEffortsJSON", "selectedModelEffortsJSON",
            "modelCapabilitiesJSON", "capabilityExceptionsJSON", "pdfPassThroughJSON", "promptHistory",
        ]
        let savedDefaults = touchedKeys.map { UserDefaults.standard.object(forKey: $0) }
        func restoreDefaults() {
            for (key, value) in zip(touchedKeys, savedDefaults) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        // The recall assertions below need an exact baseline; whatever earlier
        // harness runs left in the domain is snapshotted and restored, not kept.
        UserDefaults.standard.removeObject(forKey: "promptHistory")

        var log = CheckLog()

        // Idle insert is a plain send. The provider is a deliberately keyless
        // REMOTE one, so preflight fails deterministically ("No API key…")
        // regardless of this machine's ambient sign-in state — user row first,
        // error row after, and no request leaves the process.
        let keylessStore = ProviderStore()
        let keyless = Provider(
            id: UUID(), name: "Steer keyless", baseURL: "https://example.invalid/v1",
            isPreset: false, defaultModel: "smoke-model"
        )
        keylessStore.providers = [keyless]
        keylessStore.selectedID = keyless.id
        let store = ChatStore(providerStore: keylessStore, shortcutStore: ShortcutStore())

        // The chip is one replaceable slot.
        log.check("queue parks a pending chip",
              store.queueSteer("first") && store.steerPendingText == "first",
              "pending=\(String(describing: store.steerPendingText))")
        log.check("a second queue replaces the chip",
              store.queueSteer("second") && store.steerPendingText == "second",
              "pending=\(String(describing: store.steerPendingText))")
        store.discardSteer()
        log.check("discard clears the chip", store.steer == nil)
        log.check("blank queue is refused", !store.queueSteer("   "))
        log.check("queueing never touches ↑ recall", PromptHistory.entries.isEmpty,
              "entries=\(PromptHistory.entries)")

        _ = store.queueSteer("idle question")
        store.insertSteer()
        log.check("idle insert asks its question",
              store.messages.first?.role == .user && store.messages.first?.text == "idle question",
              "roles=\(store.messages.map(\.role))")
        log.check("idle insert shows the explicit error", store.messages.last?.role == .error,
              "roles=\(store.messages.map(\.role))")
        log.check("idle insert consumes the chip", store.steer == nil)
        log.check("idle insert records ↑ recall exactly once",
              PromptHistory.entries.filter { $0 == "idle question" }.count == 1,
              "entries=\(PromptHistory.entries)")

        // The streaming branch, offline: port 9 (discard) refuses connections on
        // the loopback, so turns start but never reach a server. Its own scratch
        // directory too — ChatStore resumes the newest stored conversation, and
        // part one just persisted one. The harness never awaits between the
        // synchronous steps, so the failing tails can't interleave before the
        // settling wait below.
        let streamScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mia-steer-stream-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        ConversationStore.overrideDirectory = streamScratch
        let providerStore = ProviderStore()
        let dead = Provider(
            id: UUID(), name: "Steer harness", baseURL: "http://127.0.0.1:9/v1",
            isPreset: false, defaultModel: "smoke-model"
        )
        providerStore.providers = [dead]
        providerStore.selectedID = dead.id // localhost: no key needed (send's isLocal exemption)
        let streaming = ChatStore(providerStore: providerStore, shortcutStore: ShortcutStore())
        log.check("root turn is streaming",
              streaming.send("root question") && streaming.isStreaming,
              "isStreaming=\(streaming.isStreaming)")
        _ = streaming.queueSteer("follow up")
        log.check("insert commits the question under the stream",
              streaming.commitSteerInsert()
                  && streaming.messages.last?.role == .user
                  && streaming.messages.last?.text == "follow up",
              "roles=\(streaming.messages.map(\.role))")
        log.check("committed follow-up is in the inserted state",
              streaming.steer != nil && streaming.steerPendingText == nil)
        log.check("inserted follow-up blocks retry", !streaming.canRerunLastTurn)
        log.check("auto-answer starts the follow-up turn",
              streaming.autoAnswerPendingSteer()
                  && streaming.steer == nil
                  && streaming.messages.last?.role == .assistant
                  && streaming.isStreaming,
              "roles=\(streaming.messages.map(\.role))")
        streaming.stop()
        // Let the failed tails land: a runloop wait, not Thread.sleep (the tails
        // are main-actor code that needs this very thread), and a poll rather
        // than a fixed sleep (the refused connection's error event surfaces
        // through URLSession on its own schedule).
        var settled = false
        var waited = 0.0
        while !settled, waited < 5 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            waited += 0.05
            settled = !streaming.isStreaming
        }
        log.check("the failed tails land", settled, "waited=\(waited)s")
        log.check("retry frees up once the queue is spent", streaming.canRerunLastTurn)

        // A queued follow-up never survives into a fresh chat.
        _ = streaming.queueSteer("leftover")
        streaming.newChat()
        log.check("newChat drops the queue", streaming.steer == nil)

        restoreDefaults()
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: streamScratch)
        log.finish()
    }
}

// Cross-conversation search behind the history popover's field (no UI).
if CommandLine.arguments.contains("--smoke-chat-search") {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("mia-chatsearch-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    ConversationStore.overrideDirectory = scratch
    var log = CheckLog()

    // The needle sits in the MIDDLE of the transcript: not in the title (first
    // message) and not in the snippet (last message). Matching only those two
    // is exactly the old filter, so this conversation is invisible to it.
    let buried = Conversation(
        id: UUID(), title: "How do I center a div", updatedAt: Date(),
        messages: [
            ChatMessage(role: .user, text: "How do I center a div"),
            ChatMessage(role: .assistant, text: "Use flexbox with justify-content."),
            ChatMessage(role: .user, text: "and the vertical axis?"),
            ChatMessage(role: .assistant, text: "align-items: center handles that."),
            ChatMessage(role: .user, text: "thanks"),
            ChatMessage(role: .assistant, text: "You're welcome."),
        ]
    )
    let other = Conversation(
        id: UUID(), title: "Unrelated", updatedAt: Date().addingTimeInterval(-60),
        messages: [ChatMessage(role: .user, text: "what time is it"),
                   ChatMessage(role: .assistant, text: "Half past four.")]
    )
    ConversationStore.save(buried)
    ConversationStore.save(other)

    let index = ConversationStore.fullTextIndex()
    log.check("indexes every conversation", index.count == 2, "count=\(index.count)")
    let text = index[buried.id] ?? ""
    log.check("index reaches mid-transcript text", text.contains("justify-content"))
    log.check("index leaves other conversations out",
          !(index[other.id] ?? "").contains("justify-content"))

    let hit = index.filter { $0.value.localizedCaseInsensitiveContains("flexbox") }
    log.check("body search finds the buried chat", hit.keys.first == buried.id, "hits=\(hit.count)")

    let excerpt = ConversationStore.excerpt(of: text, matching: "flexbox") ?? ""
    log.check("excerpt contains the needle", excerpt.localizedCaseInsensitiveContains("flexbox"),
          "excerpt=\(excerpt)")
    log.check("excerpt is one line", !excerpt.contains("\n"), "excerpt=\(excerpt)")
    log.check("excerpt shows surrounding words", excerpt.contains("justify-content"), "excerpt=\(excerpt)")
    log.check("excerpt of a miss is nil", ConversationStore.excerpt(of: text, matching: "zzzz") == nil)

    // Reasoning is deliberately absent: it renders behind a collapsed
    // disclosure, so a hit there would open a chat with nothing visibly matching.
    let thinking = Conversation(
        id: UUID(), title: "Thinker", updatedAt: Date().addingTimeInterval(-120),
        messages: [
            ChatMessage(role: .user, text: "question"),
            ChatMessage(role: .assistant, text: "answer", reasoning: "SECRETTHOUGHT"),
        ]
    )
    ConversationStore.save(thinking)
    let reindexed = ConversationStore.fullTextIndex()
    log.check("index excludes reasoning",
          !(reindexed[thinking.id] ?? "").contains("SECRETTHOUGHT"))
    log.check("reasoning survives the round trip",
          ConversationStore.load(id: thinking.id)?.messages.last?.reasoning == "SECRETTHOUGHT")
    log.check("⌘F does not count reasoning",
          !MarkdownRenderer.searchableStrings(
              for: ChatMessage(role: .assistant, text: "answer", reasoning: "SECRETTHOUGHT")
          ).joined().contains("SECRETTHOUGHT"))

    try? FileManager.default.removeItem(at: scratch)
    log.finish()
}

// Conversation export round-trip (no network, no UI): the fork chain feeds the
// Markdown/JSON encoders, and the Markdown is byte-exact against a golden
// transcript — an export is an archive, so its shape must not drift silently.
if CommandLine.arguments.contains("--smoke-export") {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("mia-export-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    ConversationStore.overrideDirectory = scratch
    var log = CheckLog()

    // The stamp line has to be golden, not machine-relative: pin the zone the
    // formatters pick up (before the encoder's cached one is first touched).
    // NSTimeZone.default — the one mutable global — rather than the read-only
    // TimeZone.current; a harness-local mutation, restored on the way out.
    let savedTimeZone = NSTimeZone.default
    NSTimeZone.default = TimeZone(identifier: "UTC")!
    defer { NSTimeZone.default = savedTimeZone }

    let stamp: (Date) -> String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: $0)
    }

    // Fixture: the parent holds the whole shared prefix; the fork stores only
    // its divergent tail — exactly what lands on disk after a real fork.
    let question = ChatMessage(role: .user, text: "What is 2+2?")
    let answer = ChatMessage(
        role: .assistant,
        text: "It is 4.\n\n```swift\nlet sum = 2 + 2\n```",
        reasoning: "Counting fingers"
    )
    let parent = Conversation(
        id: UUID(), title: "Fork parent", updatedAt: Date(),
        messages: [question, answer]
    )
    let tail = ChatMessage(role: .user, text: "Thanks!")
    let child = Conversation(
        id: UUID(), title: "Fork export child", updatedAt: Date(),
        messages: [tail],
        parentID: parent.id, forkMessageID: answer.id
    )
    ConversationStore.save(parent)
    ConversationStore.save(child)

    // (a) resolution: shared prefix absorbed, fork pointers cleared, and the
    // tail-only file on disk left as it was.
    log.check("tail-only on disk", ConversationStore.load(id: child.id)?.messages == [tail])
    let resolved = ConversationStore.resolved(child.id)
    log.check("resolved = prefix + tail (3 messages)", resolved?.messages == [question, answer, tail],
          "count=\(resolved?.messages.count ?? -1)")
    log.check("resolved clears the fork pointers",
          resolved?.parentID == nil && resolved?.forkMessageID == nil)
    guard let resolved else { log.finish() }

    // (b) Markdown, byte-exact against the golden transcript.
    let exportedAt = Date(timeIntervalSince1970: 1_761_000_000)
    log.check("the golden stamp is pinned", stamp(exportedAt) == "2025-10-20 22:40",
          "stamp=\(stamp(exportedAt))")
    let golden = """
            # Fork export child
            *Exported from Mia · \(stamp(exportedAt))*

            **You:**

            What is 2+2?

            **Assistant:**

            > *Reasoning:*
            > Counting fingers

            It is 4.

            ```swift
            let sum = 2 + 2
            ```

            **You:**

            Thanks!
            """
    let markdown = ConversationExport.markdown(conversation: resolved, exportedAt: exportedAt)
    log.check("markdown matches the golden transcript", markdown == golden + "\n",
          "got=\(markdown.debugDescription)")

    // (c) JSON: the export decodes back into the same resolved conversation.
    do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Conversation.self, from: ConversationExport.json(conversation: resolved))
        log.check("json round-trips the resolved conversation",
              decoded.id == child.id && decoded.title == child.title
                  && decoded.messages == [question, answer, tail]
                  && decoded.parentID == nil && decoded.forkMessageID == nil)
    } catch {
        log.check("json round-trips the resolved conversation", false, "threw: \(error)")
    }

    // Default file names are the slug law the panels rely on: readable, and
    // unique even among same-titled chats because of the id suffix.
    log.check("file name is slug + id prefix",
          ConversationExport.filenameBase(for: resolved) == "fork-export-child-" + String(child.id.uuidString.prefix(6)))

    // UI-only rows export as italic notes — checked apart from the fork
    // fixture so its message count stays exactly prefix + tail.
    let noisy = ConversationExport.markdown(
        conversation: Conversation(
            id: UUID(), title: "Noisy", updatedAt: Date(),
            messages: [
                ChatMessage(role: .error, text: "Provider unreachable"),
                ChatMessage(role: .activity, text: "Searching the web…"),
            ]
        ),
        exportedAt: exportedAt
    )
    log.check("error/activity rows export as italic notes",
          noisy.contains("*Provider unreachable*") && noisy.contains("*Searching the web…*"))

    // The Export All write loop, against the same scratch store: one .md per
    // conversation plus the merged bundle.
    let bundle = ConversationExport.exportAll(conversations: [resolved, parent], to: scratch)
    log.check("export all writes one .md per conversation plus conversations.json",
          bundle.written == 2 && bundle.failed == 0
              && FileManager.default.fileExists(atPath: scratch.appendingPathComponent("conversations.json").path))

    try? FileManager.default.removeItem(at: scratch)
    log.finish()
}

// Selection-quote formatting for the Services prefill (no network, no UI):
//   .build/debug/Mia --smoke-selection
// The Services plumbing around it can't run headless; the FORMAT it injects
// can and must not drift — it is what the user's model reads as context.
if CommandLine.arguments.contains("--smoke-selection") {
    var log = CheckLog()

    log.check("single line gets a '> ' prefix and one trailing blank line",
          SelectionQuote.quote("hello") == "> hello\n\n")
    log.check("multi-line selection quotes every line",
          SelectionQuote.quote("first\nsecond") == "> first\n> second\n\n")
    log.check("blank inner lines become a bare '>'",
          SelectionQuote.quote("a\n\nb") == "> a\n>\n> b\n\n")
    log.check("whitespace-only inner lines collapse to a bare '>'",
          SelectionQuote.quote("a\n   \nb") == "> a\n>\n> b\n\n")
    log.check("empty selection formats to empty (no prefill)",
          SelectionQuote.quote("") == "")
    log.check("whitespace-only selection formats to empty",
          SelectionQuote.quote(" \n \n") == "" && SelectionQuote.quote("\n") == "")
    log.check("outer newlines are trimmed, never quoted",
          SelectionQuote.quote("\n\nhello\n") == "> hello\n\n")
    log.check("indentation inside the selection survives verbatim",
          SelectionQuote.quote("code:\n    let x = 2") == "> code:\n>     let x = 2\n\n")
    log.check("CRLF selections still quote as one line each",
          SelectionQuote.quote("a\r\nb") == "> a\r\n> b\n\n")

    // P5 selection-button laws (pure): gesture thresholds, own-window
    // suppression, anchor clamping, immediate-send decision.
    let gesture = SelectionGesture.qualifies(down:up:clickCount:)
    log.check("a short drag is not a selection",
          !gesture(CGPoint(x: 100, y: 100), CGPoint(x: 105, y: 100), 1))
    log.check("a drag qualifies exactly at the 12pt threshold",
          gesture(CGPoint(x: 100, y: 100), CGPoint(x: 112, y: 100), 1))
    log.check("just under the threshold does not",
          !gesture(CGPoint(x: 100, y: 100), CGPoint(x: 111.9, y: 100), 1))
    log.check("a vertical sweep qualifies",
          gesture(CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 90), 1))
    log.check("a stationary double-click qualifies",
          gesture(CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10), 2))
    log.check("a triple-click qualifies",
          gesture(CGPoint(x: 10, y: 10), CGPoint(x: 11, y: 10), 3))
    log.check("a plain single click does not",
          !gesture(CGPoint(x: 10, y: 10), CGPoint(x: 12, y: 10), 1))

    let downEvent = NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
    )
    let dragUpEvent = NSEvent.mouseEvent(
        with: .leftMouseUp, location: NSPoint(x: 40, y: 10), modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
    )
    if let downEvent, let dragUpEvent {
        log.check("the event-typed wrapper sees the same drag",
              SelectionGesture.qualifies(mouseDown: downEvent, mouseUp: dragUpEvent))
    } else {
        log.check("the event-typed wrapper sees the same drag", false, "NSEvent synthesis failed")
    }

    let ownFrames = [CGRect(x: 0, y: 0, width: 500, height: 400), CGRect(x: 800, y: 0, width: 200, height: 200)]
    log.check("presses inside Mia's own windows are suppressed",
          SelectionGesture.isInside(point: CGPoint(x: 250, y: 200), frames: ownFrames)
              && SelectionGesture.isInside(point: CGPoint(x: 900, y: 100), frames: ownFrames))
    log.check("presses outside them are not",
          !SelectionGesture.isInside(point: CGPoint(x: 600, y: 200), frames: ownFrames))

    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    log.check("anchor sits below and left-aligned with the release point",
          Anchor.clamp(point: CGPoint(x: 400, y: 500), in: screen) == CGPoint(x: 400, y: 484))
    log.check("anchor clamps at the screen's left edge",
          Anchor.clamp(point: CGPoint(x: -40, y: 500), in: screen).x == 0)
    log.check("anchor clamps at the screen's right edge",
          Anchor.clamp(point: CGPoint(x: 1000, y: 500), in: screen).x == 1000 - Anchor.buttonSize)
    log.check("anchor clamps at the screen's bottom edge",
          Anchor.clamp(point: CGPoint(x: 400, y: 0), in: screen).y == 0)

    log.check("immediate send needs the switch AND real text",
          SelectionGesture.shouldSendImmediately(enabled: true, text: "hello")
              && !SelectionGesture.shouldSendImmediately(enabled: false, text: "hello")
              && !SelectionGesture.shouldSendImmediately(enabled: true, text: "")
              && !SelectionGesture.shouldSendImmediately(enabled: true, text: "  \n "))

    log.finish()
}

// Auto-naming (P3) request construction, cleanup and guard laws (no network,
// no UI):   .build/debug/Mia --smoke-titling
// The network hop itself has no injectable fake (fetchTitle uses the shared
// URLSession), so the contract is pinned here at every pure boundary it has.
if CommandLine.arguments.contains("--smoke-titling") {
    var log = CheckLog()

    // (a) requestMessages: one system instruction + ONE user message carrying
    // a bounded slice of the first prompt.
    let request = Titling.requestMessages(firstUserText: "How do I center a div?")
    var systemText = ""
    var userText = ""
    if case .text(let text)? = request.first?.content { systemText = text }
    if case .text(let text)? = request.last?.content { userText = text }
    log.check("request is system + single user message",
          request.count == 2 && request.first?.role == "system" && request.last?.role == "user")
    log.check("system prompt demands a short untitled-formatted name",
          systemText == Titling.systemPrompt && systemText.contains("6 words") && systemText.contains("no quotes"))
    log.check("user message carries the first prompt verbatim", userText.contains("How do I center a div?"))

    let longQuestion = String(repeating: "x", count: Titling.maxInputLength + 120)
    var longPayload = ""
    if case .text(let text)? = Titling.requestMessages(firstUserText: longQuestion).last?.content { longPayload = text }
    log.check("first prompt is capped at 500 characters",
          longPayload.count == "Name this conversation:\n\n".count + Titling.maxInputLength,
          "count=\(longPayload.count)")

    // The wire contract: tiny, cold, non-streaming.
    let body = try? Titling.requestBody(model: "test-model", messages: request)
    log.check("naming call is non-streaming, ≤24 tokens, temperature 0",
          (body?["stream"] as? Bool) == false
              && (body?["max_tokens"] as? Int) == 24
              && (body?["temperature"] as? Int) == 0
              && (body?["model"] as? String) == "test-model")

    // (b) sanitize: quotes out, newlines flattened, width capped, empty inert.
    log.check("straight quotes are stripped", Titling.sanitize("\"Fix my regex\"") == "Fix my regex")
    log.check("curly quotes are stripped", Titling.sanitize("“Swift concurrency basics”") == "Swift concurrency basics")
    log.check("newlines flatten to one line", Titling.sanitize("Line one\nLine two") == "Line one Line two")
    let longTitle = Titling.sanitize(String(repeating: "a", count: 100))
    log.check("titles cap at 40 characters plus ellipsis",
          longTitle == String(repeating: "a", count: Titling.maxTitleLength) + "…")
    log.check("blank and quote-only results are inert",
          Titling.sanitize("") == "" && Titling.sanitize("   ") == "" && Titling.sanitize("\"'“”") == "")

    // (c) the derived default: what a conversation must still carry to be
    // nameable. Internal (test hook), so the harness asserts the exact law.
    log.check("derived title is the first user message",
          ChatStore.title(for: [ChatMessage(role: .user, text: "short question")]) == "short question")
    log.check("derived title flattens newlines",
          ChatStore.title(for: [ChatMessage(role: .user, text: "line one\nline two")]) == "line one line two")
    log.check("derived title caps at 40 with ellipsis",
          ChatStore.title(for: [ChatMessage(role: .user, text: String(repeating: "b", count: 100))])
              == String(repeating: "b", count: Titling.maxTitleLength) + "…")
    log.check("conversation without a user message says New chat",
          ChatStore.title(for: [ChatMessage(role: .assistant, text: "hi")]) == "New chat")

    // (d) old files: conversations persisted before autoTitled existed decode
    // untouched — the exact JSON shape ConversationStore.save wrote back then.
    let legacyJSON = """
        {"id": "\(UUID().uuidString)", "title": "Legacy chat", "updatedAt": "2026-10-01T10:00:00Z", "messages": [{"id": "\(UUID().uuidString)", "role": "user", "text": "before auto-naming existed", "attachments": []}]}
        """
    let legacyDecoder = JSONDecoder()
    legacyDecoder.dateDecodingStrategy = .iso8601
    do {
        let legacy = try legacyDecoder.decode(Conversation.self, from: Data(legacyJSON.utf8))
        log.check("pre-autoTitled files still decode, flag reads nil",
              legacy.autoTitled == nil && legacy.title == "Legacy chat")
        var named = legacy
        named.autoTitled = true
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        let roundTrip = try legacyDecoder.decode(Conversation.self, from: try legacyEncoder.encode(named))
        log.check("autoTitled round-trips through the store codec", roundTrip.autoTitled == true)
    } catch {
        log.check("pre-autoTitled files still decode, flag reads nil", false, "threw: \(error)")
        log.check("autoTitled round-trips through the store codec", false, "threw: \(error)")
    }

    // (e) the once-guard matrix: every condition alone must veto.
    let base = (enabled: true, hasCustomTitle: false, alreadyAttempted: false, producedAnswer: true, kind: ProviderKind.openAICompatible)
    log.check("all guards passing is the only firing combination",
          Titling.shouldTitle(enabled: base.enabled, hasCustomTitle: base.hasCustomTitle,
                              alreadyAttempted: base.alreadyAttempted, producedAnswer: base.producedAnswer, kind: base.kind))
    log.check("never a second attempt",
          !Titling.shouldTitle(enabled: base.enabled, hasCustomTitle: base.hasCustomTitle,
                               alreadyAttempted: true, producedAnswer: base.producedAnswer, kind: base.kind))
    log.check("not once the title left its default",
          !Titling.shouldTitle(enabled: base.enabled, hasCustomTitle: true,
                               alreadyAttempted: base.alreadyAttempted, producedAnswer: base.producedAnswer, kind: base.kind))
    log.check("not when the setting is off",
          !Titling.shouldTitle(enabled: false, hasCustomTitle: base.hasCustomTitle,
                               alreadyAttempted: base.alreadyAttempted, producedAnswer: base.producedAnswer, kind: base.kind))
    log.check("not unless the turn produced a real answer",
          !Titling.shouldTitle(enabled: base.enabled, hasCustomTitle: base.hasCustomTitle,
                               alreadyAttempted: base.alreadyAttempted, producedAnswer: false, kind: base.kind))
    log.check("subscription provider kinds are skipped silently",
          !Titling.shouldTitle(enabled: base.enabled, hasCustomTitle: base.hasCustomTitle,
                               alreadyAttempted: base.alreadyAttempted, producedAnswer: base.producedAnswer, kind: .chatGPT)
              && !Titling.shouldTitle(enabled: base.enabled, hasCustomTitle: base.hasCustomTitle,
                                      alreadyAttempted: base.alreadyAttempted, producedAnswer: base.producedAnswer, kind: .codexAppServer))

    log.finish()
}

// Persona presets (P4) — resolution priority, Custom-path fidelity, seeding
// laws, codec round-trip (no network, no UI, reads no mutable state):
//   .build/debug/Mia --smoke-persona
if CommandLine.arguments.contains("--smoke-persona") {
    var log = CheckLog()

    let translate = Persona(id: UUID(), name: "Translate", prompt: "You are a precise translator.")
    let reviewer = Persona(id: UUID(), name: "Code Review", prompt: "You are a senior code reviewer.")
    let roster = [translate, reviewer]

    // (a) Resolution priority: the active persona's prompt wins; everything
    // else is the caller's fallback.
    log.check("active persona's prompt is sent",
          PersonaStore.resolvePrompt(activeID: translate.id.uuidString, personas: roster, fallback: "FALLBACK")
              == translate.prompt)
    log.check("no selection falls back", PersonaStore.resolvePrompt(activeID: nil, personas: roster, fallback: "FALLBACK") == "FALLBACK")
    log.check("deleted persona's id falls back (resolves as Custom)",
          PersonaStore.resolvePrompt(activeID: UUID().uuidString, personas: roster, fallback: "FALLBACK") == "FALLBACK")

    // (b) Custom-path fidelity: byte-for-byte the pre-persona expression —
    // `string(forKey: "systemPrompt") ?? default` — for every fallback shape,
    // including the explicit-empty "send no system prompt" law.
    let legacyExpression = UserDefaults.standard.string(forKey: "systemPrompt") ?? ChatStore.defaultSystemPrompt
    var customIdentical = true
    for fallback in [ChatStore.defaultSystemPrompt, "My custom instructions.", "", legacyExpression] {
        if PersonaStore.resolvePrompt(activeID: nil, personas: roster, fallback: fallback) != fallback
            || PersonaStore.resolvePrompt(activeID: UUID().uuidString, personas: roster, fallback: fallback) != fallback {
            customIdentical = false
        }
    }
    log.check("Custom path is byte-identical for every fallback", customIdentical)
    log.check("explicitly-empty prompt stays empty (no system prompt)",
          PersonaStore.resolvePrompt(activeID: nil, personas: roster, fallback: "").isEmpty)

    // (c) Seeding: three examples once, only into an empty unseeded install.
    let seeded = PersonaStore.seedPersonas(existing: [], hasSeeded: false)
    log.check("empty unseeded install gets the three examples",
          seeded.count == 3 && seeded.map(\.name) == ["Translate", "Code Review", "Writing"],
          "names=\(seeded.map(\.name))")
    log.check("seed prompts are real prompts", seeded.allSatisfy { $0.prompt.count > 40 })

    let mine = Persona(id: UUID(), name: "Mine", prompt: "Keep out.")
    log.check("an existing list is never seeded over",
          PersonaStore.seedPersonas(existing: [mine], hasSeeded: false) == [mine])
    log.check("deleted examples do not revive after seeding",
          PersonaStore.seedPersonas(existing: [], hasSeeded: true) == [])

    // (d) Codec round-trip: what persist() writes, init() reads back.
    do {
        let data = try JSONEncoder().encode(roster)
        let back = try JSONDecoder().decode([Persona].self, from: data)
        log.check("personas round-trip through the store codec", back == roster)
    } catch {
        log.check("personas round-trip through the store codec", false, "threw: \(error)")
    }

    log.finish()
}

// Update check: version ordering and release decoding (no network).
if CommandLine.arguments.contains("--smoke-update") {
    var log = CheckLog()

    // The one that a string comparison gets wrong, and the reason this is
    // component-wise: "0.1.10" < "0.1.9" lexically, and the tenth patch release
    // is not a hypothetical.
    log.check("0.1.10 is newer than 0.1.9", UpdateChecker.isNewer("0.1.10", than: "0.1.9"))
    log.check("0.1.9 is not newer than 0.1.10", !UpdateChecker.isNewer("0.1.9", than: "0.1.10"))
    log.check("equal versions are not newer", !UpdateChecker.isNewer("0.1.2", than: "0.1.2"))
    log.check("1.0 beats 0.9.9", UpdateChecker.isNewer("1.0", than: "0.9.9"))
    log.check("shorter equal prefix is not newer", !UpdateChecker.isNewer("0.1", than: "0.1.0"))
    log.check("0.1.0.1 beats 0.1.0", UpdateChecker.isNewer("0.1.0.1", than: "0.1.0"))
    // A prerelease of a version must never outrank that version's release.
    log.check("0.2.0-beta.1 is not newer than 0.2.0", !UpdateChecker.isNewer("0.2.0-beta.1", than: "0.2.0"))

    func payload(_ json: String) -> Data { Data(json.utf8) }
    func url(_ s: String) -> URL { URL(string: s)! }
    let good = UpdateChecker.decodeLatestTagPage(url(
        "https://github.com/imdlan/mia-desktop/releases/tag/v0.1.3"
    ))
    log.check("decodes the tag without its v", good?.version == "0.1.3", "version=\(good?.version ?? "-")")
    log.check("the release page is the redirect target",
          good?.page.absoluteString == "https://github.com/imdlan/mia-desktop/releases/tag/v0.1.3")
    log.check("bare tags decode too",
          UpdateChecker.decodeLatestTagPage(url("https://github.com/imdlan/mia-desktop/releases/tag/0.1.4"))?
              .version == "0.1.4")
    log.check("a non-tag page is refused",
          UpdateChecker.decodeLatestTagPage(url("https://github.com/imdlan/mia-desktop/releases")) == nil)
    log.check("an unrelated URL is refused",
          UpdateChecker.decodeLatestTagPage(url("https://github.com/imdlan/mia-desktop")) == nil)
    log.check("a tagless path is refused",
          UpdateChecker.decodeLatestTagPage(url("https://github.com/imdlan/mia-desktop/releases/tag/")) == nil)
    log.check("the running version parses",
          !UpdateChecker.isNewer(UpdateChecker.currentVersion, than: UpdateChecker.currentVersion))

    log.finish()
}

// fetch_url's internal-address guard (no network — every probe is a literal or
// a .localhost name): loopback, this-host, RFC1918, link-local (incl. the cloud
// metadata endpoint), CGNAT, ULA and multicast targets are refused, IPv4-mapped
// IPv6 is classified through its embedded v4 address, and public addresses pass.
//   .build/debug/Mia --smoke-web-guard
if CommandLine.arguments.contains("--smoke-web-guard") {
    var log = CheckLog()
    func probe(_ string: String) -> Bool { WebToolExecutor.isInternalTarget(URL(string: string)!) }
    log.check("loopback is refused", probe("http://127.0.0.1:11434/v1"))
    log.check("this-host is refused", probe("http://0.0.0.0/x"))
    log.check("RFC1918 is refused",
          probe("http://10.1.2.3/") && probe("http://192.168.1.1/")
              && probe("http://172.16.0.1/") && probe("http://172.31.255.255/"))
    log.check("a public 172.x is kept", !probe("http://172.32.0.1/"))
    log.check("link-local is refused", probe("http://169.254.169.254/latest/meta-data/"))
    log.check("CGNAT is refused", probe("http://100.100.1.1/"))
    log.check("multicast is refused", probe("http://224.0.0.1/"))
    log.check("localhost is refused", probe("http://localhost:8080/") && probe("http://api.localhost/"))
    log.check("IPv6 loopback is refused", probe("http://[::1]/"))
    log.check("IPv6 link-local is refused", probe("http://[fe80::1]/"))
    log.check("IPv6 ULA is refused", probe("http://[fd00::1]/"))
    log.check("IPv4-mapped IPv6 is refused", probe("http://[::ffff:192.168.0.1]/"))
    log.check("public addresses are kept", !probe("http://8.8.8.8/") && !probe("http://93.184.216.34/"))
    log.finish()
}

// Resource bundles: the dependencies' Bundle.module must resolve INSIDE the
// assembled .app (no network). Only meaningful when run from dist/Mia.app —
// build.sh runs it there after assembly. "Didn't trap" alone proves nothing on
// this machine, where the accessor's compile-time fallback directory usually
// exists; the redirect count is what shows the lookups went through
// Contents/Resources, which is the only place a stranger's Mac has them.
if CommandLine.arguments.contains("--smoke-bundles") {
    var log = CheckLog()
    let root = Bundle.main.bundleURL
    log.check("runs from an assembled .app", root.pathExtension == "app",
              "Bundle.main is \(root.path) — run dist/Mia.app/Contents/MacOS/Mia --smoke-bundles")
    _ = NSApplication.shared
    // The two lookups that crashed 0.1.2: the hotkey recorder (localized strings)
    // and a LaTeX font.
    let recorder = KeyboardShortcuts.RecorderCocoa(for: .toggleMia)
    log.check("the hotkey recorder constructs", recorder.shortcutName == .toggleMia)
    log.check("a math font loads", MTFontManager.manager.latinModernFont(withSize: 12) != nil)
    // Two toolchains, one law. CLT-27-era SwiftPM accessors only try the .app
    // ROOT and the compile-time fallback, so the swizzle answers the root
    // lookup and the redirect count rises. Xcode-16-era accessors check
    // Bundle.main.resourceURL — Contents/Resources — FIRST and never reach the
    // swizzle, so redirected stays 0. Either mechanism is fine as long as the
    // bundles that LOAD are the in-app copies — that is the property issue #1
    // (hotkey crash on a stranger's Mac) actually depends on.
    let redirected = MiaResourceBundleRedirectCount()
    // And the bundles the dependencies now hold ARE the in-app copies — not the
    // compile-time fallback, which on this machine usually still exists.
    let loaded = Set(Bundle.allBundles.map { $0.bundleURL.standardizedFileURL.path })
    let bundleNames = ["KeyboardShortcuts_KeyboardShortcuts", "SwiftMath_SwiftMath"]
    let inAppLoaded = bundleNames.allSatisfy { name in
        loaded.contains(
            root.appendingPathComponent("Contents/Resources/\(name).bundle").standardizedFileURL.path
        )
    }
    log.check("dependency bundles resolved inside the .app",
              redirected >= 2 || inAppLoaded, "redirected=\(redirected) inAppLoaded=\(inAppLoaded)")
    for name in bundleNames {
        let expected = root.appendingPathComponent("Contents/Resources/\(name).bundle").standardizedFileURL.path
        log.check("\(name) resolved to the in-app copy", loaded.contains(expected),
                  "loaded=\(loaded.filter { $0.hasSuffix(".bundle") }.sorted())")
    }
    log.finish()
}

// Brand migration (no network, no UI): the rename moved the bundle ID (so
// UserDefaults.standard lost every setting), the Application Support directory
// (so conversations/ and secrets.json were orphaned) and the hotkey name (so
// KeyboardShortcuts lost the user's shortcut). Every fixture here is
// disposable — a throwaway defaults domain and a temp directory — because this
// machine carries the REAL com.chenle.PopChat domain and PopChat/ data, and the
// harness must never go near them. All of migrate's parameters are therefore
// explicit; a default-argument call in here would run against real user data.
//   .build/debug/Mia --smoke-migration
if CommandLine.arguments.contains("--smoke-migration") {
    let pid = ProcessInfo.processInfo.processIdentifier
    var log = CheckLog()
    let files = FileManager.default

    // Fixtures: an Application Support root holding the old app's data, a
    // legacy defaults domain carrying two representative keys, and an empty
    // target domain standing in for the new identity.
    let root = files.temporaryDirectory
        .appendingPathComponent("mia-migration-smoke-\(pid)", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
    let legacyID = "test.mia.legacy.\(pid)"
    let targetID = "test.mia.target.\(pid)"
    let legacy = UserDefaults(suiteName: legacyID)!
    let target = UserDefaults(suiteName: targetID)!
    target.removePersistentDomain(forName: targetID)
    let hotkeyJSON = #"{"carbonModifiers": 2048, "carbonKeyCode": 49}"#
    do {
        try files.createDirectory(
            at: root.appendingPathComponent("PopChat/conversations", isDirectory: true),
            withIntermediateDirectories: true
        )
        try #"{"sk-legacy": "fixture"}"#.write(
            to: root.appendingPathComponent("PopChat/secrets.json"), atomically: true, encoding: .utf8
        )
        try #"{"id": "c1"}"#.write(
            to: root.appendingPathComponent("PopChat/conversations/c1.json"), atomically: true, encoding: .utf8
        )
    } catch {
        print("FAIL: could not build fixtures: \(error.localizedDescription)")
        exit(1)
    }
    legacy.set(["DeepSeek|https://api.deepseek.com"], forKey: "providerList")
    legacy.set(hotkeyJSON, forKey: "KeyboardShortcuts_togglePopChat")
    legacy.synchronize()

    // The full flow, exactly as a first post-rename launch runs it — with every
    // real identifier swapped for the fixtures above.
    let actions = BrandMigration.migrate(appSupportRoot: root, legacyAppID: legacyID, defaults: target)
    print("actions: \(actions)")
    log.check("moves PopChat/ to Mia/ wholesale",
          files.fileExists(atPath: root.appendingPathComponent("Mia/conversations/c1.json").path)
              && files.fileExists(atPath: root.appendingPathComponent("Mia/secrets.json").path))
    log.check("the old directory is renamed away, not copied",
          !files.fileExists(atPath: root.appendingPathComponent("PopChat").path))
    log.check("settings survive the bundle-ID change",
          target.object(forKey: "providerList") as? [String] == ["DeepSeek|https://api.deepseek.com"],
          "got \(String(describing: target.object(forKey: "providerList")))")
    log.check("the hotkey follows its renamed key",
          target.string(forKey: "KeyboardShortcuts_toggleMia") == hotkeyJSON
              && target.object(forKey: "KeyboardShortcuts_togglePopChat") == nil)
    log.check("the migrated flag is set", target.bool(forKey: BrandMigration.migratedFlagKey))

    // Idempotence: a second launch must be a complete no-op.
    let again = BrandMigration.migrate(appSupportRoot: root, legacyAppID: legacyID, defaults: target)
    log.check("a second run does nothing", again.isEmpty, "actions=\(again)")

    // Both directories present (the user ran both builds): force re-runs the
    // flow, but the move must still refuse — merging or deleting either side
    // would destroy data the user can see.
    try? files.createDirectory(
        at: root.appendingPathComponent("PopChat", isDirectory: true), withIntermediateDirectories: true
    )
    let forced = BrandMigration.migrate(
        appSupportRoot: root, legacyAppID: legacyID, defaults: target, force: true
    )
    print("forced actions: \(forced)")
    log.check("both-present leaves both directories alone",
          files.fileExists(atPath: root.appendingPathComponent("PopChat").path)
              && files.fileExists(atPath: root.appendingPathComponent("Mia").path))
    log.check("both-present says so in the log",
          forced.contains { $0.contains("nothing moved") }, "actions=\(forced)")

    // The throwaway domains and the temp tree disappear entirely.
    target.removePersistentDomain(forName: targetID)
    legacy.removePersistentDomain(forName: legacyID)
    try? files.removeItem(at: root.deletingLastPathComponent())
    log.finish()
}

// Reasoning: the wire spellings, and the waiting row's line (no network, no UI).
if CommandLine.arguments.contains("--smoke-reasoning") {
    var log = CheckLog()
    func line(_ json: String) -> String { "data: \(json)" }

    // Neither spelling is in the OpenAI schema, so a decoding regression looks
    // exactly like "this model doesn't think" rather than like a bug — which is
    // why both are pinned here.
    let deepseek = OpenAIChatClient.decodeDelta(line: line(
        #"{"choices":[{"delta":{"reasoning_content":"weighing it"}}]}"#))
    log.check("reasoning_content decodes", deepseek?.reasoning == "weighing it",
          "got=\(String(describing: deepseek?.reasoning))")
    let openrouter = OpenAIChatClient.decodeDelta(line: line(
        #"{"choices":[{"delta":{"reasoning":"weighing it"}}]}"#))
    log.check("reasoning decodes", openrouter?.reasoning == "weighing it",
          "got=\(String(describing: openrouter?.reasoning))")
    let content = OpenAIChatClient.decodeDelta(line: line(
        #"{"choices":[{"delta":{"content":"hello"}}]}"#))
    log.check("content still decodes", content?.content == "hello" && content?.reasoning == nil)

    // The whole chunk is decoded with `try?`, so a provider that spells
    // `reasoning` as an object would take the VISIBLE text down with it.
    let objectShaped = OpenAIChatClient.decodeDelta(line: line(
        #"{"choices":[{"delta":{"content":"hello","reasoning":{"summary":"x"}}}]}"#))
    log.check("an object-shaped reasoning field does not eat the content",
          objectShaped?.content == "hello", "got=\(String(describing: objectShaped?.content))")
    let nullShaped = OpenAIChatClient.decodeDelta(line: line(
        #"{"choices":[{"delta":{"content":"hi","reasoning":null}}]}"#))
    log.check("a null reasoning field does not eat the content", nullShaped?.content == "hi")
    log.check("empty reasoning is not reported", OpenAIChatClient.decodeDelta(line: line(
        #"{"choices":[{"delta":{"reasoning":""}}]}"#))?.reasoning == nil)

    log.check("tool calls still decode", OpenAIChatClient.decodeDelta(line: line(
        #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"web_search"}}]}}]}"#)
    )?.toolCalls.first?.function?.name == "web_search")
    log.check("[DONE] is the sentinel", OpenAIChatClient.decodeDelta(line: "data: [DONE]")?.isDone == true)
    log.check("non-data lines are skipped", OpenAIChatClient.decodeDelta(line: "event: ping") == nil)

    // The waiting row shows thinking through a FIXED window that scrolls, so a
    // chunk arriving can never change the row's height. That is the
    // transcript-reflow rule the old one-line status enforced with
    // lineLimit(1); a sized window gets it structurally, and shows two more
    // lines. Measured through a real hosting view, not from the constants —
    // the constants agreeing with themselves proves nothing.
    MainActor.assumeIsolated {
        func renderedHeight(_ text: String, lines: Int) -> CGFloat {
            let host = NSHostingView(
                rootView: ThinkingScroller(text: text, lines: lines).frame(width: 300)
            )
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let collapsed = WaitingIndicator.collapsedLines
        let oneLine = renderedHeight("a short thought", lines: collapsed)
        let huge = renderedHeight(
            String(repeating: "a much longer thought that wraps many times. ", count: 400),
            lines: collapsed
        )
        log.check("the thinking window's height ignores its content", oneLine == huge,
                  "short=\(oneLine) long=\(huge)")
        log.check("three lines is taller than one",
                  oneLine > renderedHeight("a short thought", lines: 1))
        log.check("expanding shows more",
                  renderedHeight("a short thought", lines: WaitingIndicator.expandedLines) > oneLine)
    }

    // Reasoning renders through the same SelectableText that measures itself
    // with boundingRect, so its styling has to be metrics-neutral. It is not a
    // theoretical rule: scaling the fonts down under the paragraph styles
    // buildProse chose made the measurement come up one paragraph short, and
    // the tail of the thinking was clipped with nothing to indicate it.
    let sample = "**Heading**\n\nFirst thought about the problem.\n\nSecond thought.\n\nThird thought."
    func height(_ string: NSAttributedString) -> CGFloat {
        string.boundingRect(
            with: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
    }
    let reasoned = MarkdownRenderer.attributedReasoning(sample)
    log.check("reasoning parses markdown", !reasoned.string.contains("**"), "got=\(reasoned.string.debugDescription)")
    log.check("reasoning keeps every paragraph", reasoned.string.contains("Third thought"))
    let delta = abs(height(MarkdownRenderer.attributedProse(sample)) - height(reasoned))
    log.check("reasoning styling is metrics-neutral", delta < 0.5, "height delta=\(delta)")

    log.finish()
}

// Turn-cost stats: the usage-bearing terminal chunk (choices empty) used to
// fall through the `choices?.first` guard and vanish; the footer's token
// counts and rate are only as real as this decoding.
if CommandLine.arguments.contains("--smoke-usage") {
    var log = CheckLog()
    func line(_ json: String) -> String { "data: \(json)" }

    let terminal = OpenAIChatClient.decodeDelta(line: line(
        #"{"choices":[],"usage":{"prompt_tokens":45000,"completion_tokens":17518,"total_tokens":62518}}"#))
    log.check("usage-only chunk decodes", terminal?.usage?.total == 62518 && terminal?.usage?.output == 17518,
          "got=\(String(describing: terminal?.usage))")
    log.check("usage-only chunk carries no content", terminal?.content == nil)

    let piggyback = OpenAIChatClient.decodeDelta(line: line(
        #"{"choices":[{"delta":{"content":"tail"},"finish_reason":"stop"}],"# +
        #""usage":{"prompt_tokens":10,"completion_tokens":5}}"#))
    log.check("usage riding a content chunk decodes", piggyback?.content == "tail" && piggyback?.usage?.total == 15,
          "got=\(String(describing: piggyback?.usage))")

    log.check("missing usage leaves it nil", OpenAIChatClient.decodeDelta(line: line(
        #"{"choices":[{"delta":{"content":"hi"}}]}"#))?.usage == nil)

    // Additive across a tool loop's rounds; derived tok/s formatting.
    log.check("usage adds across rounds",
          (TurnUsage(total: 100, output: 20) + TurnUsage(total: 30, output: 5)) == TurnUsage(total: 130, output: 25))
    log.check("stats line renders all three parts",
          TurnStats(totalTokens: 62518, outputTokens: 17518, duration: 342).displayLine
              == "62518 tokens · 5m 42s · 51.2 tok/s",
          "got=\(TurnStats(totalTokens: 62518, outputTokens: 17518, duration: 342).displayLine)")
    log.check("usage-less stats render duration only",
          TurnStats(totalTokens: nil, outputTokens: nil, duration: 5.4).displayLine == "5.4s",
          "got=\(TurnStats(totalTokens: nil, outputTokens: nil, duration: 5.4).displayLine)")
    log.check("sub-second durations render as ms",
          TurnStats(totalTokens: nil, outputTokens: nil, duration: 0.85).displayLine == "850ms",
          "got=\(TurnStats(totalTokens: nil, outputTokens: nil, duration: 0.85).displayLine)")
    log.check("duration formats minutes", TurnStats.durationText(342) == "5m 42s")

    log.finish()
}

// Attachment-loader check (no network): .build/debug/Mia --smoke-file <path>
if let flagIndex = CommandLine.arguments.firstIndex(of: "--smoke-file"),
   CommandLine.arguments.count > flagIndex + 1 {
    let path = CommandLine.arguments[flagIndex + 1]
    Task {
        let result = await AttachmentLoader.load(url: URL(fileURLWithPath: path))
        switch result {
        case .success(let attachment):
            switch attachment.content {
            case .text(let text):
                print("OK text chars=\(text.count) note=\(attachment.note ?? "-")")
                print("preview: \(text.prefix(160).replacingOccurrences(of: "\n", with: "⏎"))")
            case .image(let dataURL):
                print("OK image dataURLBytes=\(dataURL.count) note=\(attachment.note ?? "-")")
            case .pdf(let dataURL, let extractedText):
                print("OK pdf dataURLBytes=\(dataURL.count) textChars=\(extractedText.count) note=\(attachment.note ?? "-")")
                print("preview: \(extractedText.prefix(160).replacingOccurrences(of: "\n", with: "⏎"))")
            }
        case .failure(let error):
            print("ATTACH-ERROR: \(error.message)")
        }
        exit(0)
    }
    RunLoop.main.run()
}

/// Pass/fail tally shared by the check-list harnesses. Each law prints as it is
/// evaluated, so a failing run says which one broke rather than just "FAIL".
struct CheckLog {
    private(set) var failures: [String] = []

    mutating func check(
        _ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = ""
    ) {
        print("  \(condition ? "ok  " : "FAIL") \(label)\(condition ? "" : " — \(detail())")")
        if !condition { failures.append(label) }
    }

    /// Prints the verdict and exits with it — every one of these harnesses ends
    /// this way.
    func finish() -> Never {
        print(failures.isEmpty ? "PASS" : "FAIL (\(failures.count))")
        exit(failures.isEmpty ? 0 : 1)
    }
}

/// The panel's message input, found by walking the view tree.
@MainActor
func composerTextView(in view: NSView?) -> NSTextView? {
    guard let view else { return nil }
    if let textView = view as? NSTextView, textView.isEditable { return textView }
    for sub in view.subviews { if let found = composerTextView(in: sub) { return found } }
    return nil
}

/// A real keystroke: through the window, to whatever holds first responder.
/// Harnesses synthesize rather than call methods directly so a lost first
/// responder shows up as "the keystroke went nowhere", exactly as it does for
/// the user.
@MainActor
func sendKey(
    _ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = [],
    to panel: NSWindow
) -> Bool {
    guard let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: keyCode
    ) else { return false }
    panel.sendEvent(event)
    return true
}

/// An arrow key, with the modifier flags AppKit really attaches to one.
@MainActor
func sendArrow(up: Bool, to panel: NSWindow) -> Bool {
    let scalar = UnicodeScalar(up ? NSUpArrowFunctionKey : NSDownArrowFunctionKey)!
    return sendKey(
        String(scalar), keyCode: up ? 126 : 125,
        modifiers: [.function, .numericPad], to: panel
    )
}

/// Synthetic long-form conversation (prose/code/table/list/math) written into a
/// scratch store, so UI harnesses are deterministic and never touch real history.
func installBenchmarkConversation(minLength: Int) -> URL {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("mia-bench-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    ConversationStore.overrideDirectory = scratch
    let block = """
    ## Section heading

    Some **bold** prose with `inline code`, a [link](https://example.com) and \
    inline math $e^{i\\pi} + 1 = 0$ to exercise every render path.

    ```swift
    func fib(_ n: Int) -> Int { n < 2 ? n : fib(n - 1) + fib(n - 2) }
    ```

    | Column A | Column B |
    |----------|----------|
    | one      | two      |

    - first item
    - second item

    $$\\sum_{k=1}^{n} k = \\frac{n(n+1)}{2}$$

    """
    var long = ""
    while long.count < minLength { long += block }
    ConversationStore.save(Conversation(
        id: UUID(),
        title: "ui benchmark",
        updatedAt: Date(),
        messages: [
            ChatMessage(role: .user, text: "benchmark"),
            ChatMessage(role: .assistant, text: long),
        ]
    ))
    return scratch
}

/// Conversation for the ⌘F harness: long enough to scroll, with the needle in
/// three widely separated messages so stepping matches must move the scroller.
func installFindConversation() -> URL {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("mia-find-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    ConversationStore.overrideDirectory = scratch
    let filler = String(repeating: "Filler prose that exists purely to make the transcript tall. ", count: 30)
    var messages: [ChatMessage] = []
    for index in 0..<9 {
        let marker = index % 3 == 1 ? "needle\(index) " : "" // messages 1, 4, 7
        // Message 4 is pages long with its needle at the very END: centering the
        // MESSAGE would leave that hit far off screen, so it is what proves the
        // transcript scrolls to the matched characters.
        let body = index == 4 ? String(repeating: filler, count: 12) + " tailneedle end." : filler
        messages.append(ChatMessage(
            role: index % 2 == 0 ? .user : .assistant,
            text: "\(marker)message \(index). \(body)"
        ))
    }
    ConversationStore.save(Conversation(
        id: UUID(),
        title: "find harness",
        updatedAt: Date(),
        messages: messages
    ))
    return scratch
}

/// The transcript scroller is the vertically-scrollable NSScrollView with the
/// tallest document — a plain "first match" walk can land on a code block's
/// horizontal scroller or an attachment strip.
@MainActor
func transcriptScrollView(in root: NSView?) -> NSScrollView? {
    var best: NSScrollView?
    func walk(_ view: NSView) {
        if let scroll = view as? NSScrollView,
           let doc = scroll.documentView,
           doc.frame.height > (best?.documentView?.frame.height ?? 0) {
            best = scroll
        }
        for sub in view.subviews { walk(sub) }
    }
    if let root { walk(root) }
    return best
}

// Panel sizing invariants: real controller + synthetic conversation, replaying
// empty↔non-empty transitions. With messages the content height and min must
// never sit below the expanded minimum (320).
if CommandLine.arguments.contains("--smoke-minsize") {
    MainActor.assumeIsolated {
        let scratch = installBenchmarkConversation(minLength: 2_000)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Geometry persisted on a display that is now gone: the panel must come
        // back FITTING the current screen. Nothing else shrinks it (position()
        // is satisfied by a 120x80 intersection), so an oversized restore would
        // put every resize edge off-screen with no way to recover. Stored in the
        // real defaults domain, so the previous values go back on the way out.
        let defaults = UserDefaults.standard
        let priorWidth = defaults.double(forKey: "panelWidth")
        let priorHeight = defaults.double(forKey: "panelExpandedHeight")
        defaults.set(9_000, forKey: "panelWidth")
        defaults.set(9_000, forKey: "panelExpandedHeight")
        @MainActor func restoreGeometryDefaults() {
            if priorWidth > 0 { defaults.set(priorWidth, forKey: "panelWidth") }
            else { defaults.removeObject(forKey: "panelWidth") }
            if priorHeight > 0 { defaults.set(priorHeight, forKey: "panelExpandedHeight") }
            else { defaults.removeObject(forKey: "panelExpandedHeight") }
        }
        let providerStore = ProviderStore()
        let shortcutStore = ShortcutStore()
        let controller = PanelController(providerStore: providerStore, shortcutStore: shortcutStore)
        controller.show()
        restoreGeometryDefaults() // the panel exists now; don't leave 9000 lying around
        let originalID = controller.chatStore.conversationID

        // The enforced minimum lives in the windowWillResize delegate (the
        // NSHostingView zeroes contentMinSize) — probe it like a user drag.
        @MainActor func clamp(_ panel: NSWindow, _ size: NSSize) -> NSSize {
            controller.windowWillResize(panel, to: size)
        }

        @MainActor func findFieldScroll(_ view: NSView?) -> NSScrollView? {
            guard let view else { return nil }
            if let scroll = view as? NSScrollView, scroll.documentView is NSTextView { return scroll }
            for sub in view.subviews { if let found = findFieldScroll(sub) { return found } }
            return nil
        }

        @MainActor func findDragStrip(_ view: NSView?) -> WindowDragView? {
            guard let view else { return nil }
            if let strip = view as? WindowDragView { return strip }
            for sub in view.subviews { if let found = findDragStrip(sub) { return found } }
            return nil
        }

        @MainActor func report(_ label: String) {
            guard let panel = app.windows.first(where: { $0 is FloatingPanel }) else {
                restoreGeometryDefaults()
                print("FAIL: no panel"); exit(1)
            }
            let content = panel.contentRect(forFrameRect: panel.frame)
            let clamped = clamp(panel, NSSize(width: 400, height: 197))
            // Where does the composer field actually sit? Its bottom edge plus the
            // capsule + composer paddings (5+6+12) must stay inside the window.
            var fieldNote = "field=?"
            if let scroll = findFieldScroll(panel.contentView), let root = panel.contentView {
                let frame = scroll.convert(scroll.bounds, to: root)
                let bottomGap = root.isFlipped ? root.bounds.height - frame.maxY : frame.minY
                fieldNote = "fieldY=\(Int(root.isFlipped ? frame.minY : root.bounds.height - frame.maxY))"
                    + " fieldH=\(Int(frame.height)) gapBelowField=\(Int(bottomGap))"
            }
            if let strip = findDragStrip(panel.contentView), let root = panel.contentView {
                let frame = strip.convert(strip.bounds, to: root)
                fieldNote += " pillsY=\(Int(root.isFlipped ? frame.minY : root.bounds.height - frame.maxY))"
                    + " pillsH=\(Int(frame.height)) rootH=\(Int(root.bounds.height))"
            }
            print("\(label): contentH=\(Int(content.height)) w=\(Int(content.width)) \(fieldNote) " +
                  "dragTo400x197→\(Int(clamped.width))x\(Int(clamped.height)) " +
                  "empty=\(controller.chatStore.messages.isEmpty)")
        }

        var step = 0
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            MainActor.assumeIsolated {
                step += 1
                switch step {
                case 1:
                    report("launch non-empty")
                    controller.chatStore.newChat()
                case 2:
                    report("after newChat  ")
                    controller.chatStore.loadConversation(originalID)
                case 3:
                    report("after reload   ")
                default:
                    guard let panel = app.windows.first(where: { $0 is FloatingPanel }) else { exit(1) }
                    let height = panel.contentRect(forFrameRect: panel.frame).height
                    let clamped = clamp(panel, NSSize(width: 400, height: 197))
                    // The field must keep its designed bottom clearance (5+6+12
                    // = 23pt) — a smaller gap means the input capsule is being
                    // squeezed out of the panel (e.g. by safe-area insets the
                    // compact height report can't see).
                    var gapOK = false
                    if let scroll = findFieldScroll(panel.contentView), let root = panel.contentView {
                        let frame = scroll.convert(scroll.bounds, to: root)
                        let bottomGap = root.isFlipped ? root.bounds.height - frame.maxY : frame.minY
                        gapOK = bottomGap >= 20
                    }
                    // Oversized restore must have been shrunk onto a real screen.
                    let frame = panel.frame
                    let fits = NSScreen.screens.contains { screen in
                        frame.width <= screen.visibleFrame.width + 0.5
                            && frame.height <= screen.visibleFrame.height + 0.5
                    }
                    print("restored-from-9000x9000 frame=\(Int(frame.width))x\(Int(frame.height)) fitsAScreen=\(fits)")
                    let ok = !controller.chatStore.messages.isEmpty
                        && height >= 319 && clamped.width >= 519 && clamped.height >= 319 && gapOK && fits
                    print(ok ? "PASS" : "FAIL: settled height=\(Int(height)) clamp=\(Int(clamped.width))x\(Int(clamped.height)) gapOK=\(gapOK)")
                    try? FileManager.default.removeItem(at: scratch)
                    exit(ok ? 0 : 1)
                }
            }
        }
        app.run()
    }
}

// UI layout stress (no network): builds the real panel with a synthetic long
// conversation and bounces the transcript scroll while a watchdog thread checks
// main-thread responsiveness. Catches layout-convergence hangs.
if CommandLine.arguments.contains("--smoke-scroll") {
    nonisolated(unsafe) var lastPong = Date()
    nonisolated(unsafe) var maxPingLatency = 0.0
    Thread.detachNewThread {
        while true {
            let sent = Date()
            DispatchQueue.main.async {
                lastPong = Date()
                maxPingLatency = max(maxPingLatency, Date().timeIntervalSince(sent))
            }
            Thread.sleep(forTimeInterval: 0.25)
            if Date().timeIntervalSince(lastPong) > 3 {
                print("HANG pid=\(ProcessInfo.processInfo.processIdentifier) — main thread stalled >3s")
                fflush(stdout)
                Thread.sleep(forTimeInterval: 60) // stay alive so the stack can be sampled
                exit(2)
            }
        }
    }
    MainActor.assumeIsolated {
        let scratch = installBenchmarkConversation(minLength: 20_000)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let providerStore = ProviderStore()
        let shortcutStore = ShortcutStore()
        let controller = PanelController(providerStore: providerStore, shortcutStore: shortcutStore)
        controller.show()

        var elapsed = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                elapsed += 0.05
                guard let panel = app.windows.first(where: { $0 is FloatingPanel }),
                      let scroll = transcriptScrollView(in: panel.contentView),
                      let doc = scroll.documentView else {
                    if elapsed > 3 { print("FAIL: no transcript scroll view found"); exit(1) }
                    return
                }
                let maxY = max(0, doc.frame.height - scroll.contentSize.height)
                let phase = (sin(elapsed * 1.5) + 1) / 2
                scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY * phase))
                scroll.reflectScrolledClipView(scroll.contentView)
                if Int(elapsed * 20) % 20 == 0 {
                    print(String(format: "t=%.1fs offset=%.0f of %.0f", elapsed, maxY * phase, maxY))
                    fflush(stdout)
                }
                if elapsed >= 12 {
                    print(String(format: "PASS: 12s of scrolling, max main-thread ping latency %.0f ms", maxPingLatency * 1000))
                    try? FileManager.default.removeItem(at: scratch)
                    if maxY < 500 {
                        print("FAIL: transcript content did not exceed the viewport — layout suspect")
                        exit(1)
                    }
                    exit(0)
                }
            }
        }
        app.run()
    }
}

// Typing responsiveness check: real panel + synthetic 20k-char conversation in a
// scratch store, simulated edits in the real composer after warmup. Reports max
// warmed main-thread stall and whether transcript measurements scale with
// keystrokes. Fails (exit 3) on stalls above 50 ms.
if CommandLine.arguments.contains("--smoke-typing") {
    nonisolated(unsafe) var maxWarmStall = 0.0
    nonisolated(unsafe) var warmed = false
    nonisolated(unsafe) var warmStart = Date()
    nonisolated(unsafe) var stallLog: [(Double, Double)] = [] // (s since warm, ms)
    Thread.detachNewThread {
        while true {
            let sent = Date()
            DispatchQueue.main.async {
                let latency = Date().timeIntervalSince(sent)
                if warmed {
                    maxWarmStall = max(maxWarmStall, latency)
                    if latency > 0.02 {
                        stallLog.append((Date().timeIntervalSince(warmStart), latency * 1000))
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    MainActor.assumeIsolated {
        let scratch = installBenchmarkConversation(minLength: 20_000)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let providerStore = ProviderStore()
        let shortcutStore = ShortcutStore()
        let controller = PanelController(providerStore: providerStore, shortcutStore: shortcutStore)
        controller.show()

        func focusedEditor() -> NSTextView? {
            guard let panel = app.windows.first(where: { $0 is FloatingPanel }) else { return nil }
            if let editor = panel.firstResponder as? NSTextView { return editor }
            func findTextView(_ view: NSView?) -> NSTextView? {
                guard let view else { return nil }
                if let textView = view as? NSTextView, textView.isEditable { return textView }
                for sub in view.subviews {
                    if let found = findTextView(sub) { return found }
                }
                return nil
            }
            if let textView = findTextView(panel.contentView) {
                panel.makeFirstResponder(textView)
                return panel.firstResponder as? NSTextView
            }
            return nil
        }

        var elapsed = 0.0
        var edits = 0
        var measurementsAtWarm = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated {
                elapsed += 0.03
                if elapsed < 2.0 { return } // cold construction + prewarm window
                if !warmed {
                    warmed = true
                    warmStart = Date()
                    measurementsAtWarm = SelectableText.measurementCount
                    print("warmup done; measurements so far: \(measurementsAtWarm)")
                }
                guard let editor = focusedEditor() else {
                    print("FAIL: no focused editor")
                    try? FileManager.default.removeItem(at: scratch)
                    exit(1)
                }
                if edits < 150 {
                    // Alternate grow/shrink so height changes are exercised too.
                    if edits % 10 == 9 {
                        editor.deleteBackward(nil)
                    } else {
                        editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
                    }
                    edits += 1
                } else {
                    let typedMeasurements = SelectableText.measurementCount - measurementsAtWarm
                    let stallMs = maxWarmStall * 1000
                    print(String(format: "edits=%d transcript+composer measurements during typing=%d maxWarmedStall=%.1f ms",
                                 edits, typedMeasurements, stallMs))
                    for (at, ms) in stallLog.prefix(20) {
                        print(String(format: "  stall %.0f ms at t=%.2fs", ms, at))
                    }
                    try? FileManager.default.removeItem(at: scratch)
                    if stallMs > 50 {
                        print("FAIL: warmed main-thread stall exceeded 50 ms")
                        exit(3)
                    }
                    print("PASS")
                    exit(0)
                }
            }
        }
        app.run()
    }
}

// ↑ in an empty composer recalls prompts you have sent; ↑ in a draft you are
// writing must still move the caret. Real arrow-key events through the real
// panel, because the whole feature is a key route: NSTextView turns ↑ into
// moveUp: and the composer decides between the two meanings there.
if CommandLine.arguments.contains("--smoke-recall") {
    MainActor.assumeIsolated {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mia-recall-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        ConversationStore.overrideDirectory = scratch
        let savedHistory = PromptHistory.entries
        UserDefaults.standard.set(["short one", "a considerably longer older prompt"], forKey: "promptHistory")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = PanelController(providerStore: ProviderStore(), shortcutStore: ShortcutStore())
        controller.show()

        func cleanup() {
            UserDefaults.standard.set(savedHistory, forKey: "promptHistory")
            try? FileManager.default.removeItem(at: scratch)
        }
        var log = CheckLog()
        func fail(_ message: String) -> Never {
            print("FAIL: \(message)")
            cleanup()
            exit(1)
        }
        @MainActor func arrow(_ up: Bool, into panel: NSWindow) {
            if !sendArrow(up: up, to: panel) { fail("could not synthesize an arrow key") }
        }
        @MainActor func type(_ character: String, into panel: NSWindow) {
            if !sendKey(character, to: panel) { fail("could not synthesize a keystroke") }
        }

        var step = 0
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let panel = app.windows.first(where: { $0 is FloatingPanel }) else { fail("no panel") }
                guard let field = composerTextView(in: panel.contentView) else { fail("no composer field") }
                step += 1
                switch step {
                case 1:
                    panel.makeFirstResponder(field)
                case 2:
                    log.check("starts empty", field.string.isEmpty, "draft=\(field.string.debugDescription)")
                    arrow(true, into: panel)
                case 3:
                    log.check("↑ recalls the newest prompt", field.string == "short one",
                          "draft=\(field.string.debugDescription)")
                    // The caret must follow the text, or typing continues from
                    // wherever the old draft's offset happened to be.
                    log.check("caret lands at the end",
                          field.selectedRange().location == (field.string as NSString).length,
                          "caret=\(field.selectedRange().location) of \((field.string as NSString).length)")
                    arrow(true, into: panel)
                case 4:
                    log.check("↑ again walks further back", field.string == "a considerably longer older prompt",
                          "draft=\(field.string.debugDescription)")
                    log.check("caret follows a LONGER recalled prompt",
                          field.selectedRange().location == (field.string as NSString).length,
                          "caret=\(field.selectedRange().location) of \((field.string as NSString).length)")
                    arrow(true, into: panel)
                case 5:
                    log.check("↑ at the oldest stays put", field.string == "a considerably longer older prompt",
                          "draft=\(field.string.debugDescription)")
                    arrow(false, into: panel)
                case 6:
                    log.check("↓ walks back toward now", field.string == "short one",
                          "draft=\(field.string.debugDescription)")
                    log.check("caret follows a SHORTER recalled prompt",
                          field.selectedRange().location == (field.string as NSString).length,
                          "caret=\(field.selectedRange().location) of \((field.string as NSString).length)")
                    arrow(false, into: panel)
                case 7:
                    log.check("↓ past the newest restores the empty composer", field.string.isEmpty,
                          "draft=\(field.string.debugDescription)")
                    type("x", into: panel)
                case 8:
                    log.check("typing still lands", field.string == "x", "draft=\(field.string.debugDescription)")
                    arrow(true, into: panel)
                case 9:
                    // The law that keeps ↑ usable at all: recall may only START
                    // from an empty composer, or a half-typed draft is eaten and
                    // a multi-line one becomes uneditable.
                    log.check("↑ in a draft does not recall", field.string == "x",
                          "draft=\(field.string.debugDescription)")
                    cleanup()
                    log.finish()
                default:
                    fail("harness ran past its steps")
                }
            }
        }
        app.run()
    }
}

// Composer keeps focus when messages appear: types into the empty panel, sends,
// then types again — through real key events, so a lost first responder shows up
// as "the keystroke went nowhere" exactly as it does for the user. `/nope` is an
// unknown slash command: it drives the real send path (rows appended, panel grows
// 120→440) without touching the network.
if CommandLine.arguments.contains("--smoke-input") {
    MainActor.assumeIsolated {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mia-input-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        ConversationStore.overrideDirectory = scratch
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let providerStore = ProviderStore()
        let controller = PanelController(providerStore: providerStore, shortcutStore: ShortcutStore())
        controller.show()

        // Unbundled, this binary gets its own UserDefaults domain, so the provider
        // list is freshly generated and the app's stored key (keyed by the app's
        // provider UUID) doesn't match. --live borrows MIA_API_KEY like the
        // other live harnesses; the entry is removed again on the way out.
        // SecretStore writes the REAL secrets file (it has no scratch override),
        // so put back exactly what was there — deleting unconditionally would
        // destroy a key this debug profile already had.
        var borrowedAccount: String?
        var displacedSecret: String?
        if CommandLine.arguments.contains("--live"),
           let key = ProcessInfo.processInfo.environment["MIA_API_KEY"], !key.isEmpty,
           let provider = providerStore.selectedProvider {
            borrowedAccount = provider.id.uuidString
            displacedSecret = SecretStore.get(account: provider.id.uuidString)
            SecretStore.set(key, account: provider.id.uuidString)
        }
        func cleanup() {
            if let borrowedAccount {
                if let displacedSecret {
                    SecretStore.set(displacedSecret, account: borrowedAccount)
                } else {
                    SecretStore.delete(account: borrowedAccount)
                }
            }
            try? FileManager.default.removeItem(at: scratch)
        }

        func fail(_ message: String) -> Never {
            print("FAIL: \(message)")
            cleanup()
            exit(1)
        }
        @MainActor func type(_ character: String, into panel: NSWindow) {
            if !sendKey(character, to: panel) { fail("could not synthesize a keystroke") }
        }

        var step = 0
        weak var focusedBefore: NSTextView?
        var lastReplyID: UUID?
        var markedString = ""
        var composing = false
        var committedCJK = 0
        var lastTargetLength = 0
        var ticksSinceArrival = 0
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let panel = app.windows.first(where: { $0 is FloatingPanel }) else { fail("no panel") }
                step += 1
                switch step {
                case 1: return // settle
                case 2:
                    guard let field = composerTextView(in: panel.contentView) else { fail("no composer field") }
                    panel.makeFirstResponder(field)
                    focusedBefore = field
                    type("a", into: panel)
                case 3:
                    guard let field = composerTextView(in: panel.contentView) else { fail("composer vanished") }
                    if field.string != "a" { fail("baseline typing did not reach the composer (draft=\(field.string.debugDescription))") }
                    controller.chatStore.send("/nope") // rows appear, panel grows
                case 4...5:
                    return // let the growth animation and layout settle
                case 6:
                    guard let field = composerTextView(in: panel.contentView) else { fail("composer vanished after send") }
                    let same = field === focusedBefore
                    let isFirst = panel.firstResponder === field
                    print("after send: sameTextView=\(same) firstResponder=\(isFirst) rows=\(controller.chatStore.messages.count)")
                    type("b", into: panel)
                    // Assert on the keystroke, not on first responder: what matters
                    // is whether the user's next character lands.
                    if field.string != "ab" {
                        fail("typing after a new message went nowhere (draft=\(field.string.debugDescription), "
                             + "sameTextView=\(same), firstResponder=\(isFirst))")
                    }
                    print("static rows: ok")
                    // Phase 2: an IME composition (Chinese/Japanese/Korean pinyin
                    // etc.) is MARKED text — uncommitted, owned by the input
                    // context, and destroyed by any write to textView.string. A
                    // committed keystroke survives a transcript update; marked text
                    // is the thing that doesn't, so it needs its own check.
                    field.setMarkedText(
                        "ni", selectedRange: NSRange(location: 2, length: 0),
                        replacementRange: NSRange(location: NSNotFound, length: 0)
                    )
                    if !field.hasMarkedText() { fail("could not start a marked-text composition") }
                    markedString = field.string
                    controller.chatStore.send("/nope again") // rows appear → transcript re-renders
                case 7:
                    guard let field = composerTextView(in: panel.contentView) else { fail("composer vanished mid-composition") }
                    if !field.hasMarkedText() {
                        fail("IME composition was cancelled by a transcript update — "
                             + "marked text lost (was \(markedString.debugDescription), now \(field.string.debugDescription))")
                    }
                    // And it must still be composable: extend, then commit.
                    field.setMarkedText(
                        "niha", selectedRange: NSRange(location: 4, length: 0),
                        replacementRange: NSRange(location: NSNotFound, length: 0)
                    )
                    field.insertText("你好", replacementRange: field.markedRange())
                    if !field.string.contains("你好") {
                        fail("committing the composition did not reach the composer (draft=\(field.string.debugDescription))")
                    }
                    print("IME composition survived a transcript update and committed: \(field.string.debugDescription)")
                    // Phase 3 (--live, needs a configured provider): the same checks
                    // WHILE a reply streams and the typewriter re-renders the
                    // transcript ~30×/s. That is the state the user reported.
                    guard CommandLine.arguments.contains("--live") else {
                        print("PASS (offline; pass --live to also test during streaming)")
                        cleanup()
                        exit(0)
                    }
                    field.string = ""
                    controller.chatStore.send("Write about 250 words on the history of the fountain pen.")
                default:
                    guard CommandLine.arguments.contains("--live") else { fail("harness ran past its steps") }
                    guard let field = composerTextView(in: panel.contentView) else { fail("composer vanished mid-stream") }
                    // Wait for the reply to start, then type one character per tick.
                    let reply = controller.chatStore.messages.last(where: { $0.role == .assistant })?.text ?? ""
                    if reply.isEmpty {
                        if step > 60 {
                            let rows = controller.chatStore.messages
                                .map { "\($0.role.rawValue): \($0.text.prefix(120))" }
                                .joined(separator: "\n  ")
                            fail("no reply after 20s. Rows:\n  \(rows)")
                        }
                        return
                    }
                    if composing {
                        // The composition has now lived across a tick of streaming
                        // re-renders — the exact thing that used to abort it.
                        if !field.hasMarkedText() {
                            fail("IME composition was cancelled by the streaming transcript "
                                 + "(draft=\(field.string.debugDescription), replyChars=\(reply.count))")
                        }
                        field.insertText("好", replacementRange: field.markedRange())
                        composing = false
                        if !field.string.hasSuffix("好") {
                            fail("committing a mid-stream composition failed (draft=\(field.string.debugDescription))")
                        }
                        committedCJK += 1
                    } else {
                        let before = field.string
                        type("x", into: panel)
                        if field.string != before + "x" {
                            fail("keystroke lost while the reply was streaming "
                                 + "(draft=\(field.string.debugDescription), expected \((before + "x").debugDescription), "
                                 + "firstResponder=\(panel.firstResponder === field), replyChars=\(reply.count))")
                        }
                        field.setMarkedText(
                            "hao", selectedRange: NSRange(location: 3, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0)
                        )
                        composing = true
                    }
                    // `streamTarget` stops growing the moment the LAST chunk lands —
                    // the network turn is over there, whatever the typewriter is
                    // still doing. Ticks since that point measure how long the
                    // composer stayed locked afterwards.
                    let target = controller.chatStore.streamTargetLength
                    if target > lastTargetLength {
                        lastTargetLength = target
                        ticksSinceArrival = 0
                    } else if target > 0 {
                        ticksSinceArrival += 1
                    }
                    if !controller.chatStore.isStreaming, !composing, committedCJK >= 2 {
                        print("during a \(reply.count)-char reply: \(field.string.count) chars in the draft, "
                              + "\(committedCJK) IME compositions survived and committed")
                        // isStreaming must drop when the NETWORK turn ends, not when
                        // the typewriter finishes revealing: while it is true the send
                        // button is a Stop button and Return is a no-op, so a lagging
                        // reveal locked the composer for seconds after the reply had
                        // arrived. Being mid-reveal here is the point of the check.
                        let revealed = controller.chatStore.messages.last(where: { $0.role == .assistant })?.text.count ?? 0
                        let lockedFor = Double(ticksSinceArrival) * 0.4
                        print(String(format: "composer released %.1fs after the last chunk, with %d/%d chars revealed",
                                     lockedFor, revealed, target))
                        if lockedFor > 1.2 {
                            fail(String(format: "composer stayed locked %.1fs after the reply arrived — "
                                        + "isStreaming is tracking the typewriter, not the network", lockedFor))
                        }
                        // Forking mid-reveal: fork() persists the PARENT and then
                        // re-points the store at the branch, so a partial row here
                        // would be frozen into the parent's file and never
                        // corrected — the reply truncated for good.
                        if let replyID = controller.chatStore.messages.last(where: { $0.role == .assistant })?.id {
                            let parentID = controller.chatStore.conversationID
                            controller.chatStore.fork(at: replyID)
                            let onDisk = ConversationStore.loadResolved(id: parentID)?.messages
                                .last(where: { $0.role == .assistant })?.text.count ?? 0
                            print("forked mid-reveal: parent holds \(onDisk)/\(target) chars on disk")
                            if onDisk != target {
                                fail("forking mid-reveal persisted a truncated reply (\(onDisk)/\(target) chars)")
                            }
                        }
                        let userRows = controller.chatStore.messages.filter { $0.role == .user }.count
                        controller.chatStore.send("second turn")
                        if controller.chatStore.messages.filter({ $0.role == .user }).count != userRows + 1 {
                            fail("could not start a new turn while the reply was still revealing")
                        }
                        let tail = controller.chatStore.messages.first(where: { $0.id == lastReplyID })?.text.count ?? 0
                        if tail != target {
                            fail("sending mid-reveal left the previous reply truncated (\(tail)/\(target) chars)")
                        }
                        print("PASS")
                        cleanup()
                        exit(0)
                    }
                    lastReplyID = controller.chatStore.messages.last(where: { $0.role == .assistant })?.id
                }
            }
        }
        app.run()
    }
}

// ⌘Y history popover: asserts the shortcut opens it, that the filter field takes
// focus, and that ↓/↩ select and open a chat (the popover tears down).
if CommandLine.arguments.contains("--smoke-history") {
    MainActor.assumeIsolated {
        let scratch = installFindConversation()
        for title in ["alpha chat", "beta chat"] {
            ConversationStore.save(Conversation(
                id: UUID(), title: title, updatedAt: Date(),
                messages: [ChatMessage(role: .user, text: title)]
            ))
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let providerStore = ProviderStore()
        let shortcutStore = ShortcutStore()
        let controller = PanelController(providerStore: providerStore, shortcutStore: shortcutStore)
        controller.show()

        func filterField() -> NSTextField? {
            var found: NSTextField?
            func walk(_ view: NSView) {
                if let field = view as? NSTextField, field.placeholderString == "Search chats…" { found = field }
                for sub in view.subviews where found == nil { walk(sub) }
            }
            // Visible windows only: a dismissed popover keeps its window (and
            // view tree) around, so an unfiltered walk still finds the field.
            for window in app.windows where found == nil && window.isVisible {
                walk(window.contentView ?? NSView())
            }
            return found
        }

        func fail(_ message: String) -> Never {
            print("FAIL: \(message)")
            try? FileManager.default.removeItem(at: scratch)
            exit(1)
        }

        var step = 0
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let panel = app.windows.first(where: { $0 is FloatingPanel }) else { return }
                step += 1
                switch step {
                case 1...2:
                    return
                case 3:
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                        windowNumber: panel.windowNumber, context: nil,
                        characters: "y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16
                    ) else { fail("could not synthesize ⌘Y") }
                    if !panel.performKeyEquivalent(with: event) { fail("⌘Y was not handled by the panel") }
                case 4...5:
                    guard let field = filterField() else {
                        if step == 5 { fail("history popover did not appear on ⌘Y") }
                        return // popover animates in; give it one more tick
                    }
                    guard let editor = field.currentEditor(), field.window?.firstResponder === editor else {
                        fail("history filter field did not take first responder")
                    }
                    editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
                    editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                    step = 6
                case 6...7:
                    if filterField() != nil {
                        if step == 7 { fail("↩ did not open the selected chat / dismiss the popover") }
                        return
                    }
                    print("PASS")
                    try? FileManager.default.removeItem(at: scratch)
                    exit(0)
                default:
                    fail("harness ran past its steps")
                }
            }
        }
        app.run()
    }
}

// ⌘F find-in-chat: drives the real panel through open → type → step → close and
// asserts the find field takes focus, that stepping matches moves the transcript
// scroller, and that ⎋ tears the bar down again.
if CommandLine.arguments.contains("--smoke-find") {
    MainActor.assumeIsolated {
        let scratch = installFindConversation()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let providerStore = ProviderStore()
        let shortcutStore = ShortcutStore()
        let controller = PanelController(providerStore: providerStore, shortcutStore: shortcutStore)
        controller.show()

        func findField(in root: NSView?) -> NSTextField? {
            var found: NSTextField?
            func walk(_ view: NSView) {
                if let field = view as? NSTextField, field.placeholderString == "Find in chat" { found = field }
                for sub in view.subviews where found == nil { walk(sub) }
            }
            if let root { walk(root) }
            return found
        }

        func fail(_ message: String) -> Never {
            print("FAIL: \(message)")
            try? FileManager.default.removeItem(at: scratch)
            exit(1)
        }

        /// Every painted highlight in the transcript, as (field, rect in field
        /// coordinates). Laid out independently of the app's own reveal code so
        /// the check isn't just the implementation agreeing with itself.
        func highlights(in root: NSView?) -> [(field: NSTextField, rect: NSRect, active: Bool)] {
            var result: [(NSTextField, NSRect, Bool)] = []
            func walk(_ view: NSView) {
                if let field = view as? NSTextField, field.isSelectable {
                    let attributed = field.attributedStringValue
                    attributed.enumerateAttribute(
                        .backgroundColor,
                        in: NSRange(location: 0, length: attributed.length)
                    ) { value, range, _ in
                        guard let color = value as? NSColor else { return }
                        let storage = NSTextStorage(attributedString: attributed)
                        let manager = NSLayoutManager()
                        let container = NSTextContainer(size: NSSize(
                            width: field.bounds.width, height: .greatestFiniteMagnitude
                        ))
                        container.lineFragmentPadding = 0
                        manager.addTextContainer(container)
                        storage.addLayoutManager(manager)
                        manager.ensureLayout(for: container)
                        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
                        let top = field.isFlipped ? bounds.minY : field.bounds.height - bounds.maxY
                        result.append((
                            field,
                            NSRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.height),
                            color.alphaComponent > 0.3
                        ))
                    }
                }
                for sub in view.subviews { walk(sub) }
            }
            if let root { walk(root) }
            return result
        }

        func typeQuery(_ query: String) {
            guard let editor = findField(in: NSApp.windows.first(where: { $0 is FloatingPanel })?.contentView)?
                .currentEditor() else { fail("find field vanished") }
            editor.selectAll(nil)
            editor.insertText(query)
        }

        var step = 0
        var offsetAtFirstMatch: CGFloat = 0
        var measurementsBeforeTyping = 0
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let panel = app.windows.first(where: { $0 is FloatingPanel }) else { return }
                let scroll = transcriptScrollView(in: panel.contentView)
                step += 1
                switch step {
                case 1...2:
                    return // let the panel settle
                case 3:
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                        windowNumber: panel.windowNumber, context: nil,
                        characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3
                    ) else { fail("could not synthesize ⌘F") }
                    if !panel.performKeyEquivalent(with: event) { fail("⌘F was not handled by the panel") }
                case 4:
                    guard let field = findField(in: panel.contentView) else { fail("find bar did not appear on ⌘F") }
                    guard let editor = field.currentEditor(), panel.firstResponder === editor else {
                        fail("find field did not take first responder")
                    }
                    measurementsBeforeTyping = SelectableText.measurementCount
                    editor.insertText("needle")
                case 5:
                    guard let scroll else { fail("no transcript scroll view") }
                    // Highlights must be painted in place, and exactly one of
                    // them is the active hit.
                    let painted = highlights(in: panel.contentView)
                    let active = painted.filter(\.active)
                    print("painted highlights=\(painted.count) active=\(active.count)")
                    // 4: messages 1, 4 and 7 carry "needleN", plus "tailneedle".
                    if painted.count != 4 { fail("expected 4 painted matches, got \(painted.count)") }
                    if active.count != 1 { fail("expected exactly 1 active match, got \(active.count)") }
                    offsetAtFirstMatch = scroll.contentView.bounds.origin.y
                    guard let editor = findField(in: panel.contentView)?.currentEditor() else {
                        fail("find field vanished mid-search")
                    }
                    // doCommand routes through the field editor's delegate — the
                    // same path a real ↓ keypress takes.
                    editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
                case 6:
                    guard let scroll else { fail("no transcript scroll view") }
                    let moved = abs(scroll.contentView.bounds.origin.y - offsetAtFirstMatch)
                    print(String(format: "match 1 at offset %.0f, ↓ moved %.0f pt", offsetAtFirstMatch, moved))
                    if moved < 20 { fail("stepping to the next match did not scroll the transcript") }
                    // The exactness check: this needle sits at the END of a
                    // multi-page message.
                    typeQuery("tailneedle")
                case 7:
                    guard let scroll, let document = scroll.documentView else { fail("no transcript scroll view") }
                    let painted = highlights(in: panel.contentView)
                    guard painted.count == 1, let hit = painted.first else {
                        fail("expected 1 match for the tail needle, got \(painted.count)")
                    }
                    let inDocument = hit.field.convert(hit.rect, to: document)
                    let visible = scroll.documentVisibleRect
                    print(String(format: "tail hit y=%.0f (h=%.0f) visible %.0f…%.0f",
                                 inDocument.midY, hit.field.frame.height, visible.minY, visible.maxY))
                    if !visible.insetBy(dx: 0, dy: -1).intersects(inDocument) {
                        fail("the matched characters are off screen — scrolled to the message, not the hit")
                    }
                    let typed = SelectableText.measurementCount - measurementsBeforeTyping
                    print("transcript measurements during find typing=\(typed)")
                    if typed > 8 { fail("highlighting re-measured the transcript (\(typed) measurements)") }
                    guard let editor = findField(in: panel.contentView)?.currentEditor() else {
                        fail("find field vanished before ⎋")
                    }
                    editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                case 8:
                    if findField(in: panel.contentView) != nil { fail("⎋ did not close the find bar") }
                    if !panel.isVisible { fail("⎋ closed the panel instead of the find bar") }
                    // Same IME rule as the composer, other widget: searching in
                    // Chinese means composing in this field while the transcript
                    // may re-render underneath it.
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                        windowNumber: panel.windowNumber, context: nil,
                        characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3
                    ) else { fail("could not synthesize ⌘F") }
                    _ = panel.performKeyEquivalent(with: event)
                case 9:
                    guard let editor = findField(in: panel.contentView)?.currentEditor() as? NSTextView else {
                        fail("find field did not reopen")
                    }
                    editor.setMarkedText(
                        "zhong", selectedRange: NSRange(location: 5, length: 0),
                        replacementRange: NSRange(location: NSNotFound, length: 0)
                    )
                    if !editor.hasMarkedText() { fail("could not start a composition in the find field") }
                    controller.chatStore.send("/nope") // rows appear → the whole panel re-renders
                case 10:
                    guard let editor = findField(in: panel.contentView)?.currentEditor() as? NSTextView else {
                        fail("find field vanished mid-composition")
                    }
                    if !editor.hasMarkedText() {
                        fail("IME composition in the find field was cancelled by a transcript update "
                             + "(now \(editor.string.debugDescription))")
                    }
                    print("find-field IME composition survived a transcript update")
                    print("PASS")
                    try? FileManager.default.removeItem(at: scratch)
                    exit(0)
                default:
                    fail("harness ran past its steps")
                }
            }
        }
        app.run()
    }
}

// Accent-color laws (no GUI, no network): .build/debug/Mia --smoke-accent
//
// The custom accent turns any hex into HSB and back on every popover open, so
// that round trip has to be lossless; and the reason the picker is hand-rolled
// at all is that a color leaving 0…1 packs into #FFFFFF (the system color
// panel's extended-range colors did exactly that — "my accent turns white").
if CommandLine.arguments.contains("--smoke-accent") {
    func fail(_ message: String) -> Never {
        print("FAIL: \(message)")
        exit(1)
    }

    // 1. HSB → hex → HSB is stable at 8-bit precision.
    var checked = 0
    for hueStep in 0...20 {
        for saturation in [0.15, 0.5, 0.85, 1.0] {
            for brightness in [0.2, 0.6, 1.0] {
                let hue = Double(hueStep) / 20
                let first = Theme.hex(hue: hue, saturation: saturation, brightness: brightness)
                let (h, s, b) = Theme.hsb(first)
                let second = Theme.hex(hue: h, saturation: s, brightness: b)
                guard first == second else {
                    fail("hsb round trip drifted: \(first) → \(second) (h\(hue) s\(saturation) b\(brightness))")
                }
                guard first.count == 7, first.hasPrefix("#"), UInt64(first.dropFirst(), radix: 16) != nil else {
                    fail("emitted malformed hex \(first)")
                }
                checked += 1
            }
        }
    }

    // 2. Out-of-range input clamps instead of overflowing the hex. This is the
    //    white bug in miniature: 1.4 × 255 = 357 formatted as %02X is "165",
    //    which shifts every channel and reads back as a different color.
    //    Hue is an angle and WRAPS (1.4 → 0.4); saturation and brightness clamp.
    let clamped = Theme.hex(hue: 1.4, saturation: 2, brightness: 3)
    guard clamped == Theme.hex(hue: 0.4, saturation: 1, brightness: 1) else {
        fail("out-of-range HSB did not wrap hue / clamp saturation+brightness: \(clamped)")
    }
    for (hue, saturation, brightness) in [(1.4, 2.0, 3.0), (-0.3, -1.0, -2.0), (7.5, 0.5, 9.0)] {
        let hex = Theme.hex(hue: hue, saturation: saturation, brightness: brightness)
        guard hex.count == 7, UInt64(hex.dropFirst(), radix: 16) != nil else {
            fail("out-of-range HSB emitted malformed hex \(hex)")
        }
    }

    // 3. A malformed stored value falls back to the default accent, not black.
    let fallback = Theme.components(Theme.defaultAccentHex)
    for bad in ["", "#12", "#GGGGGG", "0A84FF00", "not a color"] {
        let parsed = Theme.components(bad)
        guard parsed == fallback else { fail("bad hex \(bad.isEmpty ? "<empty>" : bad) did not fall back to the default accent") }
    }
    guard Theme.components("#0a84ff") == Theme.components("#0A84FF") else { fail("hex parsing is case-sensitive") }

    // 4. Filled bubbles pick the more legible of black/white. Pale accents are
    //    exactly what fixed white text got wrong; mid-tone blues and purples are
    //    what a pure max-WCAG-ratio rule gets wrong in the other direction.
    let expectations: [(String, NSColor)] = [
        ("#FFFFFF", .black), ("#FFD60A", .black), ("#30D158", .black),
        ("#FF9F0A", .black), ("#9BE8F0", .black),
        ("#000000", .white), ("#0A84FF", .white), ("#BF5AF2", .white),
        ("#FF3B30", .white), ("#5A2AA0", .white),
    ]
    for (hex, expected) in expectations {
        let picked = Theme.contrastingNSColor(on: hex)
        guard picked == expected else {
            fail("\(hex) picked \(picked == NSColor.white ? "white" : "black") text")
        }
    }
    // The decision must be monotonic in lightness — one flip along a ramp, white
    // below and black above. An oscillating rule would strobe while dragging the
    // Brightness slider.
    for hue in [0.0, 0.25, 0.6, 0.85] {
        let decisions = (0...20).map { step -> Bool in
            let hex = Theme.hex(hue: hue, saturation: 0.7, brightness: Double(step) / 20)
            return Theme.contrastingNSColor(on: hex) == NSColor.black
        }
        // Brightness 0 is black, so every ramp starts on white text; saturated
        // reds and blues stay there even at full brightness (they are still
        // perceptually dark), so the flip to black is allowed, not required.
        guard decisions.first == false else { fail("hue \(hue): a black fill must take white text") }
        let flips = zip(decisions, decisions.dropFirst()).filter { $0 != $1 }.count
        guard flips <= 1 else { fail("hue \(hue): text color flipped \(flips) times along a brightness ramp") }
    }
    guard Theme.bubbleForegroundNSColor(style: .accentTint, accentHex: "#FFD60A") == .labelColor else {
        fail("tinted bubbles must keep label color — the fill is mostly panel")
    }

    // 5. Bubble-style migration: "quietGray" is gone, and decodes to the default.
    guard BubbleStyle(rawValue: "quietGray") == nil else { fail("quietGray is still a case") }
    guard BubbleStyle(rawValue: "quietGray") ?? .accentTint == .accentTint else { fail("quietGray must fall back to accentTint") }

    print("OK: \(checked) HSB round trips, clamping, hex fallbacks, contrast and bubble-style migration")
    exit(0)
}

// Attachment-capability laws (no GUI, no network, no defaults touched):
//   .build/debug/Mia --smoke-attach-caps
//
// The 2026-07-23 capability design in miniature: resolution priority (manual
// exception > learned > authoritative metadata > kind default), images always
// sent, PDFs passed through as files exactly when the resolved answer says so,
// rejection attribution from STRUCTURED error fields only, manual exceptions
// sticking over learned ones, and OpenRouter modality decoding.
if CommandLine.arguments.contains("--smoke-attach-caps") {
    func fail(_ message: String) -> Never {
        print("FAIL: \(message)")
        exit(1)
    }

    // 1. Resolution chain: each field independently walks exception > metadata >
    //    default — an exception about images must not erase file metadata.
    let chain = ProviderStore.resolveCapabilities(
        exception: CapabilityException(images: false, files: nil, source: .learned),
        metadata: ModelCapabilities(images: true, files: true),
        kindDefault: AttachmentCapabilities(images: nil, files: false)
    )
    guard chain.images == false else { fail("exception must beat metadata for its own field") }
    guard chain.files == true else { fail("an images exception erased file metadata") }
    let bare = ProviderStore.resolveCapabilities(
        exception: nil, metadata: nil,
        kindDefault: AttachmentCapabilities(images: nil, files: false)
    )
    guard bare.images == nil, bare.files == false else { fail("kind default must answer when nothing else does") }

    // 2. Kind defaults: OpenAI preset fully capable (its API has no metadata to
    //    ask); custom endpoints optimistic on images and toggle-gated on files;
    //    the two Codex routes vision-only.
    let openAI = Provider(id: UUID(), name: "OpenAI", baseURL: "https://api.openai.com/v1", isPreset: true, defaultModel: "gpt-4o")
    guard ProviderStore.kindDefaultCapabilities(for: openAI, pdfPassThrough: false) == AttachmentCapabilities(images: true, files: true) else {
        fail("OpenAI preset must default to images+files")
    }
    let custom = Provider(id: UUID(), name: "Custom", baseURL: "https://example.com/v1", isPreset: false, defaultModel: "")
    guard ProviderStore.kindDefaultCapabilities(for: custom, pdfPassThrough: false) == AttachmentCapabilities(images: nil, files: false),
          ProviderStore.kindDefaultCapabilities(for: custom, pdfPassThrough: true) == AttachmentCapabilities(images: nil, files: true) else {
        fail("custom endpoints must be images-unknown and files-per-toggle")
    }
    let chatGPT = Provider(id: UUID(), name: "sub", baseURL: "", isPreset: true, defaultModel: "", kind: .chatGPT)
    guard ProviderStore.kindDefaultCapabilities(for: chatGPT, pdfPassThrough: true) == AttachmentCapabilities(images: true, files: false) else {
        fail("subscription routes must be vision-only regardless of any toggle")
    }

    // 3. wireContent: a PDF becomes a native file part exactly when files ==
    //    true, its extracted text otherwise — and images are ALWAYS sent, even
    //    to a model recorded as refusing them (the warning lives in the
    //    composer; silently dropping them is the one forbidden outcome).
    let pdfMessage = ChatMessage(
        role: .user, text: "read this",
        attachments: [Attachment(
            filename: "doc.pdf",
            content: .pdf(dataURL: "data:application/pdf;base64,QUJD", extractedText: "extracted words"),
            note: nil
        )]
    )
    let asFile = ChatStore.wireContent(for: pdfMessage, capabilities: AttachmentCapabilities(images: nil, files: true))
    guard case .parts(let fileParts) = asFile,
          let filePart = fileParts.first(where: { $0.type == "file" }),
          filePart.file?.filename == "doc.pdf",
          filePart.file?.fileData == "data:application/pdf;base64,QUJD" else {
        fail("files==true must send the original PDF as a file part")
    }
    if case .parts(let parts) = asFile, parts.contains(where: { $0.text?.contains("extracted words") == true }) {
        fail("pass-through must not ALSO inline the extraction")
    }
    let asText = ChatStore.wireContent(for: pdfMessage, capabilities: AttachmentCapabilities(images: nil, files: false))
    guard case .text(let inlined) = asText, inlined.contains("extracted words"), inlined.contains("doc.pdf") else {
        fail("files==false must inline the extracted text")
    }
    let scanned = ChatMessage(
        role: .user, text: "",
        attachments: [Attachment(
            filename: "scan.pdf",
            content: .pdf(dataURL: "data:application/pdf;base64,QUJD", extractedText: ""),
            note: nil
        )]
    )
    guard case .text(let absence) = ChatStore.wireContent(for: scanned, capabilities: AttachmentCapabilities(images: nil, files: false)),
          absence.contains("could not be included") else {
        fail("a textless PDF on a text-only path must state its absence, not send an empty block")
    }
    let imageMessage = ChatMessage(
        role: .user, text: "look",
        attachments: [Attachment(filename: "shot.png", content: .image(dataURL: "data:image/jpeg;base64,QUJD"), note: nil)]
    )
    guard case .parts(let imageParts) = ChatStore.wireContent(for: imageMessage, capabilities: AttachmentCapabilities(images: false, files: false)),
          imageParts.contains(where: { $0.type == "image_url" }) else {
        fail("images must be sent even when the model is recorded as refusing them")
    }

    // 4. Attribution: structured fields only. A param path naming the exact part
    //    index resolves against what WE sent there; prose alone learns nothing;
    //    and nothing is ever attributed to a kind the request didn't carry.
    let sentHistory: [OpenAIChatClient.WireMessage] = [
        .init(role: "system", content: .text("prompt")),
        .init(role: "user", content: .parts([
            .imageDataURL("data:image/jpeg;base64,QUJD"),
            .fileDataURL(filename: "doc.pdf", dataURL: "data:application/pdf;base64,QUJD"),
            .text("hello"),
        ])),
    ]
    let paramBody = #"{"error":{"message":"whatever prose","type":"invalid_request_error","param":"messages.[1].content.[0].type","code":null}}"#
    guard OpenAIChatClient.attributeContentRejection(statusCode: 400, errorBody: paramBody, messages: sentHistory) == .images else {
        fail("a param naming the image part's index must attribute to images")
    }
    let fileParamBody = #"{"error":{"message":"x","param":"messages[1].content[1]","code":null}}"#
    guard OpenAIChatClient.attributeContentRejection(statusCode: 400, errorBody: fileParamBody, messages: sentHistory) == .files else {
        fail("a param naming the file part's index must attribute to files")
    }
    let proseBody = #"{"error":{"message":"this model does not support image input","param":null,"code":"invalid_request_error"}}"#
    guard OpenAIChatClient.attributeContentRejection(statusCode: 400, errorBody: proseBody, messages: sentHistory) == nil else {
        fail("prose-only errors must not be attributed — message text is never matched")
    }
    let textOnly: [OpenAIChatClient.WireMessage] = [.init(role: "user", content: .text("hi"))]
    guard OpenAIChatClient.attributeContentRejection(statusCode: 400, errorBody: paramBody, messages: textOnly) == nil else {
        fail("a request without typed parts can never be attributed")
    }
    guard OpenAIChatClient.attributeContentRejection(statusCode: 500, errorBody: paramBody, messages: sentHistory) == nil else {
        fail("server faults are not capability answers")
    }

    // 5. Exceptions merge per field, and manual is sticky: a later learned
    //    record updates fields but never demotes the source back to learned.
    let learned = ProviderStore.mergedException(nil, capability: .images, supported: false, source: .learned)
    guard learned.images == false, learned.files == nil, learned.source == .learned else { fail("learned record malformed") }
    let manual = ProviderStore.mergedException(learned, capability: .files, supported: false, source: .manual)
    guard manual.images == false, manual.files == false, manual.source == .manual else { fail("manual must merge onto learned") }
    let after = ProviderStore.mergedException(manual, capability: .images, supported: false, source: .learned)
    guard after.source == .manual else { fail("a learned record must not demote a manual exception") }

    // 6. OpenRouter modality decoding: capabilities exactly for entries that
    //    state them — absence stays absence.
    let fixture = #"{"data":[{"id":"vendor/vision-file","architecture":{"input_modalities":["text","image","file"]}},{"id":"vendor/text-only","architecture":{"input_modalities":["text"]}},{"id":"vendor/unstated"}]}"#
    guard let (ids, capabilities) = try? ProviderStore.decodeModelList(Data(fixture.utf8)) else {
        fail("model-list fixture failed to decode")
    }
    guard ids == ["vendor/text-only", "vendor/unstated", "vendor/vision-file"] else { fail("ids wrong: \(ids)") }
    guard capabilities["vendor/vision-file"] == ModelCapabilities(images: true, files: true),
          capabilities["vendor/text-only"] == ModelCapabilities(images: false, files: false),
          capabilities["vendor/unstated"] == nil else {
        fail("modality decoding wrong: \(capabilities)")
    }

    print("OK: resolution chain, kind defaults, wire forms, structured attribution, sticky manual exceptions, modality decoding")
    exit(0)
}

// Drop-target laws (no GUI, no network): .build/debug/Mia --smoke-drop
//
// "Drag a fresh screenshot in" is a FILE-PROMISE drag: the PNG doesn't exist
// on disk until the destination receives the promise, so the old URL-only
// `.dropDestination(for: URL.self)` ignored it — that was the bug. In-process
// promise RESOLUTION cannot be simulated (the pasteboard server never calls a
// source back inside its own process — verified while writing this), so the
// promise law checks acceptance and that the receive was initiated; a live
// screenshot-thumbnail drag is the end-to-end check.
if CommandLine.arguments.contains("--smoke-drop") {
    MainActor.assumeIsolated {
        func fail(_ message: String) -> Never {
            print("FAIL: \(message)")
            exit(1)
        }
        func pump(timeout: TimeInterval, until check: () -> Bool, what: String) {
            let deadline = Date().addingTimeInterval(timeout)
            while !check() {
                guard Date() < deadline else { fail("timed out waiting for \(what)") }
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        final class PromiseSource: NSObject, NSFilePromiseProviderDelegate {
            func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
                "Screenshot Smoke.png"
            }
            func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
                // Never reached in-process; the law only needs the promise on
                // the pasteboard to be well-formed.
                completionHandler(NSError(domain: "smoke-drop", code: 1))
            }
        }
        func scratchPasteboard(_ suffix: String) -> NSPasteboard {
            let pasteboard = NSPasteboard(name: .init("mia-smoke-drop-\(suffix)-\(ProcessInfo.processInfo.processIdentifier)"))
            pasteboard.clearContents()
            return pasteboard
        }

        let view = PanelDropView()
        let model = ComposerModel()
        view.onFileURLs = { model.handleFiles($0) }
        view.onImage = { model.handleImage($0, suggestedName: "dropped-image.jpg") }
        view.onError = { model.attachNotice = $0 }

        // 1. Registration: refuse any of these types and the drag never even
        //    highlights the panel. The promise list is the screenshot thumbnail.
        let registered = Set(view.registeredDraggedTypes.map(\.rawValue))
        for type in NSFilePromiseReceiver.readableDraggedTypes where !registered.contains(type) {
            fail("not registered for promise type \(type) — a screenshot-thumbnail drag would be refused")
        }
        for type in [NSPasteboard.PasteboardType.fileURL, .png, .tiff] where !registered.contains(type.rawValue) {
            fail("not registered for \(type.rawValue)")
        }

        // 2. A promise-only drag (the screenshot thumbnail) is accepted and
        //    initiates a receive; nothing attaches synchronously.
        let promiseSource = PromiseSource()
        let promisePasteboard = scratchPasteboard("promise")
        guard promisePasteboard.writeObjects([NSFilePromiseProvider(fileType: "public.png", delegate: promiseSource)]) else {
            fail("couldn't write a file promise to the scratch pasteboard")
        }
        guard view.accepts(promisePasteboard) else { fail("a file-promise drag is not accepted") }
        guard view.handleDrop(from: promisePasteboard) else { fail("a file-promise drop was not handled") }
        guard model.pendingAttachments.isEmpty else { fail("a promise drop attached synchronously — it must wait for the promised file") }
        guard let promiseDestination = view.lastPromiseDestination,
              FileManager.default.fileExists(atPath: promiseDestination.path) else {
            fail("a promise drop did not initiate a receive into a destination directory")
        }

        // 3. A plain file-URL drag still attaches end-to-end.
        let textURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mia-smoke-drop-\(ProcessInfo.processInfo.processIdentifier).txt")
        do { try "drop smoke".write(to: textURL, atomically: true, encoding: .utf8) } catch {
            fail("couldn't write scratch file: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: textURL) }
        let filePasteboard = scratchPasteboard("file")
        guard filePasteboard.writeObjects([textURL as NSURL]) else { fail("couldn't write the file URL") }
        guard view.accepts(filePasteboard), view.handleDrop(from: filePasteboard) else { fail("a file-URL drop was not handled") }
        pump(timeout: 5, until: { !model.pendingAttachments.isEmpty }, what: "the file-URL attachment")
        guard case .text(let text) = model.pendingAttachments[0].content, text.contains("drop smoke") else {
            fail("the file-URL drop did not attach the file's text")
        }

        // 4. Raw image data with no file behind it (browser image drags; also
        //    the screenshot path on pasteboards that carry bitmap data).
        model.clear()
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        let imagePasteboard = scratchPasteboard("image")
        guard imagePasteboard.writeObjects([image]) else { fail("couldn't write the image") }
        guard view.accepts(imagePasteboard), view.handleDrop(from: imagePasteboard) else { fail("a raw-image drop was not handled") }
        guard model.pendingAttachments.count == 1, case .image = model.pendingAttachments[0].content else {
            fail("the raw-image drop did not attach an image")
        }

        // 5. Priority: file URLs beat promises (no pointless copy through the
        //    temp dir) and beat image data (a Finder drag can carry the file
        //    icon as an image — matching images first would attach the icon).
        model.clear()
        let mixedPasteboard = scratchPasteboard("mixed")
        guard mixedPasteboard.writeObjects([
            textURL as NSURL,
            NSFilePromiseProvider(fileType: "public.png", delegate: promiseSource),
            image,
        ]) else { fail("couldn't write the mixed drag") }
        guard view.handleDrop(from: mixedPasteboard) else { fail("the mixed drop was not handled") }
        pump(timeout: 5, until: { !model.pendingAttachments.isEmpty }, what: "the mixed-drop attachment")
        guard model.pendingAttachments.count == 1, case .text = model.pendingAttachments[0].content else {
            fail("a drag carrying a file URL must attach the file, not the image data")
        }
        guard view.lastPromiseDestination == promiseDestination else {
            fail("a drag carrying a file URL must not also receive its file promise")
        }

        // 6. A text-only drag is someone dragging selected text — not ours.
        let stringPasteboard = scratchPasteboard("string")
        stringPasteboard.setString("just text", forType: .string)
        guard !view.accepts(stringPasteboard) else { fail("a text-only drag must not be accepted") }
        guard !view.handleDrop(from: stringPasteboard) else { fail("a text-only drop must not be handled") }

        print("OK: promise accepted + receive initiated, file URL and raw image attach, URL-first priority, text refused")
        exit(0)
    }
}

// Attach-notice guard: builds the REAL empty panel and drops unsupported
// .pptx files through the real PanelDropView path, so the failure notice
// renders exactly as a user sees it. The law: a notice is never
// height-compressed — the empty panel's height FOLLOWS measured content, so a
// Text that yields to the still-short window truncates (or paints past the
// card) and the height report never learns the missing lines. Discriminator:
// a long notice must settle TALLER than a short one; under the bug both
// truncate to the same single line and the delta collapses to zero.
// `--smoke-notice [png-path]` (optional PNG for eyeballing). A GUI harness —
// run it alone, like the other panel harnesses.
if let noticeIndex = CommandLine.arguments.firstIndex(of: "--smoke-notice") {
    MainActor.assumeIsolated {
        var pngPath: String?
        if CommandLine.arguments.count > noticeIndex + 1,
           !CommandLine.arguments[noticeIndex + 1].hasPrefix("--") {
            pngPath = CommandLine.arguments[noticeIndex + 1]
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)

        // Narrow width so the notice wraps; solid panel so the offscreen bitmap
        // is readable (glass has no backdrop to composite there).
        let defaults = UserDefaults.standard
        let priorWidth = defaults.object(forKey: "panelWidth")
        let priorGlass = defaults.object(forKey: "liquidGlass")
        defaults.set(520, forKey: "panelWidth")
        defaults.set(false, forKey: "liquidGlass")

        let controller = PanelController(providerStore: ProviderStore(), shortcutStore: ShortcutStore())
        controller.chatStore.newChat()
        controller.show()

        // Width is read once at panel init — safe to put back now. liquidGlass is
        // live @AppStorage: restoring it early would flip the panel back to glass
        // mid-run, so it goes back on the way out.
        if let priorWidth { defaults.set(priorWidth, forKey: "panelWidth") } else { defaults.removeObject(forKey: "panelWidth") }
        @MainActor func finish(_ code: Int32) -> Never {
            if let priorGlass { defaults.set(priorGlass, forKey: "liquidGlass") } else { defaults.removeObject(forKey: "liquidGlass") }
            exit(code)
        }

        @MainActor func findDropView(_ view: NSView?) -> PanelDropView? {
            guard let view else { return nil }
            if let drop = view as? PanelDropView { return drop }
            for sub in view.subviews { if let found = findDropView(sub) { return found } }
            return nil
        }

        // The refusal keys on NUL bytes (loadPlainText), not the extension —
        // a zip-style header with zeros is what makes the fake decks "binary".
        let names = ["SkVM_ 7-11.pptx",
                     "A quarterly all-hands deck with a truly unreasonable filename 2026-07 final v3.pptx"]
        let files = names.map { FileManager.default.temporaryDirectory.appendingPathComponent($0) }
        for file in files {
            try? Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]).write(to: file)
        }
        @MainActor func cleanUpFiles() {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }

        @MainActor func drop(_ file: URL) {
            guard let panel = app.windows.first(where: { $0 is FloatingPanel }),
                  let view = findDropView(panel.contentView) else {
                print("FAIL: no panel or drop view"); cleanUpFiles(); finish(1)
            }
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("mia-smoke-notice"))
            pasteboard.clearContents()
            pasteboard.writeObjects([file as NSURL])
            guard view.handleDrop(from: pasteboard) else {
                print("FAIL: drop not handled"); cleanUpFiles(); finish(1)
            }
        }
        @MainActor func settledHeight() -> CGFloat {
            guard let panel = app.windows.first(where: { $0 is FloatingPanel }) else {
                print("FAIL: no panel"); cleanUpFiles(); finish(1)
            }
            return panel.contentRect(forFrameRect: panel.frame).height
        }

        var shortHeight: CGFloat = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated { drop(files[0]) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            MainActor.assumeIsolated {
                shortHeight = settledHeight()
                drop(files[1])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            MainActor.assumeIsolated {
                let longHeight = settledHeight()
                if let pngPath,
                   let panel = app.windows.first(where: { $0 is FloatingPanel }),
                   let view = panel.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: pngPath))
                        print("wrote \(pngPath)")
                    }
                }
                cleanUpFiles()
                print("short-notice contentH=\(Int(shortHeight)) long-notice contentH=\(Int(longHeight))")
                // One extra wrapped line is ~14pt; a compressed notice collapses
                // the delta to ~0 because both truncate to the same height.
                guard longHeight - shortHeight >= 10 else {
                    print("FAIL: a longer notice must grow the panel — it is being truncated")
                    finish(1)
                }
                print("PASS")
                finish(0)
            }
        }
        app.run()
    }
}

// Design QA: renders a view to PNG in-process (`--shot <settings|switcher> <path>`),
// so the layout can be checked without screen-recording permission.
if let shotIndex = CommandLine.arguments.firstIndex(of: "--shot"),
   CommandLine.arguments.count > shotIndex + 2 {
    MainActor.assumeIsolated {
        let which = CommandLine.arguments[shotIndex + 1]
        let path = CommandLine.arguments[shotIndex + 2]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--dark") {
            app.appearance = NSAppearance(named: .darkAqua)
        } else if CommandLine.arguments.contains("--light") {
            app.appearance = NSAppearance(named: .aqua)
        }

        let defaults = UserDefaults.standard
        let providerKeys = [
            "providersJSON", "selectedProviderID", "knownModelsJSON", "selectedModelsJSON",
            "knownModelEffortsJSON", "defaultModelEffortsJSON", "selectedModelEffortsJSON",
            "accentColor", "customAccentColor", "bubbleStyle", "liquidGlass",
        ]
        let snapshot = providerKeys.reduce(into: [String: Any?]()) { $0[$1] = defaults.object(forKey: $1) }
        func restore() {
            for key in providerKeys {
                if let value = snapshot[key] ?? nil { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        // A custom accent already chosen, so the row renders its selected state
        // (`--no-custom` renders the untouched state instead).
        if which == "general", !CommandLine.arguments.contains("--no-custom") {
            // `--accent <hex>` overrides, for checking a fill's text color.
            var accent = "#E0655B"
            if let index = CommandLine.arguments.firstIndex(of: "--accent"),
               CommandLine.arguments.count > index + 1 {
                accent = CommandLine.arguments[index + 1]
            }
            defaults.set(accent, forKey: "accentColor")
            defaults.set(accent, forKey: "customAccentColor")
            if CommandLine.arguments.contains("--fill") {
                defaults.set(BubbleStyle.accentFill.rawValue, forKey: "bubbleStyle")
            }
        }

        let store = ProviderStore()
        let deepseek = Provider(id: UUID(), name: "DeepSeek", baseURL: "https://api.deepseek.com", isPreset: true, defaultModel: "deepseek-chat")
        let chatgpt = ProviderStore.chatGPTPreset()
        let router = Provider(id: UUID(), name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", isPreset: true, defaultModel: "openrouter/auto")
        let ollama = Provider(id: UUID(), name: "Ollama (local)", baseURL: "http://localhost:11434/v1", isPreset: true, defaultModel: "")
        // Template-born (freeTemplate) so the settings shot exercises the Free
        // badge and the get-a-key band notice.
        let groq = Provider(id: UUID(), name: "Groq", baseURL: "https://api.groq.com/openai/v1", isPreset: false, defaultModel: "llama-3.3-70b", freeTemplate: "Groq")
        store.providers = [chatgpt, deepseek, groq, router, ollama]
        store.knownModels = [
            chatgpt.id: ChatGPTAuth.modelCatalog,
            deepseek.id: ["deepseek-chat", "deepseek-coder", "deepseek-reasoner"],
            groq.id: ["llama-3.3-70b", "mixtral-8x7b"],
        ]
        store.knownModelEfforts = [chatgpt.id: Dictionary(uniqueKeysWithValues: ChatGPTAuth.modelCatalog.map {
            ($0, ChatGPTAuth.supportedReasoningEfforts(for: $0))
        })]
        store.defaultModelEfforts = [chatgpt.id: Dictionary(uniqueKeysWithValues: ChatGPTAuth.modelCatalog.compactMap { model in
            ChatGPTAuth.defaultReasoningEffort(for: model).map { (model, $0) }
        })]
        store.selectedModels = [
            chatgpt.id: ChatGPTAuth.defaultModel,
            deepseek.id: "deepseek-chat",
            groq.id: "llama-3.3-70b",
        ]
        store.selectedID = which == "switcher-effort" ? chatgpt.id : deepseek.id

        let content: NSView
        let size: NSSize
        switch which {
        case "switcher", "switcher-effort":
            content = NSHostingView(rootView: ProviderSwitcher(store: store)
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor)))
            size = NSSize(width: which == "switcher-effort" ? 530 : 412, height: 340)
        case "general":
            content = NSHostingView(rootView: SettingsView(
                store: store, shortcutStore: ShortcutStore(), personaStore: PersonaStore(),
                updates: UpdateChecker(), tab: .general
            ))
            size = NSSize(width: 540, height: 620)
        case "about":
            content = NSHostingView(rootView: SettingsView(
                store: store, shortcutStore: ShortcutStore(), personaStore: PersonaStore(),
                updates: UpdateChecker(), tab: .about
            ))
            size = NSSize(width: 540, height: 620)
        case "chat":
            content = NSHostingView(rootView: SettingsView(
                store: store, shortcutStore: ShortcutStore(), personaStore: PersonaStore(),
                updates: UpdateChecker(), tab: .chat
            ))
            size = NSSize(width: 540, height: 620)
        case "thinking":
            // The waiting row mid-think, so the scrolling window and its expand
            // control can be eyeballed. Rendered directly — it is a plain view,
            // so this needs no production seam and no live provider.
            let thought = """
            **Considering the physics**

            Rayleigh scattering goes as 1/λ⁴, so shorter wavelengths scatter far more \
            than longer ones. That is why the daytime sky reads blue rather than violet — \
            the eye's sensitivity peaks away from violet, and some of it is absorbed high up.

            The answer should stay short: this is a quick-chat panel, not an optics lecture.
            """
            content = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
                WaitingIndicator(status: "Thinking…", reasoning: thought)
                Divider()
                // The expanded window, which the shot cannot click into.
                ThinkingScroller(text: thought, lines: WaitingIndicator.expandedLines)
                Divider()
                WaitingIndicator(status: "Starting Codex…")
            }
                .padding(20)
                .frame(width: 460, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor)))
            size = NSSize(width: 460, height: 420)
        case "accent":
            content = NSHostingView(rootView: AccentPickerPopover(
                accentHex: .constant("#E0655B"), customHex: .constant("#E0655B")
            )
                .background(Color(nsColor: .windowBackgroundColor)))
            size = NSSize(width: 268, height: 190)
        case "transcript":
            // A finished turn with thinking attached, so the reasoning
            // disclosure and the last row's Retry / Edit prompt actions can be
            // eyeballed without driving a live provider. A scratch store keeps
            // the synthetic conversation out of the real history.
            //
            // Solid panel, like --smoke-notice: an offscreen bitmap has no
            // backdrop for glass to composite against, so the dark rendering
            // comes out as a white fog (the light one only looks fine by luck).
            defaults.set(false, forKey: "liquidGlass")
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("mia-shot-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            ConversationStore.overrideDirectory = scratch
            // Seeded the supported way — saved to the scratch store, then
            // resumed by ChatStore.init like every other transcript harness.
            // That also makes the shot exercise `adopt`, the restore reveal and
            // the round-trip decode of `reasoning`, rather than bypassing them.
            ConversationStore.save(Conversation(
                id: UUID(), title: "Why is the sky blue?", updatedAt: Date(),
                messages: [
                    ChatMessage(role: .user, text: "Why is the sky blue?"),
                    ChatMessage(
                        role: .assistant,
                        text: "Shorter wavelengths scatter more in air, so blue light reaches your eyes from every direction.",
                        reasoning: "**Considering the physics**\n\nRayleigh scattering goes as 1/λ⁴, so blue scatters far more than red.\n\nThe answer should stay short — this is a quick-chat panel."
                    ),
                ]
            ))
            let chatStore = ChatStore(providerStore: store, shortcutStore: ShortcutStore())
            content = NSHostingView(rootView: ChatView(
                state: PanelState(), store: chatStore, providerStore: store,
                shortcutStore: ShortcutStore(), onClose: {}
            ))
            size = NSSize(width: 560, height: 420)
        case "timeline":
            // Several finished turns so the question timeline has real markers
            // to lay out (idle state only — hover needs a live pointer). Same
            // scratch-store seeding as the transcript case, solid panel.
            defaults.set(false, forKey: "liquidGlass")
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("mia-shot-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            ConversationStore.overrideDirectory = scratch
            func turn(_ q: String, _ a: String) -> [ChatMessage] {
                [ChatMessage(role: .user, text: q), ChatMessage(role: .assistant, text: a)]
            }
            ConversationStore.save(Conversation(
                id: UUID(), title: "Timeline shot", updatedAt: Date(),
                messages: [
                    turn("Why is the sky blue?",
                         "Shorter wavelengths scatter more in air, so blue light reaches your eyes from every direction."),
                    turn("Summarize the theory of relativity in one sentence",
                         "Space and time form a single fabric whose geometry is shaped by mass and energy, and that geometry is what we experience as gravity."),
                    turn("What's a good name for a cat?",
                         "Something short and punchy — Miso, Pixel, or Biscuit all read well when you call them across a room."),
                    turn("Explain HTTP status codes like I'm five",
                         "They're the server's way of answering: 200 means \"here you go\", 404 means \"I looked and found nothing\", 500 means \"I broke\"."),
                    turn("Write a haiku about rain",
                         "Soft grey morning hush / every leaf holds a small sea / then lets it go home."),
                ].flatMap { $0 }
            ))
            let chatStore = ChatStore(providerStore: store, shortcutStore: ShortcutStore())
            content = NSHostingView(rootView: ChatView(
                state: PanelState(), store: chatStore, providerStore: store,
                shortcutStore: ShortcutStore(), onClose: {}
            ))
            size = NSSize(width: 560, height: 560)
        default:
            content = NSHostingView(rootView: SettingsView(
                store: store, shortcutStore: ShortcutStore(), personaStore: PersonaStore(),
                updates: UpdateChecker(), tab: .providers, editing: groq.id
            ))
            size = NSSize(width: 540, height: 620)
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = content
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated {
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    print("FAIL: could not build a bitmap")
                    restore()
                    exit(1)
                }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    print("FAIL: could not encode PNG")
                    restore()
                    exit(1)
                }
                try? data.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
                restore()
                exit(0)
            }
        }
        app.run()
    }
}

// Delta 5's core rule, which is a BEHAVIOUR and not a look: browsing providers
// must never switch what the next message uses. Drives the real 7c switcher
// through provider → model → effort and asserts nothing commits until ↩, then asserts the
// catalog side (addCustom must not select) and that the green-dot predicate and
// the rail agree.
//
// Runs against the real ProviderStore — the provider defaults keys are
// snapshotted and restored on every exit path, and only `.test` base URLs are
// ever installed, so no network and no lasting change to the user's setup.
private actor CodexRefreshProbe {
    private(set) var calls = 0

    func inspect(includeModels: Bool) async throws -> CodexAppServerClient.Inspection {
        calls += 1
        try await Task.sleep(for: .milliseconds(150))
        return CodexAppServerClient.Inspection(
            email: "fake@example.test",
            plan: "test",
            models: includeModels ? ["fake-model"] : [],
            defaultModel: includeModels ? "fake-model" : nil,
            supportedEfforts: includeModels ? ["fake-model": ["low", "high"]] : [:],
            defaultEfforts: includeModels ? ["fake-model": "low"] : [:]
        )
    }
}

// Three simultaneous callers must share one inspection and publish one coherent
// result. This is intentionally independent of a real Codex installation.
if CommandLine.arguments.contains("--smoke-codex-refresh-coalescing") {
    Task { @MainActor in
        let defaults = UserDefaults.standard
        let keys = [
            "providersJSON", "selectedProviderID", "knownModelsJSON", "selectedModelsJSON",
            "knownModelEffortsJSON", "defaultModelEffortsJSON", "selectedModelEffortsJSON",
        ]
        let snapshot = keys.reduce(into: [String: Any?]()) { $0[$1] = defaults.object(forKey: $1) }
        func restore() {
            for key in keys {
                if let value = snapshot[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        let store = ProviderStore()
        let provider = ProviderStore.codexAppServerPreset()
        store.providers = [provider]
        store.selectedID = provider.id
        let probe = CodexRefreshProbe()
        async let first: Void = store.refreshCodexAppServer(
            includeModels: true,
            inspection: { try await probe.inspect(includeModels: $0) }
        )
        async let second: Void = store.refreshCodexAppServer(
            includeModels: true,
            inspection: { try await probe.inspect(includeModels: $0) }
        )
        async let third: Void = store.refreshCodexAppServer(
            includeModels: true,
            inspection: { try await probe.inspect(includeModels: $0) }
        )
        _ = await (first, second, third)

        let calls = await probe.calls
        let ready: Bool
        if case .ready = store.codexAppServerStatus { ready = true } else { ready = false }
        let passed = calls == 1
            && ready
            && store.knownModels[provider.id] == ["fake-model"]
            && !store.fetchingProviders.contains(provider.id)
        print("refresh-calls=\(calls) ready=\(ready) \(passed ? "PASS" : "FAIL")")
        restore()
        exit(passed ? 0 : 1)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--smoke-providers") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let defaults = UserDefaults.standard
        let providerKeys = [
            "providersJSON", "selectedProviderID", "knownModelsJSON", "selectedModelsJSON",
            "knownModelEffortsJSON", "defaultModelEffortsJSON", "selectedModelEffortsJSON",
        ]
        let snapshot = providerKeys.reduce(into: [String: Any?]()) { $0[$1] = defaults.object(forKey: $1) }
        func restore() {
            for key in providerKeys {
                if let value = snapshot[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        func fail(_ message: String) -> Never {
            print("FAIL: \(message)")
            restore()
            exit(1)
        }

        let store = ProviderStore()
        let alpha = Provider(id: UUID(), name: "Harness A", baseURL: "https://a.test/v1", isPreset: true, defaultModel: "a-1")
        let beta = Provider(id: UUID(), name: "Harness B", baseURL: "https://b.test/v1", isPreset: true, defaultModel: "b-1")
        store.providers = [alpha, beta]
        store.knownModels = [alpha.id: ["a-1", "a-2"], beta.id: ["b-1", "b-2"]]
        store.selectedModels = [alpha.id: "a-1", beta.id: "b-1"]
        store.knownModelEfforts = [
            beta.id: ["b-1": ["low", "medium", "high"], "b-2": ["low", "medium", "high"]],
        ]
        store.defaultModelEfforts = [beta.id: ["b-1": "medium", "b-2": "medium"]]
        store.selectedModelEfforts = [:]
        store.selectedID = alpha.id
        guard store.configuredProviders.map(\.id) == [alpha.id, beta.id] else {
            fail("seeded providers are not both offered by the switcher")
        }
        guard store.currentReasoningEffort == nil else {
            fail("provider without effort capabilities acquired an effort value")
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: ProviderSwitcher(store: store))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        /// The switcher's invisible first responder (ProviderSwitcher.KeyCaptureView).
        func captureView() -> NSView? {
            // Match the AppKit view itself, not SwiftUI's representable host —
            // the host's class name embeds the wrapped type's name too.
            var found: NSView?
            func walk(_ view: NSView) {
                if String(describing: type(of: view)).contains("CaptureView"), view.acceptsFirstResponder {
                    found = view
                }
                for sub in view.subviews where found == nil { walk(sub) }
            }
            walk(window.contentView ?? NSView())
            return found
        }

        func send(_ keyCode: UInt16, _ label: String) {
            guard let view = captureView() else { fail("switcher key capture view vanished") }
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
            ) else { fail("could not synthesize \(label)") }
            view.keyDown(with: event)
        }

        var step = 0
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated {
                step += 1
                switch step {
                case 1:
                    return // let the popover body appear and claim first responder
                case 2:
                    guard let view = captureView() else { fail("switcher did not install its key capture view") }
                    guard window.firstResponder === view else {
                        fail("switcher key capture view did not take first responder")
                    }
                    send(125, "↓")             // rail: Harness A → Harness B
                    if store.selectedID != alpha.id {
                        fail("arrowing the provider rail COMMITTED — preview must not switch (delta 5, 7c)")
                    }
                case 3:
                    send(124, "→")             // into the model column
                    send(125, "↓")             // b-1 → b-2
                    if store.selectedID != alpha.id {
                        fail("moving into the model column committed a provider switch")
                    }
                    if store.currentModel != "a-1" {
                        fail("previewing another provider's models changed the live model")
                    }
                case 4:
                    send(124, "→")             // into the effort column (default medium)
                    send(125, "↓")             // medium → high
                    if store.selectedID != alpha.id || store.selectedModelEfforts[beta.id] != nil {
                        fail("previewing effort committed before ↩")
                    }
                case 5:
                    send(36, "↩")
                case 6:
                    if store.selectedID != beta.id { fail("↩ did not commit the previewed provider") }
                    if store.selectedModels[beta.id] != "b-2" { fail("↩ did not commit the focused model") }
                    if store.selectedModelEfforts[beta.id]?["b-2"] != "high" {
                        fail("↩ did not commit the focused effort")
                    }
                    if store.currentConfig()?.reasoningEffort != "high" {
                        fail("committed effort did not reach ProviderConfig")
                    }
                    print("preview stayed inert; ↩ committed Harness B · b-2 · high")

                    // Catalog side (7b): adding a provider in Settings must not
                    // redirect the live conversation.
                    let added = store.addCustom()
                    if store.selectedID != beta.id {
                        fail("addCustom() switched the live provider — Settings must never write selectedID")
                    }
                    store.remove(added)

                    // Free-tier templates (2026-08-04): same never-select law,
                    // unique names on re-add, the origin marker the Free badge
                    // and band notice key on, and sane URLs (chat/completions
                    // and models are appended, so no trailing slash).
                    guard let template = FreeProviderTemplate.all.first else {
                        fail("free template list is empty")
                    }
                    let firstAdd = store.addTemplate(template)
                    let secondAdd = store.addTemplate(template)
                    if store.selectedID != beta.id {
                        fail("addTemplate() switched the live provider — Settings must never write selectedID")
                    }
                    let templateRows = store.providers.filter { [firstAdd, secondAdd].contains($0.id) }
                    if Set(templateRows.map(\.name)).count != 2 {
                        fail("re-adding a template did not unique its name")
                    }
                    if templateRows.contains(where: { $0.freeTemplate != template.name || $0.isPreset }) {
                        fail("template rows must be custom providers carrying their free-tier origin")
                    }
                    for entry in FreeProviderTemplate.all {
                        guard let url = URL(string: entry.baseURL), url.scheme == "https",
                              !(url.host() ?? "").isEmpty, !entry.baseURL.hasSuffix("/") else {
                            fail("free template \(entry.name) has a malformed base URL: \(entry.baseURL)")
                        }
                        if URL(string: entry.keyURL)?.scheme != "https" {
                            fail("free template \(entry.name) has a malformed key URL: \(entry.keyURL)")
                        }
                    }
                    store.remove(firstAdd)
                    store.remove(secondAdd)
                    print("free templates: inert add, unique names, origin marker, sane URLs")

                    // The green dot and the rail are one predicate: every
                    // configured provider is offered, and the only row the rail
                    // adds is the live one.
                    let rail = Set(store.configuredProviders.map(\.id))
                    for provider in store.providers {
                        let configured = store.isConfigured(provider)
                        if configured && !rail.contains(provider.id) {
                            fail("\(provider.name) is green in Settings but missing from the switcher")
                        }
                        if !configured && rail.contains(provider.id) && provider.id != store.selectedID {
                            fail("\(provider.name) is offered by the switcher but gray in Settings")
                        }
                    }
                    print("green-dot law matches the switcher rail")
                    print("PASS")
                    restore()
                    exit(0)
                default:
                    fail("harness ran past its steps")
                }
            }
        }
        app.run()
    }
}

// An LSUIElement app that opens nothing on launch reads as broken, and
// double-clicking it again — the natural retry — used to be a literal no-op.
// This drives the REAL launch path with the install marker cleared:
//   .build/debug/Mia --smoke-firstrun
// (a GUI harness: it takes key window, so don't run it beside the others.)
if CommandLine.arguments.contains("--smoke-firstrun") {
    let launchDelegate = MainActor.assumeIsolated { AppDelegate() }
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.delegate = launchDelegate
        app.setActivationPolicy(.accessory)

        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: AppDelegate.hasLaunchedKey)
        func restore() {
            if let saved { defaults.set(saved, forKey: AppDelegate.hasLaunchedKey) }
            else { defaults.removeObject(forKey: AppDelegate.hasLaunchedKey) }
        }
        // Pretend this machine has never run Mia.
        defaults.removeObject(forKey: AppDelegate.hasLaunchedKey)

        var failures: [String] = []
        func check(_ passed: Bool, _ law: String) {
            print("\(passed ? "ok  " : "FAIL") \(law)")
            if !passed { failures.append(law) }
        }
        func step(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(body) }
        }

        // The launch UI is posted from applicationDidFinishLaunching via
        // main.async, and the hint waits a further 0.35s behind the panel.
        step(1.0) {
            check(launchDelegate.isPanelOnScreen, "first launch opens the panel")
            check(FirstRunHint.isShowing, "first launch points at the menu bar icon")
            check(defaults.bool(forKey: AppDelegate.hasLaunchedKey), "the install marker is recorded")
            check(!FirstRunHint.shortcutDescription.isEmpty, "the hint names a real recorded shortcut")

            FirstRunHint.dismiss()
            launchDelegate.hidePanel()
        }
        // Second launch on the same machine: silent, as it has always been.
        step(1.5) {
            launchDelegate.presentLaunchUI(loginItem: false)
        }
        step(2.0) {
            check(!launchDelegate.isPanelOnScreen, "a later launch stays out of the way")

            // ...and a login-item launch stays silent even on a fresh install:
            // the user asked for Mia to be READY at boot, not to greet them.
            defaults.removeObject(forKey: AppDelegate.hasLaunchedKey)
            launchDelegate.presentLaunchUI(loginItem: true)
        }
        step(2.5) {
            check(!launchDelegate.isPanelOnScreen, "a login-item launch never opens the panel")

            // The headline fix: double-clicking an already-running app.
            _ = launchDelegate.applicationShouldHandleReopen(app, hasVisibleWindows: false)
        }
        step(3.0) {
            check(launchDelegate.isPanelOnScreen, "reopening the app shows the panel")
            restore()
            print(failures.isEmpty ? "PASS" : "FAIL: \(failures.joined(separator: "; "))")
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }
}

// NSApplication.delegate is held unowned — the top-level constant keeps it alive
// for the app's lifetime.
let delegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = delegate
    // Accessory: no Dock icon, no menu bar takeover. The status item is the only chrome.
    app.setActivationPolicy(.accessory)
    app.run()
}
