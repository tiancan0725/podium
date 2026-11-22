import SwiftUI
import PencilKit
import Security

/// API keys, kept in the iPad's Keychain (never in UserDefaults or logs): one for Anthropic, one for
/// the other (OpenAI-compatible) provider.
enum Keychain {
    static let anthropic = "com.cantian.podium.anthropic"
    static let other = "com.cantian.podium.other-provider"
    /// The account the first key of each kind was saved under; later connections use their own id.
    static let originalAccount = "api-key"

    private static func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func readKey(_ service: String, account: String) -> String? {
        var item: CFTypeRef?
        var search = query(service, account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveKey(_ key: String, _ service: String, account: String) -> Bool {
        // Replace in place, so a failed save never loses the old key.
        let update = [kSecValueData as String: Data(key.utf8)] as CFDictionary
        let status = SecItemUpdate(query(service, account) as CFDictionary, update)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(service, account)
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func deleteKey(_ service: String, account: String) {
        SecItemDelete(query(service, account) as CFDictionary)
    }
}

/// Which AI answers in the panel and writes prep notes.
enum AIProvider: String, Codable, Sendable {
    case claude, other
    var keychainService: String { self == .claude ? Keychain.anthropic : Keychain.other }
}

/// A saved connection: a name you choose, the provider, its address and model, and a key in the Keychain.
struct AIProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: AIProvider
    var baseURL: String = ""
    /// Claude: an AssistantModel raw value. Other: the provider's model name.
    var model: String
    /// Where its key is in the Keychain.
    var keyAccount: String

    var subtitle: String {
        switch kind {
        case .claude: "Claude · \(AssistantModel(rawValue: model)?.title ?? model)"
        case .other: "\(OtherProviderPreset.name(forBaseURL: baseURL)) · \(model.isEmpty ? "no model set" : model)"
        }
    }
}

/// Everything a request needs, captured on the main actor.
struct AIConnection: Sendable {
    let provider: AIProvider
    let key: String
    let claudeModel: AssistantModel
    let baseURL: String
    let otherModel: String

    /// The name shown in messages ("Claude", "OpenAI", …).
    var name: String {
        guard provider == .other else { return "Claude" }
        return OtherProviderPreset.name(forBaseURL: baseURL)
    }
}

/// Common OpenAI-compatible services, to fill in the address.
enum OtherProviderPreset: CaseIterable {
    case openAI, gemini, openRouter

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .gemini: "Google Gemini"
        case .openRouter: "OpenRouter"
        }
    }

    var baseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openRouter: "https://openrouter.ai/api/v1"
        }
    }

    static func name(forBaseURL url: String) -> String {
        allCases.first { url.hasPrefix($0.baseURL) }?.title ?? (URL(string: url)?.host ?? "the AI provider")
    }
}

enum AssistantModel: String, CaseIterable, Identifiable, Sendable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .opus: "Opus 5.5 (best)"
        case .sonnet: "Sonnet 5.5 (faster, cheaper)"
        case .haiku: "Haiku 5.5 (fastest, cheapest)"
        }
    }

    /// Server-side refusal fallback; Haiku has none.
    var supportsFallback: Bool { self != .haiku }
}

/// One message as shown in the panel.
struct AssistantTurn: Identifiable {
    let id = UUID()
    var isUser: Bool
    var text: String
    var isError = false
    /// Set when Claude changed this slide's prep notes during this reply.
    var editedNotes = false
}

/// A conversation about one slide: what the panel shows, plus the exact API history.
/// The history is append-only and replays Claude's content blocks unchanged.
struct AssistantConversation {
    var turns: [AssistantTurn] = []
    var history: [[String: Any]] = []
    var lastImageSignature: String?
    var lastSideSignature: String?
}

/// Talks to the Claude API (raw HTTP; there is no Swift SDK) about the slide on screen.
/// Lives only on the presenter's iPad; nothing here reaches the projector.
@MainActor @Observable
final class AssistantStore {
    static let shared = AssistantStore()

    private(set) var conversations: [Int: AssistantConversation] = [:]
    private(set) var streamingSlide: Int?
    /// True between sending and the first visible text (thinking happens silently).
    private(set) var waitingForText = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var deckTextCache: (deck: ObjectIdentifier, text: String)?

    static let quickPrompts: [(title: String, prompt: String)] = [
        ("Likely student questions", "What questions are students likely to ask about this slide? Give 3–5, each with a one-line answer I can say out loud."),
        ("Another example", "Give me one more concrete example that illustrates this slide's idea, in a few sentences I could say to the class."),
        ("Explain simply", "Explain this slide's main idea simply and intuitively, as I might say it to a student who is lost."),
        ("Check this slide for errors", "Check this slide for mistakes: math, notation, logic, or typos. List only real problems, briefly. If it looks right, say so."),
        ("Add to notes", "Add the most useful points from your last answer to this slide's prep notes, briefly."),
    ]

    // MARK: Connections

    /// Saved connections (several keys, each with its own name); one is in use.
    var profiles: [AIProfile] = [] {
        didSet { saveProfiles() }
    }
    var activeID: UUID? {
        didSet { saveProfiles() }
    }
    /// Bumped when a key is saved or removed, so views asking `hasKey` refresh.
    private(set) var keyRevision = 0

    var active: AIProfile? { profiles.first { $0.id == activeID } ?? profiles.first }

    private func updateActive(_ change: (inout AIProfile) -> Void) {
        guard let active, let index = profiles.firstIndex(where: { $0.id == active.id }) else { return }
        change(&profiles[index])
    }

    var provider: AIProvider { active?.kind ?? .claude }
    /// The Claude model of the connection in use (Opus if it isn't a Claude connection).
    var model: AssistantModel {
        get { active.flatMap { $0.kind == .claude ? AssistantModel(rawValue: $0.model) : nil } ?? .opus }
        set { updateActive { if $0.kind == .claude { $0.model = newValue.rawValue } } }
    }
    var otherBaseURL: String {
        get { active?.baseURL ?? "" }
        set { updateActive { $0.baseURL = newValue } }
    }
    var otherModel: String {
        get { active?.kind == .other ? active?.model ?? "" : "" }
        set { updateActive { if $0.kind == .other { $0.model = newValue } } }
    }
    var activeName: String {
        get { active?.name ?? "" }
        set { updateActive { $0.name = newValue } }
    }

    func hasKey(for profile: AIProfile) -> Bool {
        _ = keyRevision
        return Keychain.readKey(profile.kind.keychainService, account: profile.keyAccount) != nil
    }

    /// The connection in use is ready.
    var hasKey: Bool {
        guard let active else { return false }
        return hasKey(for: active) && (active.kind == .claude || !active.model.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func addProfile(_ kind: AIProvider) {
        let id = UUID()
        let profile = kind == .claude
            ? AIProfile(id: id, name: "Claude", kind: .claude, model: AssistantModel.opus.rawValue, keyAccount: id.uuidString)
            : AIProfile(id: id, name: "New provider", kind: .other, baseURL: OtherProviderPreset.openAI.baseURL, model: "",
                        keyAccount: id.uuidString)
        profiles.append(profile)
        activeID = id
    }

    /// Removes a connection and its key.
    func deleteProfile(_ profile: AIProfile) {
        Keychain.deleteKey(profile.kind.keychainService, account: profile.keyAccount)
        profiles.removeAll { $0.id == profile.id }
        if activeID == profile.id { activeID = profiles.first?.id }
        keyRevision += 1
    }

    /// The connection in use, with its key, or a message saying what's missing.
    func connection() -> Result<AIConnection, ConnectionProblem> {
        guard let active else { return .failure(ConnectionProblem("Add a connection first (the key button in the panel).")) }
        guard let key = Keychain.readKey(active.kind.keychainService, account: active.keyAccount) else {
            return .failure(ConnectionProblem("Add the API key for \u{201C}\(active.name)\u{201D} first (the key button in the panel)."))
        }
        switch active.kind {
        case .claude:
            return .success(AIConnection(provider: .claude, key: key, claudeModel: model, baseURL: "", otherModel: ""))
        case .other:
            let modelName = active.model.trimmingCharacters(in: .whitespaces)
            guard !modelName.isEmpty else {
                return .failure(ConnectionProblem("Enter a model name for \u{201C}\(active.name)\u{201D} (the key button in the panel)."))
            }
            return .success(AIConnection(provider: .other, key: key, claudeModel: model,
                                         baseURL: active.baseURL.trimmingCharacters(in: .whitespaces), otherModel: modelName))
        }
    }

    struct ConnectionProblem: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Saves (or replaces) the key of the connection in use.
    func setKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let active else { return }
        Keychain.saveKey(trimmed, active.kind.keychainService, account: active.keyAccount)
        keyRevision += 1
    }

    func removeKey() {
        guard let active else { return }
        Keychain.deleteKey(active.kind.keychainService, account: active.keyAccount)
        keyRevision += 1
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "assistant.profiles")
        }
        UserDefaults.standard.set(activeID?.uuidString, forKey: "assistant.activeProfile")
    }

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "assistant.profiles"),
           let saved = try? JSONDecoder().decode([AIProfile].self, from: data), !saved.isEmpty {
            profiles = saved
            activeID = defaults.string(forKey: "assistant.activeProfile").flatMap(UUID.init(uuidString:)) ?? saved.first?.id
            return
        }
        // First run of this version: turn the earlier single Claude key and single other key into connections.
        let claude = AIProfile(name: "Claude", kind: .claude,
                               model: defaults.string(forKey: "assistant.model") ?? AssistantModel.opus.rawValue,
                               keyAccount: Keychain.originalAccount)
        var list = [claude]
        var active = claude.id
        let otherURL = defaults.string(forKey: "assistant.otherBaseURL") ?? OtherProviderPreset.openAI.baseURL
        let otherModel = defaults.string(forKey: "assistant.otherModel") ?? ""
        if Keychain.readKey(Keychain.other, account: Keychain.originalAccount) != nil || !otherModel.isEmpty {
            let other = AIProfile(name: OtherProviderPreset.name(forBaseURL: otherURL), kind: .other, baseURL: otherURL,
                                  model: otherModel, keyAccount: Keychain.originalAccount)
            list.append(other)
            if defaults.string(forKey: "assistant.provider") == AIProvider.other.rawValue { active = other.id }
        }
        profiles = list
        activeID = active
        saveProfiles()   // property observers don't run inside init
    }

    func conversation(for slide: Int) -> AssistantConversation {
        conversations[slide] ?? AssistantConversation()
    }

    func reset(slide: Int) {
        if streamingSlide == slide { stop() }
        conversations[slide] = nil
    }

    func resetAll() {
        stop()
        conversations = [:]
        deckTextCache = nil
    }

    /// Stops the reply being written. Its turn is tidied up here; the cancelled task's late finish is ignored.
    func stop() {
        runID += 1
        task?.cancel()
        task = nil
        if let slide = streamingSlide, var conversation = conversations[slide] {
            if conversation.turns.last.map({ !$0.isUser && $0.text.isEmpty }) == true { conversation.turns.removeLast() }
            conversation.lastImageSignature = nil
            conversation.lastSideSignature = nil
            conversations[slide] = conversation
        }
        streamingSlide = nil
        waitingForText = false
    }

    /// Bumped per question and on stop, so a stopped reply can't write into the next one.
    @ObservationIgnored private var runID = 0

    // MARK: Sending

    /// Asks about the current slide. Attaches a fresh picture of the slide (with ink)
    /// whenever the page or the ink changed since the last picture in this conversation.
    func send(_ prompt: String) {
        let state = PresentationState.shared
        // Claude works with the deck (its prep notes and per-slide chats), not the side document.
        let doc = state.primary
        guard streamingSlide == nil, let deck = doc.deck else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let slideIndex = deck.slideIndex(ofPage: doc.pageIndex)
        var conversation = conversation(for: slideIndex)
        conversation.turns.append(AssistantTurn(isUser: true, text: text))

        let connection: AIConnection
        switch self.connection() {
        case .success(let ready): connection = ready
        case .failure(let problem):
            conversation.turns.append(AssistantTurn(isUser: false, text: problem.message, isError: true))
            conversations[slideIndex] = conversation
            return
        }

        let page = doc.pageIndex
        let drawing = doc.drawings[doc.inkKey]
        let signature = "\(page)-\(drawing?.dataRepresentation().hashValue ?? 0)-\(doc.whiteboardShown)"
        var content: [[String: Any]] = []
        if signature != conversation.lastImageSignature,
           let jpeg = Self.snapshot(deck: deck, page: page, drawing: drawing, board: doc.whiteboardShown) {
            content.append(["type": "image",
                            "source": ["type": "base64", "media_type": "image/jpeg",
                                       "data": jpeg.base64EncodedString()]])
            conversation.lastImageSignature = signature
        }
        let position = doc.slidePosition.map { "Slide \($0.slide) of \($0.slideCount), overlay step \($0.step) of \($0.stepCount)" } ?? ""
        let where_ = doc.whiteboardShown ? "\(position). The picture shows my whiteboard, not the slide." : position
        let notes = PrepStore.shared.note(forSlide: slideIndex).map { "This slide's current prep notes:\n\($0.text)" }
            ?? "This slide has no prep notes yet."
        // A second PDF open beside the deck: Claude sees its current page too (a fresh picture when it changes).
        var sideNote = ""
        if let side = state.secondary, let sideDeck = side.deck {
            let sideDrawing = side.drawings[side.inkKey]
            let sideSignature = "\(ObjectIdentifier(sideDeck))-\(side.pageIndex)-\(sideDrawing?.dataRepresentation().hashValue ?? 0)-\(side.whiteboardShown)"
            if sideSignature != conversation.lastSideSignature,
               let jpeg = Self.snapshot(deck: sideDeck, page: side.pageIndex, drawing: sideDrawing, board: side.whiteboardShown) {
                content.append(["type": "image",
                                "source": ["type": "base64", "media_type": "image/jpeg",
                                           "data": jpeg.base64EncodedString()]])
                conversation.lastSideSignature = sideSignature
                sideNote = "\n[Also open beside the slide: \"\(sideDeck.title)\", page \(side.pageIndex + 1) of \(sideDeck.pageCount); "
                    + "the last picture shows that page with my notes on it.]"
            } else {
                sideNote = "\n[Also open beside the slide: \"\(sideDeck.title)\", page \(side.pageIndex + 1) of \(sideDeck.pageCount) (unchanged since the last picture of it).]"
            }
        }
        content.append(["type": "text", "text": "[\(where_)]\(sideNote)\n[\(notes)]\n\n\(text)"])
        let userMessage: [String: Any] = ["role": "user", "content": content]

        conversation.turns.append(AssistantTurn(isUser: false, text: ""))
        conversations[slideIndex] = conversation
        streamingSlide = slideIndex
        waitingForText = true

        let deckText = deckText(for: deck)
        let history = conversation.history + [userMessage]
        runID += 1
        let run = runID
        task = Task { [weak self] in
            // Claude may call update_prep_notes; run the tool and continue, a few rounds at most.
            var messages = history
            var shown = ""
            for _ in 0..<4 {
                let prefix = shown
                let result = await Self.stream(connection: connection, deckText: deckText, messages: messages) { visible in
                    guard self?.runID == run else { return }
                    self?.updateReply(slide: slideIndex, text: prefix + visible)
                }
                guard self?.runID == run else { return }
                guard case .success(let blocks, let visible, let stopReason) = result else {
                    self?.finish(slide: slideIndex, messages: nil, result: result)
                    return
                }
                shown += visible
                messages.append(["role": "assistant", "content": blocks])
                guard stopReason == "tool_use", let self else { break }
                let results = self.runTools(blocks, slide: slideIndex)
                guard !results.isEmpty else { break }
                messages.append(["role": "user", "content": results])
                if !shown.isEmpty { shown += "\n\n" }
            }
            guard let self, self.runID == run else { return }
            self.finish(slide: slideIndex, messages: Self.withoutDanglingToolCalls(messages),
                        result: .success(blocks: [], visible: shown, stopReason: nil))
        }
    }

    /// A reply cut off mid tool call (or after the last round) leaves tool calls without results, which
    /// the API rejects on the next question; keep only the reply's text in that case.
    private static func withoutDanglingToolCalls(_ messages: [[String: Any]]) -> [[String: Any]] {
        guard var last = messages.last, last["role"] as? String == "assistant",
              let blocks = last["content"] as? [[String: Any]],
              blocks.contains(where: { $0["type"] as? String == "tool_use" }) else { return messages }
        var kept = blocks.filter { $0["type"] as? String == "text" }
        if kept.isEmpty { kept = [["type": "text", "text": "(Stopped before finishing.)"]] }
        last["content"] = kept
        return Array(messages.dropLast()) + [last]
    }

    /// Runs Claude's tool calls (only update_prep_notes exists) and returns the tool results.
    private func runTools(_ blocks: [[String: Any]], slide: Int) -> [[String: Any]] {
        blocks.compactMap { block -> [String: Any]? in
            guard block["type"] as? String == "tool_use", let id = block["id"] as? String else { return nil }
            guard block["name"] as? String == "update_prep_notes",
                  let input = block["input"] as? [String: Any],
                  PrepStore.shared.applyToolEdit(input, slide: slide) else {
                return ["type": "tool_result", "tool_use_id": id, "is_error": true,
                        "content": "The notes couldn't be updated: the input didn't match the schema."]
            }
            if var conversation = conversations[slide], let last = conversation.turns.indices.last {
                conversation.turns[last].editedNotes = true
                conversations[slide] = conversation
            }
            return ["type": "tool_result", "tool_use_id": id, "content": "Updated. The new notes are shown under the slide."]
        }
    }

    private func updateReply(slide: Int, text: String) {
        guard streamingSlide == slide, var conversation = conversations[slide],
              let last = conversation.turns.indices.last else { return }
        if !text.isEmpty { waitingForText = false }
        conversation.turns[last].text = text
        conversations[slide] = conversation
    }

    /// `messages` is the full history after a successful reply (tool rounds included).
    private func finish(slide: Int, messages: [[String: Any]]?, result: StreamResult) {
        guard var conversation = conversations[slide], let last = conversation.turns.indices.last else { return }
        switch result {
        case .success(_, let visible, _):
            conversation.turns[last].text = visible.isEmpty && conversation.turns[last].editedNotes
                ? "Updated this slide's notes." : visible
            if let messages { conversation.history = messages }
        case .failure(let message):
            // The turn didn't happen: keep the history as it was, so the next question starts cleanly.
            conversation.turns[last] = AssistantTurn(isUser: false, text: message, isError: true)
            conversation.lastImageSignature = nil
            conversation.lastSideSignature = nil
        case .cancelled:
            if conversation.turns[last].text.isEmpty { conversation.turns.removeLast() }
            conversation.lastImageSignature = nil
            conversation.lastSideSignature = nil
        }
        conversations[slide] = conversation
        if streamingSlide == slide {
            streamingSlide = nil
            waitingForText = false
            task = nil
        }
    }

    // MARK: Context

    /// Every page's text, capped at about 100k characters; sent as cached system context.
    private func deckText(for deck: Deck) -> String {
        if let cache = deckTextCache, cache.deck == ObjectIdentifier(deck) { return cache.text }
        let text = "The full text of the deck \"\(deck.title)\", slide by slide:\n" + deck.slideByslideText(limit: 100_000)
        deckTextCache = (ObjectIdentifier(deck), text)
        return text
    }

    /// The page with its ink (or the whiteboard), as a JPEG about 1600 px on the long edge.
    private static func snapshot(deck: Deck, page: Int, drawing: PKDrawing?, board: Bool) -> Data? {
        let size = deck.pageSize(page)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = 1600 / max(size.width, size.height)
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: pixels, format: format).image { context in
            if board {
                UIColor(white: PresentationState.shared.boardIsDark ? 0.12 : 1, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: pixels))
            } else {
                deck.image(page: page, width: pixels.width, scale: 1)?.draw(in: CGRect(origin: .zero, size: pixels))
            }
            if let drawing {
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    drawing.image(from: CGRect(origin: .zero, size: size), scale: scale)
                        .draw(in: CGRect(origin: .zero, size: pixels))
                }
            }
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    // MARK: HTTP

    enum StreamResult {
        case success(blocks: [[String: Any]], visible: String, stopReason: String?)
        case failure(String)
        case cancelled
    }

    nonisolated private static let instructions = """
    You are helping an economics lecturer while they present slides live in class. They read your answers \
    on their iPad, privately; the class never sees this panel. They glance at it between sentences, so keep \
    answers short and scannable: a few bullets or 2–4 sentences, no preamble, no closing summary. Write math \
    in plain Unicode where you can (α, β, ≤, x², ∂y/∂x, Σ); use LaTeX only when there's no readable alternative. \
    Each question comes with a picture of the current slide, including anything the lecturer has written on it, \
    the slide's private prep notes (shown under the slide on the iPad), and the full text of the deck is below. \
    When the lecturer asks you to change, add to or remove from the prep notes, call update_prep_notes. It \
    replaces the slide's notes entirely, so include everything that should stay, and keep the lecturer's own \
    reminders unless asked to remove them. Then confirm in one short line. Don't call it unless asked.
    """

    /// Lets Claude rewrite the current slide's prep notes from the chat.
    nonisolated private static let tools: [[String: Any]] = [[
        "name": "update_prep_notes",
        "description": "Replace the private prep notes for the slide currently on screen. Notes are shown under the slide on the lecturer's iPad. Include every item that should remain; anything omitted is deleted. Use empty strings or empty arrays for parts with nothing to say.",
        "input_schema": PrepNote.schema(includingSlide: false, includingReminders: true),
        "strict": true,
        "eager_input_streaming": true,
    ]]

    /// The panel's request: short answers at medium effort, deck text as cached context.
    nonisolated private static func stream(connection: AIConnection, deckText: String,
                                           messages: [[String: Any]],
                                           onText: @escaping @MainActor (String) -> Void) async -> StreamResult {
        let body: [String: Any] = [
            "max_tokens": 64000,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "medium"],
            "system": [
                ["type": "text", "text": instructions],
                ["type": "text", "text": deckText, "cache_control": ["type": "ephemeral"]],
            ],
            "tools": tools,
            "messages": messages,
        ]
        return await stream(connection: connection, body: body, timeout: 300, onText: onText)
    }

    /// Sends a request (in the Messages API's shape) to whichever provider is chosen.
    nonisolated static func stream(connection: AIConnection, body: [String: Any], timeout: TimeInterval,
                                   onText: @escaping @MainActor (String) -> Void) async -> StreamResult {
        switch connection.provider {
        case .claude:
            return await stream(key: connection.key, model: connection.claudeModel, body: body, timeout: timeout, onText: onText)
        case .other:
            return await OpenAICompatible.stream(connection: connection, body: body, timeout: timeout, onText: onText)
        }
    }

    /// Streams one Messages API request. `body` holds everything except the model, streaming
    /// and the refusal fallback, which are added here. `onText` gets the visible text so far.
    nonisolated static func stream(key: String, model: AssistantModel, body: [String: Any],
                                   timeout: TimeInterval,
                                   onText: @escaping @MainActor (String) -> Void) async -> StreamResult {
        var body = body
        body["model"] = model.rawValue
        body["stream"] = true
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if model.supportsFallback {
            // If a safety classifier declines, Anthropic re-runs the request on its recommended model.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure("Couldn't prepare the request.")
        }
        request.httpBody = data

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                var raw = Data()
                for try await byte in bytes {
                    raw.append(byte)
                    if raw.count > 64_000 { break }
                }
                return .failure(friendlyError(status: status, body: raw))
            }

            var blocks: [[String: Any]] = []
            var position: [Int: Int] = [:]      // stream index -> position in `blocks`
            var visible = ""                      // text since the last model switch
            var stopReason: String?
            var partialJSON: [Int: String] = [:]   // tool-call input as it streams, by position
            for try await line in bytes.lines {
                guard line.hasPrefix("data:"),
                      let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any],
                      let type = json["type"] as? String else { continue }
                switch type {
                case "content_block_start":
                    guard let index = json["index"] as? Int, let block = json["content_block"] as? [String: Any] else { continue }
                    position[index] = blocks.count
                    blocks.append(block)
                    if block["type"] as? String == "fallback" {
                        // A declined attempt was re-run on another model: drop its partial answer.
                        visible = ""
                        await onText(visible)
                    }
                case "content_block_delta":
                    guard let index = json["index"] as? Int, let at = position[index],
                          let delta = json["delta"] as? [String: Any] else { continue }
                    switch delta["type"] as? String {
                    case "text_delta":
                        let piece = delta["text"] as? String ?? ""
                        blocks[at]["text"] = (blocks[at]["text"] as? String ?? "") + piece
                        visible += piece
                        await onText(visible)
                    case "thinking_delta":
                        blocks[at]["thinking"] = (blocks[at]["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                    case "signature_delta":
                        blocks[at]["signature"] = delta["signature"]
                    case "input_json_delta":
                        partialJSON[at, default: ""] += delta["partial_json"] as? String ?? ""
                    default:
                        break
                    }
                case "content_block_stop":
                    // A finished tool call: parse its streamed input (validated again by the caller).
                    guard let index = json["index"] as? Int, let at = position[index], let raw = partialJSON[at] else { continue }
                    let parsed = raw.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
                    blocks[at]["input"] = parsed ?? [:]
                case "message_delta":
                    if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                        stopReason = reason
                    }
                case "error":
                    let error = json["error"] as? [String: Any]
                    return .failure(friendlyError(type: error?["type"] as? String, message: error?["message"] as? String))
                default:
                    break
                }
            }
            if Task.isCancelled { return .cancelled }
            if stopReason == "refusal" {
                return .failure("Claude declined to answer this one. Try rephrasing the question.")
            }
            return .success(blocks: blocks, visible: visible, stopReason: stopReason)
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost].contains(error.code) {
            return .failure("No connection to Claude. Check the iPad's Wi-Fi and try again.")
        } catch {
            return .failure("Something went wrong talking to Claude: \(error.localizedDescription)")
        }
    }

    nonisolated private static func friendlyError(status: Int, body: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        switch status {
        case 401: return "That API key wasn't accepted. Check it in the key settings above."
        case 403: return "This API key isn't allowed to use that model. Try another model, or check the key's permissions."
        case 429: return "Too many requests right now (rate limit). Wait a moment and try again."
        case 529: return "Claude is overloaded at the moment. Try again in a few seconds, or switch to a smaller model."
        default: return friendlyError(type: error?["type"] as? String, message: error?["message"] as? String, status: status)
        }
    }

    nonisolated private static func friendlyError(type: String?, message: String?, status: Int? = nil) -> String {
        switch type {
        case "overloaded_error": return "Claude is overloaded at the moment. Try again in a few seconds, or switch to a smaller model."
        case "rate_limit_error": return "Too many requests right now (rate limit). Wait a moment and try again."
        case "authentication_error": return "That API key wasn't accepted. Check it in the key settings above."
        default:
            let code = status.map { " (HTTP \($0))" } ?? ""
            return "Claude returned an error\(code): \(message ?? "unknown error")"
        }
    }
}
