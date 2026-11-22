import SwiftUI

/// The Claude side panel on the presenter's iPad. Never shown on the projector.
struct AssistantPanel: View {
    @Bindable private var assistant = AssistantStore.shared
    @State private var draft = ""
    @State private var showSettings = false
    @State private var showPrep = false
    @FocusState private var fieldFocused: Bool
    let onClose: () -> Void

    var body: some View {
        let state = PresentationState.shared
        let slide = state.primary.deck.map { $0.slideIndex(ofPage: state.primary.pageIndex) } ?? 0
        let conversation = assistant.conversation(for: slide)
        let busy = assistant.streamingSlide != nil

        VStack(spacing: 0) {
            header(slide: slide, hasTurns: !conversation.turns.isEmpty)
            Divider()
            PrepStatus()
            if !assistant.hasKey {
                KeySetup()
                    .padding(16)
                Spacer()
            } else {
                messages(conversation, slide: slide)
                chips(busy: busy)
                inputRow(busy: busy, slide: slide)
            }
        }
        .background(Color.panelBackground)
    }

    // MARK: Pieces

    private func header(slide: Int, hasTurns: Bool) -> some View {
        HStack(spacing: 14) {
            Label("\(assistant.activeName.isEmpty ? "Claude" : assistant.activeName) · slide \(slide + 1)", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            if hasTurns {
                Button {
                    assistant.reset(slide: slide)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Start this slide's conversation over")
            }
            Button {
                showPrep = true
            } label: {
                Image(systemName: "list.bullet.clipboard")
            }
            .help("Prep the whole deck")
            .popover(isPresented: $showPrep) {
                PrepPopover()
                    .padding(16)
                    .frame(width: 340)
            }
            Button {
                showSettings = true
            } label: {
                Image(systemName: "key")
            }
            .popover(isPresented: $showSettings) {
                KeySetup()
                    .padding(16)
                    .frame(width: 340)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func messages(_ conversation: AssistantConversation, slide: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if conversation.turns.isEmpty {
                        Text("Ask about the slide on screen. Claude sees the slide (with your ink) and the whole deck. Only you see this panel.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(conversation.turns) { turn in
                        TurnView(turn: turn, slide: slide,
                                 thinking: turn.id == conversation.turns.last?.id
                                    && assistant.streamingSlide == slide && assistant.waitingForText)
                            .id(turn.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: conversation.turns.last?.text) {
                if let id = conversation.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func chips(busy: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AssistantStore.quickPrompts, id: \.title) { chip in
                    Button(chip.title) { assistant.send(chip.prompt) }
                        .font(.footnote)
                        .buttonStyle(.bordered)
                        .disabled(busy)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func inputRow(busy: Bool, slide: Int) -> some View {
        HStack(spacing: 10) {
            TextField("Ask about this slide…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(sendDraft)
            if busy {
                Button {
                    assistant.stop()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .help("Stop")
            } else {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func sendDraft() {
        guard assistant.streamingSlide == nil else { return }
        assistant.send(draft)
        draft = ""
    }
}

private struct TurnView: View {
    let turn: AssistantTurn
    let slide: Int
    let thinking: Bool

    var body: some View {
        if turn.isUser {
            Text(turn.text)
                .textSelection(.enabled)
                .padding(10)
                .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else if thinking && turn.text.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                Text("Thinking…").foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.markdown(turn.text))
                    .textSelection(.enabled)
                    .foregroundStyle(turn.isError ? Color.orange : Color.primary)
                if turn.editedNotes {
                    HStack(spacing: 12) {
                        Label("Updated this slide's notes", systemImage: "list.bullet.clipboard")
                            .font(.caption)
                            .foregroundStyle(.mint)
                        if PrepStore.shared.undo[slide] != nil {
                            Button("Undo") { PrepStore.shared.undoEdit(slide: slide) }
                                .font(.caption)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Inline Markdown (bold, italics, code) with line breaks kept.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Saved connections (each a name, a provider and a key), the one in use ticked; below, the chosen one's
/// settings. Keys go straight to the Keychain and are never shown again.
private struct KeySetup: View {
    @Bindable private var assistant = AssistantStore.shared
    @State private var key = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connections").font(.headline)
                Spacer()
                Menu {
                    Button("Claude (Anthropic)") { assistant.addProfile(.claude) }
                    Button("Other provider (OpenAI-compatible)") { assistant.addProfile(.other) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            VStack(spacing: 0) {
                ForEach(assistant.profiles) { profile in
                    Button {
                        assistant.activeID = profile.id
                        key = ""
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: profile.id == assistant.active?.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(profile.id == assistant.active?.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.name.isEmpty ? "Unnamed" : profile.name).foregroundStyle(.primary)
                                Text(profile.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !assistant.hasKey(for: profile) {
                                Text("no key").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if profile.id != assistant.profiles.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 10)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            Text("Tap a connection to use it. Each keeps its own key, so you can switch any time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let active = assistant.active {
                Divider()
                TextField("Name", text: $assistant.activeName)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                if active.kind == .claude {
                    Picker("Model", selection: $assistant.model) {
                        ForEach(AssistantModel.allCases) { Text($0.title).tag($0) }
                    }
                } else {
                    HStack {
                        TextField("https://…/v1", text: $assistant.otherBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Menu("Presets") {
                            ForEach(OtherProviderPreset.allCases, id: \.title) { preset in
                                Button(preset.title) {
                                    assistant.otherBaseURL = preset.baseURL
                                    if assistant.activeName == "New provider" { assistant.activeName = preset.title }
                                }
                            }
                        }
                    }
                    TextField("Model name (from the provider's docs)", text: $assistant.otherModel)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                let saved = assistant.hasKey(for: active)
                SecureField(saved ? "Replace key…" : (active.kind == .claude ? "sk-ant-…" : "API key"), text: $key)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("Save Key") {
                        assistant.setKey(key)
                        key = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if saved {
                        Button("Remove Key", role: .destructive) { assistant.removeKey() }
                    }
                    Spacer()
                    if assistant.profiles.count > 1 {
                        Button("Delete Connection", role: .destructive) { confirmDelete = true }
                            .font(.footnote)
                    }
                }
                Text(active.kind == .claude
                     ? "Stored in this iPad's Keychain and only sent to Anthropic. Each question costs a few cents with Opus, less with Sonnet or Haiku."
                     : "Stored in this iPad's Keychain and only sent to the address above. The model needs to read images (for the slide picture); prep mode needs one that returns JSON in a fixed format.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Delete \u{201C}\(assistant.activeName)\u{201D}?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Connection", role: .destructive) {
                if let active = assistant.active { assistant.deleteProfile(active) }
            }
        } message: {
            Text("Its key is removed from this iPad. Your other connections stay.")
        }
    }
}

/// Progress or errors from prep mode, under the panel header.
private struct PrepStatus: View {
    var body: some View {
        let prep = PrepStore.shared
        if prep.isRunning {
            HStack(spacing: 10) {
                ProgressView(value: Double(prep.slidesDone), total: Double(max(prep.slidesTotal, 1)))
                Text("Prepping \(prep.slidesDone)/\(prep.slidesTotal)")
                    .font(.caption.monospacedDigit())
                Button("Cancel") { prep.cancel() }
                    .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        } else if let error = prep.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Starts prep mode: Claude reads the whole deck and writes notes for every slide,
/// optionally following the lecturer's instructions, or only for slides without notes.
private struct PrepPopover: View {
    @State private var instructions = PrepStore.shared.instructions
    @State private var onlyMissing = PrepStore.shared.created != nil

    var body: some View {
        let prep = PrepStore.shared
        let assistant = AssistantStore.shared
        let missing = prep.missingSlides.count
        VStack(alignment: .leading, spacing: 12) {
            Text("Prep this deck").font(.headline)
            Text("Claude reads the whole PDF and writes private notes for each slide: likely student questions with answers, where to slow down, a backup example, and anything that looks wrong. They appear under each slide on this iPad only, and are saved with the PDF.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Optional instructions, e.g. “first-year PhD class, focus on intuition”", text: $instructions, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            if let created = prep.created {
                Toggle("Only slides without notes (\(missing))", isOn: $onlyMissing)
                    .font(.footnote)
                Text(onlyMissing
                     ? "Slides that already have notes, including your edits, are kept."
                     : "Replaces the notes on every slide, including your edits. Last prepped \(created.formatted(.relative(presentation: .named))).")
                    .font(.caption)
                    .foregroundStyle(onlyMissing ? Color.secondary : Color.orange)
            }
            if let deck = PresentationState.shared.primary.deck {
                let slides = (prep.created != nil && onlyMissing) ? missing : deck.slides.count
                if assistant.provider == .claude {
                    let cost = PrepStore.estimatedCost(deck: deck, model: assistant.model, slides: slides)
                    Text("Model: \(assistant.model.title). Estimated cost: about \(cost < 0.1 ? "a few cents" : String(format: "$%.2f", cost)). Takes a minute or two.")
                        .font(.footnote)
                } else {
                    Text("Model: \(assistant.otherModel) via \(assistant.activeName). Takes a minute or two.")
                        .font(.footnote)
                }
            }
            if prep.isRunning {
                Button("Cancel Prep", role: .destructive) { prep.cancel() }
            } else {
                Button(prep.created == nil ? "Prep with Claude" : "Prep Again") {
                    prep.start(instructions: instructions,
                               onlyMissing: prep.created != nil && onlyMissing)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!assistant.hasKey || (prep.created != nil && onlyMissing && missing == 0))
                if !assistant.hasKey {
                    Text("Add your API key first (key button).").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}
