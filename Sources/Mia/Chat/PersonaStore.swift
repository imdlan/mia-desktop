import Foundation

/// A named system-prompt preset (P4 "persona"). Selecting one in Settings ›
/// Chat replaces the system prompt sent with every turn; "Custom" keeps the
/// free-text prompt, unchanged.
struct Persona: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var prompt: String
}

@MainActor
final class PersonaStore: ObservableObject {
    @Published var personas: [Persona] {
        didSet { persist() }
    }

    /// The selected persona's id as a string, nil = Custom (no persona). A
    /// string because it lives in UserDefaults; the id-keyed indirection is
    /// what makes renaming a persona safe and deleting one fall back cleanly.
    @Published var activeID: String? {
        didSet {
            guard oldValue != activeID else { return }
            if let activeID {
                UserDefaults.standard.set(activeID, forKey: Self.activeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeKey)
            }
        }
    }

    private static let defaultsKey = "personasJSON"
    private static let seedFlagKey = "hasSeededPersonas"
    private static let activeKey = "activePersonaID"

    init() {
        personas = Self.seedPersonas(
            existing: Self.stored(),
            hasSeeded: UserDefaults.standard.bool(forKey: Self.seedFlagKey)
        )
        if UserDefaults.standard.bool(forKey: Self.seedFlagKey) == false {
            // Records "this install has met the personas feature" whether the
            // list came from disk or from seeding — either way it must never
            // seed again, so a user who deletes every example stays deleted.
            UserDefaults.standard.set(true, forKey: Self.seedFlagKey)
        }
        if !personas.isEmpty { persist() } // first seeding reaches the disk
        activeID = UserDefaults.standard.string(forKey: Self.activeKey)
    }

    // MARK: - Prompt resolution (pure, for ChatStore and the smoke harness)

    /// The whole wiring law as one pure function: the active persona's prompt
    /// wins; anything else — no selection, or a selection whose persona was
    /// deleted — falls back to the caller's default unchanged. That fallback
    /// is byte-for-byte the pre-persona system prompt, so Custom behavior is
    /// whatever it always was.
    nonisolated static func resolvePrompt(activeID: String?, personas: [Persona], fallback: String) -> String {
        guard let activeID,
              let persona = personas.first(where: { $0.id.uuidString == activeID }) else { return fallback }
        return persona.prompt
    }

    /// The stored list, without instantiating the store — ChatStore.systemPrompt
    /// is static and must not need an ObservableObject to read defaults.
    nonisolated static func stored() -> [Persona] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([Persona].self, from: data) else { return [] }
        return list
    }

    /// Seed decision, pure: the three examples land only when the list is
    /// EMPTY and this install has never been seeded. Non-empty means the user
    /// has their own — untouched; already-seeded means even an emptied list
    /// stays empty (deleted examples must not revive).
    nonisolated static func seedPersonas(existing: [Persona], hasSeeded: Bool) -> [Persona] {
        guard !hasSeeded, existing.isEmpty else { return existing }
        return [
            Persona(
                id: UUID(),
                name: "Translate",
                prompt: "You are a precise translator. Translate the user's text into natural, idiomatic English unless the text itself asks for a different target language. Preserve tone, formatting and markdown structure. Reply with the translation only — no preamble, no notes, no back-translation."
            ),
            Persona(
                id: UUID(),
                name: "Code Review",
                prompt: "You are a senior code reviewer. Review the user's code for correctness bugs first, then security, then readability and performance. Point at the exact lines involved. Be direct and concrete: for each issue, show the minimal fix rather than describing it abstractly. Say so plainly when code looks fine."
            ),
            Persona(
                id: UUID(),
                name: "Writing",
                prompt: "You are a sharp editing assistant. Improve the user's draft for clarity, flow and concision while preserving their voice and meaning. Keep their formatting (markdown, lists, emphasis). Reply with the improved text only, unless they ask you to explain the edits."
            ),
        ]
    }

    // MARK: - CRUD

    func add() {
        personas.append(Persona(id: UUID(), name: "New persona", prompt: "You are…"))
    }

    /// Deleting the active persona drops the selection back to Custom — a
    /// stale id would resolve as Custom on the next send anyway (see
    /// `resolvePrompt`), but the Picker should not keep showing a ghost.
    func remove(id: UUID) {
        personas.removeAll { $0.id == id }
        if activeID == id.uuidString { activeID = nil }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(personas) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
