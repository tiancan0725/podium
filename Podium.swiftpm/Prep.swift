import SwiftUI

/// Private speaker notes for one slide: written by Claude in prep mode, edited by hand or from the chat.
struct PrepNote: Codable, Equatable {
    struct QA: Codable, Hashable {
        var question: String
        var answer: String
    }

    var fingerprint: String?
    var slide: Int
    var questions: [QA]
    var slowDown: String
    var example: String
    var issues: [String]
    var reminders: [String]?       // the lecturer's own lines

    var isEmpty: Bool {
        questions.isEmpty && slowDown.isEmpty && example.isEmpty && issues.isEmpty && (reminders ?? []).isEmpty
    }

    // MARK: Plain-text form, for editing

    /// One item per line: "⚠️ …" issue, "🐢 …" slow down, "Q: …" / "A: …", "💡 …" example; anything else is a reminder.
    var text: String {
        var lines: [String] = []
        lines += issues.map { "⚠️ \($0)" }
        if !slowDown.isEmpty { lines.append("🐢 \(slowDown)") }
        for qa in questions {
            lines.append("Q: \(qa.question)")
            lines.append("A: \(qa.answer)")
        }
        if !example.isEmpty { lines.append("💡 \(example)") }
        lines += reminders ?? []
        return lines.joined(separator: "\n")
    }

    init(fingerprint: String?, slide: Int, questions: [QA], slowDown: String, example: String,
         issues: [String], reminders: [String]? = nil) {
        self.fingerprint = fingerprint
        self.slide = slide
        self.questions = questions
        self.slowDown = slowDown
        self.example = example
        self.issues = issues
        self.reminders = reminders
    }

    init(text: String, fingerprint: String?, slide: Int) {
        self.init(fingerprint: fingerprint, slide: slide, questions: [], slowDown: "", example: "", issues: [])
        var reminders: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            func rest(after prefix: String) -> String? {
                line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : nil
            }
            if let issue = rest(after: "⚠️") ?? rest(after: "⚠") {
                issues.append(issue)
            } else if let note = rest(after: "🐢") {
                slowDown = slowDown.isEmpty ? note : slowDown + " " + note
            } else if let question = rest(after: "Q:") {
                questions.append(QA(question: question, answer: ""))
            } else if let answer = rest(after: "A:"), let last = questions.indices.last {
                questions[last].answer = questions[last].answer.isEmpty ? answer : questions[last].answer + " " + answer
            } else if let idea = rest(after: "💡") {
                example = example.isEmpty ? idea : example + " " + idea
            } else {
                reminders.append(line)
            }
        }
        self.reminders = reminders.isEmpty ? nil : reminders
    }

    // MARK: JSON form, as Claude writes it

    /// Reads Claude's JSON (snake_case keys). Returns nil if anything has the wrong type.
    init?(json: [String: Any], fingerprint: String?, slide: Int) {
        guard let questions = json["questions"] as? [[String: Any]],
              let slowDown = json["slow_down"] as? String,
              let example = json["example"] as? String,
              let issues = json["issues"] as? [String] else { return nil }
        var pairs: [QA] = []
        for item in questions {
            guard let question = item["question"] as? String, let answer = item["answer"] as? String else { return nil }
            pairs.append(QA(question: question, answer: answer))
        }
        let reminders = json["reminders"] as? [String]
        self.init(fingerprint: fingerprint, slide: slide, questions: pairs, slowDown: slowDown,
                  example: example, issues: issues, reminders: (reminders?.isEmpty ?? true) ? nil : reminders)
    }

    /// The JSON schema of one slide's notes, shared by prep mode and the chat's edit tool.
    static func schema(includingSlide: Bool, includingReminders: Bool) -> [String: Any] {
        var properties: [String: Any] = [
            "questions": ["type": "array", "items": object(["question": ["type": "string"], "answer": ["type": "string"]])],
            "slow_down": ["type": "string"],
            "example": ["type": "string"],
            "issues": ["type": "array", "items": ["type": "string"]],
        ]
        if includingSlide { properties["slide"] = ["type": "integer"] }
        if includingReminders { properties["reminders"] = ["type": "array", "items": ["type": "string"]] }
        return object(properties)
    }

    static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "additionalProperties": false,
         "required": Array(properties.keys).sorted(), "properties": properties]
    }
}

struct SavedPrep: Codable {
    var title: String
    var model: String
    var created: Date
    var instructions: String?
    var notes: [PrepNote]
    var updated: Date?             // when the notes last changed; the newer copy wins on open
}

/// Prep mode: Claude reads the whole PDF once and writes speaker notes for every slide.
/// Notes are saved per PDF (same id as the ink notes) and matched to slides by their text,
/// so they survive recompiling. Shown only on the presenter's iPad.
@MainActor @Observable
final class PrepStore {
    static let shared = PrepStore()

    /// Notes for the open deck, by slide index.
    private(set) var notes: [Int: PrepNote] = [:]
    private(set) var created: Date?
    private(set) var instructions = ""
    private(set) var runningID: String?
    private(set) var slidesDone = 0
    private(set) var slidesTotal = 0
    private(set) var lastError: String?
    /// The note each slide had before its last edit, for one-step undo (`nil` inside: it had none).
    private(set) var undo: [Int: PrepNote?] = [:]

    @ObservationIgnored private var openID: String?
    @ObservationIgnored private var openDeck: Deck?
    @ObservationIgnored private var orphans: [PrepNote] = []
    @ObservationIgnored private var model = AssistantModel.opus.rawValue
    @ObservationIgnored private var updated: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { runningID != nil }
    /// True once the deck has been prepped or has any note, so the notes strip is worth showing.
    var hasNotes: Bool { created != nil || !notes.isEmpty }

    // MARK: Open deck

    /// `companionPrep` comes from the file next to the PDF; it's used if it's newer than the local copy.
    func load(deck: Deck, notesID: String?, companionPrep: SavedPrep? = nil) {
        openDeck = deck
        openID = notesID
        lastError = nil
        undo = [:]
        var saved = notesID.flatMap(Self.read)
        if let remote = companionPrep, (remote.updated ?? remote.created) > (saved?.updated ?? saved?.created ?? .distantPast) {
            saved = remote
            if let notesID { Self.write(remote, id: notesID) }
        }
        apply(saved, to: deck)
    }

    func unload() {
        openDeck = nil
        openID = nil
        notes = [:]
        orphans = []
        undo = [:]
        created = nil
        instructions = ""
    }

    func note(forSlide slide: Int) -> PrepNote? {
        notes[slide].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func apply(_ saved: SavedPrep?, to deck: Deck) {
        notes = [:]
        orphans = []
        created = saved?.created
        updated = saved?.updated
        instructions = saved?.instructions ?? ""
        model = saved?.model ?? AssistantModel.opus.rawValue
        guard let saved else { return }
        var indexOfFingerprint: [String: Int] = [:]
        for (index, fingerprint) in deck.fingerprints.enumerated() { indexOfFingerprint[fingerprint] = index }
        let matched = Set(saved.notes.compactMap { $0.fingerprint.flatMap { indexOfFingerprint[$0] } })
        for note in saved.notes {
            if let fingerprint = note.fingerprint, let index = indexOfFingerprint[fingerprint] {
                notes[index] = note
            } else if deck.slides.indices.contains(note.slide), !matched.contains(note.slide), notes[note.slide] == nil {
                notes[note.slide] = note
            } else {
                orphans.append(note)
            }
        }
    }

    // MARK: Editing

    /// Replaces one slide's notes (hand edit or Claude's tool), remembering the old ones for undo.
    func setNote(_ note: PrepNote?, forSlide slide: Int) {
        guard let deck = openDeck, deck.slides.indices.contains(slide) else { return }
        undo[slide] = .some(notes[slide])
        var note = note
        note?.slide = slide
        note?.fingerprint = deck.fingerprints[slide]
        notes[slide] = (note?.isEmpty ?? true) ? nil : note
        if created == nil { created = .now }
        save()
    }

    func undoEdit(slide: Int) {
        guard let previous = undo[slide] else { return }
        notes[slide] = previous
        undo[slide] = nil
        save()
    }

    /// Applies Claude's `update_prep_notes` tool input. Returns false if the input is malformed.
    func applyToolEdit(_ input: [String: Any], slide: Int) -> Bool {
        guard let note = PrepNote(json: input, fingerprint: nil, slide: slide) else { return false }
        setNote(note, forSlide: slide)
        return true
    }

    private func save() {
        guard let openID else { return }
        updated = .now
        guard let saved = currentSaved() else { return }
        Self.write(saved, id: openID)
        PresentationState.shared.scheduleCompanionWrite()
    }

    /// The open deck's notes as they'd be saved, for the companion file.
    func currentSaved() -> SavedPrep? {
        guard let deck = openDeck, created != nil || !notes.isEmpty else { return nil }
        let current = notes.sorted { $0.key < $1.key }.map { slide, note -> PrepNote in
            var note = note
            note.slide = slide
            note.fingerprint = deck.fingerprints[slide]
            return note
        }
        return SavedPrep(title: deck.title, model: model, created: created ?? .now,
                         instructions: instructions.isEmpty ? nil : instructions,
                         notes: current + orphans, updated: updated)
    }

    // MARK: Running prep

    /// Rough cost in dollars: PDF pages read as images plus text, and a few hundred tokens of notes per slide.
    static func estimatedCost(deck: Deck, model: AssistantModel, slides: Int? = nil) -> Double {
        let input = Double(deck.pageCount) * 2500 + 3000
        let output = Double(slides ?? deck.slides.count) * 600 + 8000
        let (inPrice, outPrice): (Double, Double) = switch model {
        case .opus: (4, 20)
        case .sonnet: (2, 10)
        case .haiku: (0.1, 0.5)
        }
        return (input * inPrice + output * outPrice) / 1_000_000
    }

    /// Slides that have no notes yet.
    var missingSlides: [Int] {
        guard let deck = openDeck else { return [] }
        return deck.slides.indices.filter { note(forSlide: $0) == nil }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        runningID = nil
    }

    /// Bumped per run, so a cancelled run finishing late can't clear the state of the next one.
    @ObservationIgnored private var generation = 0

    /// Runs prep with the connection in use. `onlyMissing` keeps every slide that already has notes (including hand edits).
    func start(instructions: String, onlyMissing: Bool) {
        guard !isRunning, let deck = openDeck, let notesID = openID else { return }
        let connection: AIConnection
        switch AssistantStore.shared.connection() {
        case .success(let ready): connection = ready
        case .failure(let problem):
            lastError = problem.message
            return
        }
        let targets = onlyMissing ? missingSlides : Array(deck.slides.indices)
        guard !targets.isEmpty else {
            lastError = "Every slide already has notes."
            return
        }
        lastError = nil
        runningID = notesID
        slidesDone = 0
        slidesTotal = targets.count
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        self.instructions = trimmed
        // Only Claude reads an attached PDF; other providers get the slides' text.
        let body = Self.requestBody(deck: deck, targets: targets, instructions: trimmed,
                                    attachPDF: connection.provider == .claude)
        let modelName = connection.provider == .claude ? connection.claudeModel.rawValue : connection.otherModel
        generation += 1
        let run = generation
        task = Task { [weak self] in
            let result = await AssistantStore.stream(connection: connection, body: body, timeout: 900) { text in
                guard let self, self.generation == run else { return }
                self.slidesDone = min(text.components(separatedBy: "\"slide\"").count - 1, self.slidesTotal)
            }
            guard let self, self.generation == run else { return }
            self.finish(result, notesID: notesID, deck: deck, targets: targets, model: modelName, name: connection.name)
        }
    }

    private func finish(_ result: AssistantStore.StreamResult, notesID: String, deck: Deck,
                        targets: [Int], model: String, name: String) {
        defer {
            runningID = nil
            task = nil
        }
        switch result {
        case .cancelled:
            return
        case .failure(let message):
            lastError = message
        case .success(_, let text, _):
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = json["slides"] as? [[String: Any]] else {
                lastError = "\(name)'s notes came back incomplete. Try again, or use a faster model for a long deck."
                return
            }
            // Only touch the deck that was prepped, even if another one is open now.
            guard openID == notesID, openDeck === deck else { return }
            let allowed = Set(targets)
            for entry in entries {
                guard let number = entry["slide"] as? Int, allowed.contains(number - 1),
                      let note = PrepNote(json: entry, fingerprint: deck.fingerprints[number - 1], slide: number - 1)
                else { continue }
                notes[number - 1] = note.isEmpty ? nil : note
                undo[number - 1] = nil
            }
            if targets.count == deck.slides.count { orphans = [] }
            created = .now
            self.model = model
            save()
        }
    }

    // MARK: Request

    private static let systemPrompt = """
    You are helping an economics lecturer prepare to present a slide deck. Read the whole deck, then write \
    private speaker notes for the slides you're asked about. The lecturer glances at them on an iPad while \
    talking, so every note must be short and readable at a glance.

    For each slide:
    - questions: 0–3 questions students are likely to ask about this slide, each with a one- or two-sentence \
    answer the lecturer can say out loud. Skip title, outline and transition slides.
    - slow_down: one short sentence if students are likely to struggle here and why; otherwise "".
    - example: one concrete backup example or intuition in 1–2 sentences, if it would help; otherwise "".
    - issues: real mistakes only (math, notation, logic, typos, inconsistencies with other slides), each in \
    one line saying what and where. Empty if none. Don't nitpick style.

    Write math in plain Unicode where you can (α, β, ≤, x², ∂y/∂x, Σ). Infer the course level from the deck. \
    If the lecturer gives instructions, follow them.
    """

    /// The PDF itself (so Claude sees figures and equations), how Podium numbers the slides,
    /// which slides to write notes for, and the lecturer's instructions.
    private static func requestBody(deck: Deck, targets: [Int], instructions: String, attachPDF: Bool) -> [String: Any] {
        var map = "Podium groups PDF pages into slides; the overlay steps of one Beamer frame are one slide. " +
            "Slide numbers and their PDF pages:\n"
        for slide in deck.slides {
            let pages = slide.pages.count == 1
                ? "page \(slide.pages.lowerBound + 1)"
                : "pages \(slide.pages.lowerBound + 1)–\(slide.pages.upperBound + 1)"
            map += "Slide \(slide.number): \(pages)\n"
        }
        if targets.count == deck.slides.count {
            map += "\nWrite notes for every slide: exactly one entry per slide, in order."
        } else {
            map += "\nWrite notes only for these slides, one entry each: " +
                targets.map { String($0 + 1) }.joined(separator: ", ") + "."
        }
        if !instructions.isEmpty {
            map += "\n\nThe lecturer's instructions for these notes:\n\(instructions)"
        }

        var content: [[String: Any]] = []
        let pdf = attachPDF ? deck.document.dataRepresentation() : nil
        if let pdf, pdf.count < 22_000_000, deck.pageCount <= 600 {
            content.append(["type": "document",
                            "source": ["type": "base64", "media_type": "application/pdf",
                                       "data": pdf.base64EncodedString()]])
        } else {
            // No PDF (too big, or a provider that can't read one): the text of each slide instead.
            let text = "The deck's text, slide by slide:\n" + deck.slideByslideText(limit: 400_000)
            content.append(["type": "text", "text": text])
        }
        content.append(["type": "text", "text": map])

        let schema = PrepNote.object(["slides": ["type": "array",
                                                 "items": PrepNote.schema(includingSlide: true, includingReminders: false)]])
        return [
            "max_tokens": 64000,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "high", "format": ["type": "json_schema", "schema": schema]],
            "system": systemPrompt,
            "messages": [["role": "user", "content": content]],
        ]
    }

    // MARK: Files

    static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Prep", isDirectory: true)
    }

    private static func read(_ id: String) -> SavedPrep? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(id).json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SavedPrep.self, from: data)
    }

    private static func write(_ prep: SavedPrep, id: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(prep) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
    }

    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }
}

/// The current slide's prep notes, under the slide on the iPad, with edit and undo.
struct PrepNotesView: View {
    let slide: Int
    @State private var editing = false

    var body: some View {
        let prep = PrepStore.shared
        let note = prep.note(forSlide: slide)
        // Buttons on the left, away from a right hand's resting palm.
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 14) {
                Button {
                    editing = true
                } label: {
                    Image(systemName: note == nil ? "plus" : "pencil")
                }
                .help("Edit these notes")
                if prep.undo[slide] != nil {
                    Button {
                        prep.undoEdit(slide: slide)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("Undo the last change to these notes")
                }
            }
            .padding(12)
            ScrollView {
                if let note {
                    content(note)
                } else {
                    Text("No notes for this slide.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                }
            }
        }
        .frame(maxHeight: note == nil ? 44 : 180)
        .background(Color.barBackground)
        .sheet(isPresented: $editing) {
            PrepNoteEditor(slide: slide, original: note)
        }
    }

    private func content(_ note: PrepNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(note.issues, id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if !note.slowDown.isEmpty {
                Label(note.slowDown, systemImage: "tortoise.fill")
                    .foregroundStyle(.yellow)
            }
            ForEach(note.reminders ?? [], id: \.self) { reminder in
                Label(reminder, systemImage: "pin.fill")
                    .foregroundStyle(.mint)
            }
            ForEach(note.questions, id: \.self) { qa in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Q: \(qa.question)").fontWeight(.semibold)
                    Text(qa.answer).foregroundStyle(.secondary)
                }
            }
            if !note.example.isEmpty {
                Label(note.example, systemImage: "lightbulb")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

/// Edit one slide's notes as plain text, one item per line.
private struct PrepNoteEditor: View {
    let slide: Int
    let original: PrepNote?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("One item per line:  ⚠️ problem   🐢 slow down   Q: question / A: answer   💡 example. Any other line is your own reminder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(16)
            .navigationTitle("Notes · slide \(slide + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        PrepStore.shared.setNote(PrepNote(text: text, fingerprint: nil, slide: slide), forSlide: slide)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { text = original?.text ?? "" }
    }
}
