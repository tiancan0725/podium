import SwiftUI

/// One PDF's notes kept on this iPad (ink and/or prep notes, filed by the PDF's id).
struct StoredDeck: Identifiable {
    let id: String
    var title: String
    var hasInk: Bool
    var hasPrep: Bool
    var bytes: Int64
    var lastUsed: Date?
}

/// What Podium keeps on this iPad, and the optional cleanup of notes that haven't been used in a while.
/// Only Podium's own copies are touched; companion ".podium" files next to PDFs are never deleted here.
@MainActor
enum Storage {
    static let cleanupKey = "storage.cleanupDays"
    private static let lastRunKey = "storage.cleanupLastRun"
    private static let usageKey = "storage.lastUsed"

    /// Days without use before notes are removed automatically; 0 means never.
    static var cleanupDays: Int { UserDefaults.standard.integer(forKey: cleanupKey) }

    private static var lastUsed: [String: Date] {
        get { (UserDefaults.standard.dictionary(forKey: usageKey) as? [String: Date]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: usageKey) }
    }

    static func markUsed(_ id: String) {
        lastUsed[id] = .now
    }

    static func list() -> [StoredDeck] {
        var decks: [String: StoredDeck] = [:]
        let usage = lastUsed
        func scan(_ directory: URL, isPrep: Bool) {
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
            for file in files where file.pathExtension == "json" {
                let id = file.deletingPathExtension().lastPathComponent
                let values = try? file.resourceValues(forKeys: Set(keys))
                var deck = decks[id] ?? StoredDeck(id: id, title: "Untitled", hasInk: false, hasPrep: false, bytes: 0,
                                                   lastUsed: usage[id])
                deck.bytes += Int64(values?.fileSize ?? 0)
                if isPrep { deck.hasPrep = true } else { deck.hasInk = true }
                if let title = title(of: file) { deck.title = title }
                // Notes saved before usage was tracked: fall back to when the file last changed.
                if usage[id] == nil, let modified = values?.contentModificationDate {
                    deck.lastUsed = max(deck.lastUsed ?? .distantPast, modified)
                }
                decks[id] = deck
            }
        }
        scan(Notes.directory, isPrep: false)
        scan(PrepStore.directory, isPrep: true)
        return decks.values.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    private static func title(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["title"] as? String
    }

    static func delete(_ id: String) {
        Notes.delete(id)
        PrepStore.delete(id)
        Inserts.deleteAll(id)
        lastUsed[id] = nil
    }

    /// Removes notes unused for longer than the chosen period. Runs at most once a day, from the library
    /// (so no PDF is open at the time).
    static func autoCleanup() {
        let days = cleanupDays
        guard days > 0 else { return }
        let lastRun = UserDefaults.standard.object(forKey: lastRunKey) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(lastRun) > 86_400 else { return }
        UserDefaults.standard.set(Date.now, forKey: lastRunKey)
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        for deck in list() where (deck.lastUsed ?? .distantPast) < cutoff {
            delete(deck.id)
        }
    }
}

/// Library → Manage Storage.
struct StorageView: View {
    /// Ids of PDFs currently in the library, to flag notes whose PDF is gone.
    let libraryIDs: Set<String>
    @Environment(\.dismiss) private var dismiss
    @Bindable private var state = PresentationState.shared
    @AppStorage(Storage.cleanupKey) private var cleanupDays = 0
    @State private var decks: [StoredDeck] = []
    @State private var deleting: StoredDeck?
    @State private var confirmDeleteAll = false

    private static let periods: [(days: Int, title: String)] = [
        (0, "Never"), (30, "1 month"), (90, "3 months"), (180, "6 months"), (365, "1 year"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Remove notes not used for", selection: $cleanupDays) {
                        ForEach(Self.periods, id: \.days) { Text($0.title).tag($0.days) }
                    }
                } header: {
                    Text("Auto cleanup")
                } footer: {
                    Text("Checked once a day. Removes Podium's copy on this iPad only: your PDFs, and any .podium files next to them, are never touched.")
                }

                Section {
                    Toggle("Save notes next to PDFs", isOn: $state.companionEnabled)
                } footer: {
                    Text("For PDFs in linked folders: a small .podium file beside each PDF keeps its ink and prep notes, so they sync with Dropbox or iCloud and survive cleanup or deleting the app.")
                }

                Section {
                    if decks.isEmpty {
                        Text("No saved notes.").foregroundStyle(.secondary)
                    }
                    ForEach(decks) { deck in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(deck.title).font(.body)
                            Text(detail(deck)).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { deleting = deck }
                        }
                    }
                } header: {
                    Text("Saved notes · \(ByteCountFormatter.string(fromByteCount: decks.reduce(0) { $0 + $1.bytes }, countStyle: .file))")
                } footer: {
                    Text("Swipe left to delete one PDF's notes.")
                }

                if !decks.isEmpty {
                    Section {
                        Button("Delete All Notes…", role: .destructive) { confirmDeleteAll = true }
                    }
                }
            }
            .navigationTitle("Manage Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { decks = Storage.list() }
            .confirmationDialog("Delete the notes for \(deleting?.title ?? "this PDF")?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Notes", role: .destructive) {
                    if let deleting { Storage.delete(deleting.id) }
                    decks = Storage.list()
                }
            } message: {
                Text("Its ink, prep notes and inserted pages on this iPad will be deleted. This can't be undone (a .podium file next to the PDF, if any, is kept).")
            }
            .confirmationDialog("Delete all saved notes?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete All Notes", role: .destructive) {
                    decks.forEach { Storage.delete($0.id) }
                    decks = Storage.list()
                }
            } message: {
                Text("Ink and prep notes for every PDF on this iPad will be deleted. This can't be undone.")
            }
        }
    }

    private func detail(_ deck: StoredDeck) -> String {
        var parts: [String] = []
        if deck.hasInk { parts.append("Ink") }
        if deck.hasPrep { parts.append("Prep notes") }
        parts.append(ByteCountFormatter.string(fromByteCount: deck.bytes, countStyle: .file))
        if let used = deck.lastUsed { parts.append("used \(used.formatted(.relative(presentation: .named)))") }
        if !libraryIDs.contains(deck.id) { parts.append("PDF not in library") }
        return parts.joined(separator: " · ")
    }
}
