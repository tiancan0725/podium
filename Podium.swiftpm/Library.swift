import SwiftUI
import UniformTypeIdentifiers
import PencilKit

/// A PDF the user imported. We keep a bookmark to the original file rather than a copy,
/// so recompiling the Beamer source and reopening it here always shows the latest version.
struct LibraryItem: Codable, Identifiable {
    var id = UUID()
    var name: String
    var bookmark: Data
    var lastOpened: Date?
    var notesID: String?           // see Notes.id(for:); filled when added or opened
}

/// A folder the user linked. Podium lists the PDFs in it (and its subfolders) itself.
struct LibraryFolder: Codable, Identifiable {
    var id = UUID()
    var name: String
    var bookmark: Data
}

/// A PDF found inside a linked folder.
struct FolderFile: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let subfolder: String          // path relative to the linked folder, "" at the top level
    let modified: Date?
}

@MainActor @Observable
final class LibraryStore {
    /// One library for the whole app, so the presenter can open a second PDF from it.
    static let shared = LibraryStore()
    private(set) var items: [LibraryItem] = []
    private(set) var folders: [LibraryFolder] = []
    private(set) var folderFiles: [UUID: [FolderFile]] = [:]
    private let defaultsKey = "library.items"
    private let foldersKey = "library.folders"
    /// Where each folder or added PDF lives, for display (resolving bookmarks on every redraw would be slow).
    @ObservationIgnored private var places: [UUID: String] = [:]
    @ObservationIgnored private var names: [UUID: String] = [:]

    /// "Dropbox › Teaching › ECON 720", the folder a linked folder or an added PDF sits in.
    func place(of item: LibraryItem) -> String {
        if let known = places[item.id] { return known }
        let place = url(of: item).map { Self.displayPath(of: $0.deletingLastPathComponent()) } ?? ""
        places[item.id] = place
        return place
    }

    /// A linked folder's name as the Files app shows it. Linking the top of a cloud drive gives a folder
    /// whose real name is an id ("FEE8AB6E"); the system usually knows its display name ("Dropbox").
    func name(of folder: LibraryFolder) -> String {
        if let known = names[folder.id] { return known }
        var name = folder.name
        if let url = url(of: folder) {
            let accessing = url.startAccessingSecurityScopedResource()
            if let localized = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName,
               !Self.looksLikeID(localized) {
                name = localized
            }
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        if Self.looksLikeID(name) { name = "Linked folder" }
        names[folder.id] = name
        return name
    }

    func place(of folder: LibraryFolder) -> String {
        if let known = places[folder.id] { return known }
        let place = url(of: folder).map { Self.displayPath(of: $0.deletingLastPathComponent()) } ?? ""
        places[folder.id] = place
        return place
    }

    /// A readable path: the storage provider's name, then the folders inside it, without the
    /// system's own folders (app containers, ids) in between. Very deep paths keep their last folders.
    nonisolated static func displayPath(of url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
        var root: String?
        var rest: [String]
        if let i = parts.firstIndex(of: "com~apple~CloudDocs") {
            root = "iCloud Drive"
            rest = Array(parts[(i + 1)...])
        } else if let i = parts.firstIndex(of: "Mobile Documents"), i + 1 < parts.count {
            root = "iCloud Drive"
            rest = Array(parts[(i + 2)...])
        } else if let i = parts.firstIndex(of: "CloudStorage"), i + 1 < parts.count {
            root = parts[i + 1].components(separatedBy: "-").first
            rest = Array(parts[(i + 2)...])
        } else if let i = parts.firstIndex(of: "File Provider Storage") {
            rest = Array(parts[(i + 1)...])
            // Apps like Dropbox keep their files under an id ("FEE8AB6E"); ask the system for the
            // provider's own name for that folder, and drop the id if it doesn't know one.
            if let id = rest.first, looksLikeID(id) {
                let domain = URL(fileURLWithPath: "/" + parts[...(i + 1)].joined(separator: "/"))
                if let name = (try? domain.resourceValues(forKeys: [.localizedNameKey]))?.localizedName,
                   name != id, !looksLikeID(name) {
                    root = name
                }
            }
        } else if let i = parts.firstIndex(of: "Documents"), parts.contains("Application") || parts.contains("Data") {
            root = "Podium"
            rest = Array(parts[(i + 1)...])
        } else {
            rest = parts
        }
        rest = rest.filter { !looksLikeID($0) }
        if root == nil, let first = rest.first, ["Dropbox", "OneDrive", "Box", "Google Drive"].contains(first) {
            root = first
            rest.removeFirst()
        }
        if rest.count > 5 { rest = ["…"] + rest.suffix(4) }
        return ([root].compactMap { $0 } + rest).joined(separator: " › ")
    }

    /// Folder names that are really system ids (UUIDs, long hex or digit strings).
    nonisolated static func looksLikeID(_ name: String) -> Bool {
        if UUID(uuidString: name) != nil { return true }
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        // Hex ids such as "FEE8AB6E": at least 8 characters, mixing digits and letters.
        if name.count >= 8, name.unicodeScalars.allSatisfy(hex.contains),
           name.contains(where: \.isNumber), name.contains(where: \.isLetter) { return true }
        // Long numeric ids (but not dates like 20261117).
        return name.count >= 10 && name.allSatisfy(\.isNumber)
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([LibraryItem].self, from: data) {
            items = saved
        }
        if let data = UserDefaults.standard.data(forKey: foldersKey),
           let saved = try? JSONDecoder().decode([LibraryFolder].self, from: data) {
            folders = saved
        }
    }

    // MARK: Single files

    func add(_ urls: [URL]) {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let bookmark = try? url.bookmarkData() else { continue }
            let name = OtherFiles.displayName(url.lastPathComponent)
            let existing = items.filter { resolveBookmark($0.bookmark)?.standardizedFileURL == url.standardizedFileURL }
            items.removeAll { item in existing.contains { $0.id == item.id } }
            items.insert(LibraryItem(name: name, bookmark: bookmark, lastOpened: nil,
                                     notesID: Notes.id(for: url)), at: 0)
        }
        save()
    }

    func remove(_ item: LibraryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func url(of item: LibraryItem) -> URL? {
        resolve(item.id, item.bookmark) { [weak self] fresh in
            guard let self, let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.items[index].bookmark = fresh
        }
    }

    /// Bookmarks resolved so far (resolving on every redraw would be slow); cleared on refresh.
    @ObservationIgnored private var resolved: [UUID: URL] = [:]

    /// Resolves a bookmark. A stale one is renewed afterwards, outside the view update that asked.
    private func resolve(_ id: UUID, _ bookmark: Data, renew: @escaping (Data) -> Void) -> URL? {
        if let known = resolved[id] { return known }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return nil }
        resolved[id] = url
        if stale {
            Task { @MainActor [weak self] in
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let fresh = try? url.bookmarkData() else { return }
                renew(fresh)
                self?.save()
            }
        }
        return url
    }

    func markOpened(_ item: LibraryItem, notesID: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].lastOpened = .now
        items[index].notesID = notesID
        let opened = items.remove(at: index)
        items.insert(opened, at: 0)
        save()
    }

    // MARK: Folders

    func addFolder(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData() else { return }
        folders.removeAll { resolveBookmark($0.bookmark)?.standardizedFileURL == url.standardizedFileURL }
        folders.insert(LibraryFolder(name: url.lastPathComponent, bookmark: bookmark), at: 0)
        save()
    }

    func removeFolder(_ folder: LibraryFolder) {
        folders.removeAll { $0.id == folder.id }
        folderFiles[folder.id] = nil
        save()
    }

    func url(of folder: LibraryFolder) -> URL? {
        resolve(folder.id, folder.bookmark) { [weak self] fresh in
            guard let self, let index = self.folders.firstIndex(where: { $0.id == folder.id }) else { return }
            self.folders[index].bookmark = fresh
        }
    }

    /// Re-reads every linked folder off the main thread.
    func refreshFolders() async {
        // Files may have moved since: resolve bookmarks and paths afresh.
        resolved = [:]
        places = [:]
        names = [:]
        for folder in folders {
            guard let url = url(of: folder) else { continue }
            let files = await Task.detached(priority: .userInitiated) { Self.scan(url) }.value
            // Unlinked while it was being read: don't bring it back.
            guard folders.contains(where: { $0.id == folder.id }) else { continue }
            folderFiles[folder.id] = files
        }
    }

    /// Every PDF under `root`, newest first. iCloud files that aren't downloaded yet
    /// show up as ".name.pdf.icloud" placeholders; list them under their real name.
    nonisolated private static func scan(_ root: URL) -> [FolderFile] {
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        refreshListing(of: root, depth: 0)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsPackageDescendants]) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var files: [FolderFile] = []
        for case let url as URL in enumerator {
            var fileName = url.lastPathComponent
            var fileURL = url
            if fileName.hasPrefix("."), fileName.lowercased().hasSuffix(".icloud"),
               OtherFiles.canOpen(String(fileName.dropFirst().dropLast(".icloud".count))) {
                fileName = String(fileName.dropFirst().dropLast(".icloud".count))
                fileURL = url.deletingLastPathComponent().appendingPathComponent(fileName)
            } else if fileName.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard OtherFiles.canOpen(fileName) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let parentPath = fileURL.deletingLastPathComponent().standardizedFileURL.path
            let subfolder = parentPath.hasPrefix(rootPath)
                ? String(parentPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : ""
            files.append(FolderFile(url: fileURL,
                                    name: OtherFiles.displayName(fileName),
                                    subfolder: subfolder,
                                    modified: values?.contentModificationDate))
        }
        return files.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// Cloud apps like Dropbox only fetch a folder's current contents when someone asks for them.
    /// A coordinated read of each folder makes the provider update its listing (file contents
    /// stay in the cloud until a PDF is opened).
    nonisolated private static func refreshListing(of folder: URL, depth: Int) {
        var subfolders: [URL] = []
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.immediatelyAvailableMetadataOnly], error: &error) { url in
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                      options: [.skipsHiddenFiles])) ?? []
            subfolders = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        }
        guard depth < 3 else { return }
        for subfolder in subfolders.prefix(50) { refreshListing(of: subfolder, depth: depth + 1) }
    }

    // MARK: Loading

    /// Reads a PDF off the main thread (downloading it from iCloud if needed) and splits it into slides.
    /// `scope` is the security-scoped URL that grants access: the file itself or its linked folder.
    /// Also reads the PDF's companion notes file when that's turned on and the PDF is in a linked folder.
    nonisolated static func loadDeck(at url: URL, scope: URL, title: String,
                                     companion: CompanionTarget?) async -> (deck: Deck, companion: CompanionFile?)? {
        let read = await Task.detached(priority: .userInitiated) { () -> (Data?, CompanionFile?, String) in
            let accessing = scope.startAccessingSecurityScopedResource()
            defer { if accessing { scope.stopAccessingSecurityScopedResource() } }
            var data: Data?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
                data = try? Data(contentsOf: readURL)
            }
            let file = companion.flatMap { Companion.enabled ? Companion.read($0) : nil }
            // Pages added in Podium (blank pages, photos) are spliced in; the file itself is untouched.
            let notesID = Notes.id(for: url)
            if let inserts = file?.inserts { Inserts.adopt(inserts, id: notesID) }
            return (data, file, notesID)
        }.value
        // Markdown, text and images become PDF pages here (the file itself is untouched).
        guard let data = read.0, let pdf = await OtherFiles.pdfData(from: data, fileName: url.lastPathComponent) else { return nil }
        let file = read.1
        let notesID = read.2
        let isReader = OtherFiles.isReader(url.lastPathComponent)
        return await Task.detached(priority: .userInitiated) {
            guard let deck = Deck(data: pdf, title: title, inserts: Inserts.load(notesID), isReader: isReader) else { return nil }
            return (deck, file)
        }.value
    }

    private func resolveBookmark(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: foldersKey)
        }
    }
}

struct LibraryView: View {
    @State private var store = LibraryStore.shared
    @State private var presenting = false
    @State private var loadingName: String?
    @State private var failedName: String?
    /// Bumped when notes may have changed, so the "has notes" marks refresh.
    @State private var notesRevision = 0
    @State private var showStorage = false
    @State private var clearingNotes: (id: String, name: String, companion: CompanionTarget?)?

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty && store.folders.isEmpty {
                    ContentUnavailableView {
                        Label("No slides yet", systemImage: "rectangle.on.rectangle.angled")
                    } description: {
                        Text("Choose the folder where your Beamer PDFs live, or add single files (PDF, Markdown, text, images). Files stay linked to the originals, so recompiled slides show up the next time you open them.")
                    } actions: {
                        Button("Choose Folder") { chooseFolder() }
                            .buttonStyle(.borderedProminent)
                        Button("Add Files") { addFiles() }
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Podium")
            .toolbar {
                Button {
                    showStorage = true
                } label: {
                    Label("Manage Storage", systemImage: "internaldrive")
                }
                Menu {
                    Button("Choose Folder…", systemImage: "folder.badge.plus") { chooseFolder() }
                    Button("Add Files…", systemImage: "doc.badge.plus") { addFiles() }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            .overlay {
                if let loadingName {
                    ProgressView("Opening \(loadingName)…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .fullScreenCover(isPresented: $presenting, onDismiss: {
                PresentationState.shared.close()
                notesRevision += 1
                Task { await store.refreshFolders() }
            }) {
                PresenterView()
            }
            .alert("Couldn't open \(failedName ?? "this file")",
                   isPresented: Binding(get: { failedName != nil }, set: { if !$0 { failedName = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("It may have been moved or deleted, or it isn't a readable PDF.")
            }
            .confirmationDialog("Clear the notes on \(clearingNotes?.name ?? "this PDF")?",
                                isPresented: Binding(get: { clearingNotes != nil }, set: { if !$0 { clearingNotes = nil } }),
                                titleVisibility: .visible) {
                Button("Clear Notes", role: .destructive) {
                    if let clearingNotes {
                        Notes.delete(clearingNotes.id)
                        if let companion = clearingNotes.companion { Companion.clearInk(companion) }
                    }
                    notesRevision += 1
                }
            } message: {
                Text("All ink on its slides and its whiteboard will be deleted.")
            }
            .task {
                #if DEBUG
                // Testing aid: `-PodiumShowStorage YES` opens Manage Storage.
                if UserDefaults.standard.bool(forKey: "PodiumShowStorage") { showStorage = true }
                // Testing aid: launch with `-PodiumAutoOpen /path/to/deck.pdf` to open a deck directly.
                if let path = UserDefaults.standard.string(forKey: "PodiumAutoOpen"), !presenting {
                    let url = URL(fileURLWithPath: path)
                    load(url: url, scope: url, title: url.deletingPathExtension().lastPathComponent,
                         notesID: Notes.id(for: url),
                         companion: CompanionTarget(url: Companion.url(for: url), scope: url.deletingLastPathComponent())) {}
                }
                #endif
                Storage.autoCleanup()
                await store.refreshFolders()
            }
            .sheet(isPresented: $showStorage, onDismiss: { notesRevision += 1 }) {
                StorageView(libraryIDs: libraryIDs)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(store.folders) { folder in
                Section {
                    let files = store.folderFiles[folder.id] ?? []
                    if files.isEmpty {
                        Text(store.folderFiles[folder.id] == nil ? "Reading folder…" : "No PDFs in this folder yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(files) { file in
                        let notesID = Notes.id(for: file.url)
                        FileRow(name: file.name,
                                place: file.subfolder,
                                placeFolder: file.subfolder.isEmpty ? nil : file.url.deletingLastPathComponent(),
                                detail: file.modified.map { "Modified \($0.formatted(.relative(presentation: .named)))" } ?? "",
                                hasNotes: hasNotes(notesID))
                            .contentShape(Rectangle())
                            .onTapGesture { open(file, in: folder) }
                        .swipeActions {
                            if hasNotes(notesID) {
                                Button("Clear Notes", role: .destructive) {
                                    clearingNotes = (notesID, file.name, store.url(of: folder).map {
                                        CompanionTarget(url: Companion.url(for: file.url), scope: $0)
                                    })
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Label(store.name(of: folder), systemImage: "folder")
                        let place = store.place(of: folder)
                        if !place.isEmpty {
                            PlaceButton(place: "in \(place)", folder: store.url(of: folder)?.deletingLastPathComponent())
                                .textCase(nil)
                        }
                        Spacer()
                        Menu {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                Task { await store.refreshFolders() }
                            }
                            Button("Unlink Folder", systemImage: "folder.badge.minus", role: .destructive) {
                                store.removeFolder(folder)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }

            if !store.items.isEmpty {
                Section("Added files") {
                    ForEach(store.items) { item in
                        FileRow(name: item.name,
                                place: store.place(of: item),
                                placeFolder: store.url(of: item)?.deletingLastPathComponent(),
                                detail: item.lastOpened.map { "Opened \($0.formatted(.relative(presentation: .named)))" } ?? "",
                                hasNotes: item.notesID.map(hasNotes) ?? false)
                            .contentShape(Rectangle())
                            .onTapGesture { open(item) }
                        .swipeActions {
                            Button("Remove", role: .destructive) { store.remove(item) }
                            if let notesID = item.notesID, hasNotes(notesID) {
                                Button("Clear Notes") { clearingNotes = (notesID, item.name, nil) }
                                    .tint(.orange)
                            }
                        }
                    }
                }
            }
        }
        .refreshable { await store.refreshFolders() }
    }

    /// Notes ids of every PDF currently in the library.
    private var libraryIDs: Set<String> {
        var ids = Set(store.items.compactMap(\.notesID))
        for files in store.folderFiles.values { ids.formUnion(files.map { Notes.id(for: $0.url) }) }
        return ids
    }

    private func hasNotes(_ id: String) -> Bool {
        _ = notesRevision
        return Notes.exists(id)
    }

    // MARK: Actions

    private func chooseFolder() {
        DocumentPicker.present(types: [.folder], multiple: false) { urls in
            guard let url = urls.first else { return }
            store.addFolder(url)
            Task { await store.refreshFolders() }
        }
    }

    private func addFiles() {
        DocumentPicker.present(types: OtherFiles.contentTypes, multiple: true) { urls in
            store.add(urls)
        }
    }

    private func open(_ item: LibraryItem) {
        guard let url = store.url(of: item) else {
            failedName = item.name
            return
        }
        let notesID = Notes.id(for: url)
        load(url: url, scope: url, title: item.name, notesID: notesID, companion: nil) { store.markOpened(item, notesID: notesID) }
    }

    private func open(_ file: FolderFile, in folder: LibraryFolder) {
        guard let scope = store.url(of: folder) else {
            failedName = file.name
            return
        }
        load(url: file.url, scope: scope, title: file.name, notesID: Notes.id(for: file.url),
             companion: CompanionTarget(url: Companion.url(for: file.url), scope: scope)) {}
    }

    private func load(url: URL, scope: URL, title: String, notesID: String, companion: CompanionTarget?,
                      onSuccess: @escaping () -> Void) {
        guard loadingName == nil else { return }
        loadingName = title
        Task {
            let loaded = await LibraryStore.loadDeck(at: url, scope: scope, title: title, companion: companion)
            loadingName = nil
            if let deck = loaded?.deck {
                onSuccess()
                PresentationState.shared.open(deck, notesID: notesID, companion: companion,
                                              companionFile: loaded?.companion,
                                              source: TabSource(url: url, scope: scope, title: title))
                #if DEBUG
                // Testing aids: `-PodiumTestMargins YES` turns margins on; `-PodiumTestFinger YES` draws with a finger.
                if UserDefaults.standard.bool(forKey: "PodiumTestMargins") { PresentationState.shared.primary.margins = true }
                if UserDefaults.standard.bool(forKey: "PodiumTestFinger") { PresentationState.shared.fingerDraws = true }
                // Testing aid: `-PodiumTestSide /path/to/other.pdf` opens a second PDF beside the deck.
                if let sidePath = UserDefaults.standard.string(forKey: "PodiumTestSide") {
                    let sideURL = URL(fileURLWithPath: sidePath)
                    if let side = await LibraryStore.loadDeck(at: sideURL, scope: sideURL, title: sideURL.deletingPathExtension().lastPathComponent, companion: nil) {
                        PresentationState.shared.openSecondary(side.deck, notesID: Notes.id(for: sideURL), companion: nil, companionFile: nil)
                        if UserDefaults.standard.bool(forKey: "PodiumTestScroll") { PresentationState.shared.secondary?.scrollMode = true }
                    }
                }
                // Testing aid: `-PodiumTestTab /path/to/other.pdf` opens a second PDF in a new tab.
                if let tabPath = UserDefaults.standard.string(forKey: "PodiumTestTab") {
                    let tabURL = URL(fileURLWithPath: tabPath)
                    if let other = await LibraryStore.loadDeck(at: tabURL, scope: tabURL, title: tabURL.deletingPathExtension().lastPathComponent, companion: nil) {
                        PresentationState.shared.openTab(other.deck, notesID: Notes.id(for: tabURL), companion: nil, companionFile: nil,
                                                         source: TabSource(url: tabURL, scope: tabURL, title: other.deck.title))
                    }
                }
                // Testing aid: `-PodiumTestInk s2` adds a red stroke under that ink key.
                if let testKey = UserDefaults.standard.string(forKey: "PodiumTestInk") {
                    let size = deck.pageSize(0)
                    let points = (0...40).map { i -> PKStrokePoint in
                        let t = CGFloat(i) / 40
                        return PKStrokePoint(location: CGPoint(x: size.width * (0.2 + 0.6 * t),
                                                               y: size.height * (0.85 - 0.1 * sin(t * .pi))),
                                             timeOffset: TimeInterval(t), size: CGSize(width: 3, height: 3),
                                             opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                    }
                    let stroke = PKStroke(ink: PKInk(.pen, color: .red),
                                          path: PKStrokePath(controlPoints: points, creationDate: .now))
                    PresentationState.shared.primary.drawings[testKey] = PKDrawing(strokes: [stroke])
                    PresentationState.shared.primary.inkRevision += 1
                }
                #endif
                presenting = true
            } else {
                failedName = title
            }
        }
    }
}

private struct FileRow: View {
    let name: String
    /// Where the file is ("Dropbox › Teaching"); tapping it opens that folder in the Files app.
    var place: String = ""
    var placeFolder: URL?
    let detail: String
    var hasNotes = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if !place.isEmpty {
                        PlaceButton(place: place, folder: placeFolder)
                    }
                    if !detail.isEmpty {
                        Text((place.isEmpty ? "" : "· ") + detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if hasNotes {
                Spacer(minLength: 8)
                Image(systemName: "pencil.and.scribble")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Has notes")
            }
        }
        .padding(.vertical, 4)
    }
}

/// The system document picker, presented full screen so long file names have room
/// (SwiftUI's fileImporter uses a narrow form sheet on iPad).
@MainActor
enum DocumentPicker {
    private static var delegate: Delegate?

    static func present(types: [UTType], multiple: Bool, startingAt directory: URL? = nil,
                        completion: @escaping ([URL]) -> Void) {
        guard let top = UIApplication.topViewController else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.allowsMultipleSelection = multiple
        picker.directoryURL = directory
        picker.shouldShowFileExtensions = true
        picker.modalPresentationStyle = .fullScreen
        let delegate = Delegate(completion: completion)
        picker.delegate = delegate
        Self.delegate = delegate
        top.present(picker, animated: true)
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let completion: ([URL]) -> Void
        init(completion: @escaping ([URL]) -> Void) { self.completion = completion }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(urls)
            DocumentPicker.delegate = nil
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DocumentPicker.delegate = nil
        }
    }
}

/// A file's location. Tap it to add more files from that folder, link the folder, or show it in Files.
/// (Podium may only read what you pick, so the picker opens right in that folder.)
struct PlaceButton: View {
    let place: String
    let folder: URL?

    var body: some View {
        Menu {
            if let folder {
                Button("Add Files from This Folder…", systemImage: "doc.badge.plus") {
                    DocumentPicker.present(types: OtherFiles.contentTypes, multiple: true, startingAt: folder) { urls in
                        LibraryStore.shared.add(urls)
                    }
                }
                Button("Link This Folder…", systemImage: "folder.badge.plus") {
                    // Opens one level up with the folder in view: select it and tap Open.
                    DocumentPicker.present(types: [.folder], multiple: false, startingAt: folder.deletingLastPathComponent()) { urls in
                        guard let url = urls.first else { return }
                        LibraryStore.shared.addFolder(url)
                        Task { await LibraryStore.shared.refreshFolders() }
                    }
                }
                Button("Show in Files", systemImage: "arrow.up.forward.app") { FilesApp.show(folder) }
            }
        } label: {
            Label(place, systemImage: "folder")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .disabled(folder == nil)
    }
}

/// Opens a folder in Apple's Files app.
@MainActor
enum FilesApp {
    static func show(_ folder: URL) {
        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.path = folder.standardizedFileURL.path
        if let url = components.url { UIApplication.shared.open(url) }
    }
}
