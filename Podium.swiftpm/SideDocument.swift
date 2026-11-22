import SwiftUI

/// Choose the second PDF: from the library (linked folders and added PDFs) or straight from Files.
struct SideDocumentPicker: View {
    /// Open the PDF in a new tab instead of beside the deck.
    var asTab = false
    @Environment(\.dismiss) private var dismiss
    @State private var loading: String?
    @State private var failed: String?
    private var store: LibraryStore { LibraryStore.shared }

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.folders) { folder in
                    Section {
                        ForEach(store.folderFiles[folder.id] ?? []) { file in
                            row(file.name, detail: file.subfolder) {
                                guard let scope = store.url(of: folder) else { return nil }
                                return (file.url, scope, CompanionTarget(url: Companion.url(for: file.url), scope: scope))
                            }
                        }
                    } header: {
                        let place = store.place(of: folder)
                        let name = store.name(of: folder)
                        Text(place.isEmpty ? name : "\(name)  ·  in \(place)")
                    }
                }
                if !store.items.isEmpty {
                    Section("Added files") {
                        ForEach(store.items) { item in
                            row(item.name, detail: store.place(of: item)) {
                                store.url(of: item).map { ($0, $0, nil) }
                            }
                        }
                    }
                }
                Section {
                    Button("Other File from Files…", systemImage: "doc.badge.plus") {
                        DocumentPicker.present(types: OtherFiles.contentTypes, multiple: false) { urls in
                            guard let url = urls.first else { return }
                            // It joins the library's added files, so it's easy to find again.
                            store.add([url])
                            open(title: OtherFiles.displayName(url.lastPathComponent), url: url, scope: url, companion: nil)
                        }
                    }
                }
            }
            .overlay {
                if let loading {
                    ProgressView("Opening \(loading)…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .navigationTitle(asTab ? "Open in New Tab" : "Open Side by Side")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Couldn't open \(failed ?? "this file")",
                   isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func row(_ name: String, detail: String,
                     target: @escaping () -> (url: URL, scope: URL, companion: CompanionTarget?)?) -> some View {
        Button {
            guard let target = target() else {
                failed = name
                return
            }
            open(title: name, url: target.url, scope: target.scope, companion: target.companion)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(.primary)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(loading != nil)
    }

    private func open(title: String, url: URL, scope: URL, companion: CompanionTarget?) {
        loading = title
        Task {
            let loaded = await LibraryStore.loadDeck(at: url, scope: scope, title: title, companion: companion)
            loading = nil
            guard let deck = loaded?.deck else {
                failed = title
                return
            }
            withAnimation(.snappy) {
                if asTab {
                    PresentationState.shared.openTab(deck, notesID: Notes.id(for: url), companion: companion,
                                                     companionFile: loaded?.companion,
                                                     source: TabSource(url: url, scope: scope, title: title))
                } else {
                    PresentationState.shared.openSecondary(deck, notesID: Notes.id(for: url), companion: companion,
                                                           companionFile: loaded?.companion,
                                                           source: TabSource(url: url, scope: scope, title: title))
                }
            }
            dismiss()
        }
    }
}
