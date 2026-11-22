import SwiftUI
import PencilKit
import Observation

/// One open PDF: its page, ink, zoom, pointer and whiteboard, and saving its notes.
/// The presenter has a main document (the deck) and optionally a second one beside it;
/// tools, colours and settings are shared and live in `PresentationState`.
@MainActor @Observable
final class DocumentState {
    /// The main deck owns the prep notes and the slide palette; a side document doesn't.
    let isPrimary: Bool

    private(set) var deck: Deck?
    private(set) var pageIndex = 0
    /// Bumped by deliberate page turns (keys, the grid, inserting a page), never by touching or scrolling
    /// a page, so scroll mode moves the list only when asked to.
    private(set) var jumpRequest = 0

    // Ink, stored in page coordinates (PDF points) so it renders at any size.
    var drawings: [String: PKDrawing] = [:] {
        didSet {
            notesDirty = true
            scheduleNotesSave()
        }
    }
    var inkRevision = 0
    var liveStroke: LiveStroke?
    let pointer = PointerState()

    // Whiteboard: a blank page that drops over the page. Its ink lives under its own key.
    var whiteboardShown = false

    /// Blank space beside each page for writing notes (see `Sheet`).
    var margins = false

    /// Continuous scrolling through all pages (for reading and note-taking) instead of one page at a time.
    var scrollMode = false
    /// In scroll mode, the page the pointer is on (pointer coordinates are per page).
    var pointerPage: Int?

    // Fast seeking by whole slides
    private(set) var isSeeking = false
    @ObservationIgnored private var seekTask: Task<Void, Never>?

    // Zoom, shared with the projector: `zoomFocus` is the page point (0...1) at the middle of the view.
    private(set) var zoom: CGFloat = 1
    private(set) var zoomFocus = CGPoint(x: 0.5, y: 0.5)
    /// The zoom the page is rendered at; catches up when a pinch ends, so pinching stays smooth.
    private(set) var renderZoom: CGFloat = 1
    static let maxZoom: CGFloat = 6
    static let minScrollZoom: CGFloat = 0.4

    @ObservationIgnored weak var activeCanvas: PKCanvasView?
    @ObservationIgnored private(set) var companion: CompanionTarget?
    @ObservationIgnored private var nextLiveStrokeID = 0

    init(isPrimary: Bool) {
        self.isPrimary = isPrimary
    }

    // MARK: Open and close

    /// Opens a deck with the notes saved for `notesID` (see `Notes.id(for:)`). If a companion file
    /// next to the PDF holds newer notes (say, from another iPad), those win.
    func open(_ deck: Deck, notesID: String?, companion: CompanionTarget?, companionFile: CompanionFile?) {
        self.deck = deck
        self.notesID = notesID
        self.companion = companion
        companionPrep = companionFile?.prep
        companionInserts = nil
        if let notesID { Storage.markUsed(notesID) }
        pageIndex = 0
        linkHistory = []
        var savedNotes = notesID.flatMap(Notes.load)
        var adoptedCompanionInk = false
        if let remote = companionFile?.ink,
           (remote.updated ?? .distantPast) > (savedNotes?.updated ?? .distantPast) {
            savedNotes = remote
            adoptedCompanionInk = true
        }
        notesUpdated = savedNotes?.updated
        let saved = savedNotes.map { Notes.drawings(from: $0.records, deck: deck) }
        orphanedNotes = saved?.orphans ?? []
        drawings = saved?.drawings ?? [:]
        notesDirty = false
        if adoptedCompanionInk, let notesID, let savedNotes { Notes.save(savedNotes, id: notesID) }
        debugLog("loaded notes for keys \(drawings.keys.sorted()), \(orphanedNotes.count) orphaned")
        notesSaveTask?.cancel()
        if isPrimary { PrepStore.shared.load(deck: deck, notesID: notesID, companionPrep: companionFile?.prep) }
        // Bring the companion file up to date if this iPad has newer notes than it (or it's missing).
        let prepUpdated = isPrimary ? PrepStore.shared.currentSaved()?.updated : nil
        let insertsUpdated = notesID.flatMap(Inserts.updated)
        let localNewest = max(notesUpdated ?? .distantPast, prepUpdated ?? .distantPast, insertsUpdated ?? .distantPast)
        if localNewest > (companionFile?.updated ?? .distantPast), localNewest > .distantPast {
            scheduleCompanionWrite()
        }
        inkRevision += 1
        liveStroke = nil
        whiteboardShown = false
        pointer.reset()
        resetZoom()
    }

    func close() {
        saveNotesNow()
        companionWriteTask?.cancel()
        writeCompanionNow()
        notesID = nil
        companion = nil
        orphanedNotes = []
        stopSeeking()
        whiteboardShown = false
        deck = nil
        drawings = [:]
        liveStroke = nil
        pointer.reset()
    }

    // MARK: Inserted pages

    /// The page on screen, if it was added in Podium rather than coming from the PDF.
    var currentInsert: InsertedPage? { deck?.insertedPages[pageIndex] }

    /// Adds a blank page (same size and background as this one) after the current slide.
    func insertBlankPage() {
        guard let deck else { return }
        // Copy the nearest page of the PDF itself, so a blank page after a photo still looks like the slides.
        let fromPDF = (0..<deck.pageCount).filter { deck.insertedPages[$0] == nil }
        let model = fromPDF.last(where: { $0 <= pageIndex }) ?? fromPDF.first ?? pageIndex
        let size = deck.pageSize(model)
        var record = newInsert(kind: .blank)
        record.width = size.width
        record.height = size.height
        record.background = deck.backgroundColor(page: model).hexString
        addInsert(record, photo: nil)
    }

    /// Adds a photo as a page after the current slide.
    func insertPhoto(_ image: UIImage) {
        addInsert(newInsert(kind: .photo), photo: image)
    }

    private func newInsert(kind: InsertedPage.Kind) -> InsertedPage {
        let slide = deck.map { $0.slideIndex(ofPage: pageIndex) } ?? -1
        return InsertedPage(kind: kind, afterFingerprint: deck?.fingerprints[slide], afterSlide: slide, width: 0, height: 0)
    }

    private func addInsert(_ record: InsertedPage, photo: UIImage?) {
        guard let notesID else { return }
        if let photo, !Inserts.savePhoto(photo, pageID: record.id, id: notesID) { return }
        Inserts.save(Inserts.records(notesID) + [record], id: notesID)
        companionInserts = nil
        rebuildDeck()
        if let page = deck?.insertedPages.first(where: { $0.value.id == record.id })?.key { go(toPage: page) }
    }

    /// Removes the inserted page on screen, and the ink on it.
    func removeCurrentInsert() {
        guard let notesID, let insert = currentInsert else { return }
        let page = pageIndex
        // The page's own ink, under either key (whichever "keep ink across steps" was set to).
        drawings["s\(deck?.slideIndex(ofPage: page) ?? -1)"] = nil
        drawings["p\(page)"] = nil
        // Pages that were added after this one move up to its place.
        let key = "inserted-\(insert.id.uuidString)"
        let remaining = Inserts.records(notesID).filter { $0.id != insert.id }.map { record -> InsertedPage in
            guard record.afterFingerprint == key else { return record }
            var moved = record
            moved.afterFingerprint = insert.afterFingerprint
            moved.afterSlide = insert.afterSlide
            return moved
        }
        Inserts.save(remaining, id: notesID)
        Inserts.deletePhoto(pageID: insert.id, id: notesID)
        companionInserts = nil
        rebuildDeck()
        go(toPage: max(0, page - 1))
    }

    /// Rebuilds the deck from the original PDF plus the current inserts. Notes are saved first and
    /// reloaded by slide text, so ink and prep notes stay on their slides as pages shift.
    private func rebuildDeck() {
        guard let deck, let notesID else { return }
        saveNotesNow()
        guard let rebuilt = Deck(data: deck.sourceData, title: deck.title, inserts: Inserts.load(notesID), isReader: deck.isReader) else { return }
        let keep = (margins, scrollMode, companionPrep)
        if isPrimary { AssistantStore.shared.resetAll() }
        open(rebuilt, notesID: notesID, companion: companion, companionFile: nil)
        (margins, scrollMode, companionPrep) = keep
        scheduleCompanionWrite()
    }

    // MARK: Navigation

    func next() {
        guard let deck, pageIndex < deck.pageCount - 1 else { return }
        go(toPage: pageIndex + 1)
    }

    func previous() {
        guard pageIndex > 0 else { return }
        go(toPage: pageIndex - 1)
    }

    /// In scroll mode: the page being read or written on becomes the current one (the projector shows it).
    func setCurrentPage(_ page: Int) {
        guard let deck, (0..<deck.pageCount).contains(page), page != pageIndex else { return }
        pageIndex = page
    }

    /// Pages left by following links, so a "back" link returns there.
    private(set) var linkHistory: [Int] = []
    /// Per ink key, bumped on each change, so every view showing that ink stays in step.
    var keyRevisions: [String: Int] = [:]

    /// Follows a link in the PDF to another page, remembering where it came from.
    func follow(linkTo page: Int) {
        guard page != pageIndex else { return }
        linkHistory.append(pageIndex)
        if linkHistory.count > 50 { linkHistory.removeFirst() }
        go(toPage: page)
    }

    /// The back chip's ×: forget where links came from.
    func clearLinkHistory() { linkHistory = [] }

    /// Beamer's "back" link (or the back chip): returns to the page a link was followed from.
    func goBackFromLink() -> Bool {
        guard let page = linkHistory.popLast() else { return false }
        go(toPage: page)
        return true
    }

    func go(toPage page: Int) {
        guard let deck, (0..<deck.pageCount).contains(page) else { return }
        pageIndex = page
        jumpRequest += 1
        // Turning the page lifts the whiteboard; its ink stays for next time.
        if whiteboardShown { whiteboardShown = false }
        liveStroke = nil
        pointer.reset()
    }

    /// First step of the next slide, skipping the rest of this slide's overlays.
    func nextSlide() {
        guard let deck else { return }
        let slide = deck.slideIndex(ofPage: pageIndex)
        guard slide + 1 < deck.slides.count else { return }
        go(toPage: deck.slides[slide + 1].pages.lowerBound)
    }

    /// First step of the previous slide.
    func previousSlide() {
        guard let deck else { return }
        let slide = deck.slideIndex(ofPage: pageIndex)
        guard slide > 0 else { return }
        go(toPage: deck.slides[slide - 1].pages.lowerBound)
    }

    /// Jumps one slide now, then keeps jumping while held, speeding up from ~3 to ~8 per second.
    func startSeeking(forward: Bool) {
        stopSeeking()
        isSeeking = true
        seekTask = Task { @MainActor [weak self] in
            var interval = 0.33
            while let self, !Task.isCancelled {
                forward ? self.nextSlide() : self.previousSlide()
                try? await Task.sleep(for: .seconds(interval))
                interval = max(0.125, interval * 0.88)
            }
        }
    }

    func stopSeeking() {
        seekTask?.cancel()
        seekTask = nil
        isSeeking = false
    }

    var slidePosition: (slide: Int, slideCount: Int, step: Int, stepCount: Int)? {
        guard let deck else { return nil }
        let slide = deck.slide(ofPage: pageIndex)
        return (slide.id + 1, deck.slides.count, pageIndex - slide.pages.lowerBound + 1, slide.pages.count)
    }

    // MARK: Zoom

    /// Pinch: scales by `factor` keeping the page point `anchor` (0...1) under the fingers.
    func zoom(by factor: CGFloat, around anchor: CGPoint) {
        // Scrolling pages can also shrink (more pages on screen); the single page stops at its fitted size.
        if scrollMode {
            zoom = min(max(zoom * factor, Self.minScrollZoom), Self.maxZoom)
            return
        }
        let newZoom = min(max(zoom * factor, 1), Self.maxZoom)
        let applied = newZoom / zoom
        if newZoom <= 1.001 {
            resetZoom()
            return
        }
        zoom = newZoom
        moveZoomFocus(to: CGPoint(x: anchor.x - (anchor.x - zoomFocus.x) / applied,
                                  y: anchor.y - (anchor.y - zoomFocus.y) / applied))
    }

    /// Two-finger pan, in fractions of the page.
    func panZoom(by delta: CGSize) {
        guard zoom > 1 else { return }
        moveZoomFocus(to: CGPoint(x: zoomFocus.x - delta.width, y: zoomFocus.y - delta.height))
    }

    private func moveZoomFocus(to point: CGPoint) {
        let half = 0.5 / zoom
        zoomFocus = CGPoint(x: min(max(point.x, half), 1 - half), y: min(max(point.y, half), 1 - half))
    }

    func commitZoom() {
        renderZoom = zoom
    }

    func resetZoom() {
        zoom = 1
        renderZoom = 1
        zoomFocus = CGPoint(x: 0.5, y: 0.5)
    }

    // MARK: Ink

    /// Ink belongs to the slide by default, so it carries across overlay steps.
    var inkKey: String {
        if whiteboardShown { return PresentationState.boardKey }
        return inkKey(forPage: pageIndex)
    }

    func inkKey(forPage page: Int) -> String {
        guard let deck, (0..<deck.pageCount).contains(page) else { return "" }
        return PresentationState.shared.inkFollowsSlide ? "s\(deck.slideIndex(ofPage: page))" : "p\(page)"
    }

    func clearInk() {
        drawings[inkKey] = nil
        inkRevision += 1
    }

    /// Clears every slide's ink, saved notes included; the whiteboard keeps its own.
    func clearAllInk() {
        orphanedNotes = []
        drawings = drawings.filter { $0.key == PresentationState.boardKey }
        inkRevision += 1
        saveNotesNow()
    }

    func undo() {
        activeCanvas?.undoManager?.undo()
    }

    /// `widthFraction` is the width the canvas actually draws with, after clamping to the ink's valid range.
    func beginLiveStroke(at points: [CGPoint], widthFraction: CGFloat) {
        let state = PresentationState.shared
        nextLiveStrokeID += 1
        liveStroke = LiveStroke(id: nextLiveStrokeID, points: points, color: state.currentColor,
                                widthFraction: widthFraction, isMarker: state.tool == .highlighter)
    }

    // MARK: Saved notes

    @ObservationIgnored private var notesID: String?
    /// The PDF's notes id, which also names its tab.
    var fileID: String? { notesID }
    @ObservationIgnored private var orphanedNotes: [SavedNotes.Record] = []
    @ObservationIgnored private var notesSaveTask: Task<Void, Never>?
    @ObservationIgnored private var companionWriteTask: Task<Void, Never>?
    @ObservationIgnored private var notesDirty = false
    @ObservationIgnored private var notesUpdated: Date?
    /// A side document's companion file may hold prep notes from when it was the main deck; keep them.
    @ObservationIgnored private var companionPrep: SavedPrep?
    /// The inserted pages (with their photos) as written to the companion file; rebuilt after a change.
    @ObservationIgnored private var companionInserts: SavedInserts?

    /// Saves a second after the last change, so writing doesn't hit the disk on every stroke.
    private func scheduleNotesSave() {
        guard notesID != nil else { return }
        notesSaveTask?.cancel()
        notesSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNotes(waiting: false)
        }
    }

    /// Saves now and waits until it's on disk (closing, switching tabs, rebuilding after an insert).
    func saveNotesNow() {
        saveNotes(waiting: true)
    }

    /// Turning ink into data and writing it takes long enough on a full deck to make the Pencil stutter,
    /// so it runs on a background queue; the queue keeps saves in order.
    private func saveNotes(waiting: Bool) {
        notesSaveTask?.cancel()
        notesSaveTask = nil
        guard notesDirty, let snapshot = notesSnapshot(touch: true), let notesID else {
            // Nothing new, but a save may still be on its way to disk: wait for it before anyone reads the file.
            if waiting { Self.saveQueue.sync {} }
            return
        }
        notesDirty = false
        let work: @Sendable () -> Void = { Notes.save(snapshot.notes(), id: notesID) }
        if waiting { Self.saveQueue.sync(execute: work) } else { Self.saveQueue.async(execute: work) }
        scheduleCompanionWrite()
    }

    nonisolated static let saveQueue = DispatchQueue(label: "podium.notes-save", qos: .utility)

    /// The ink as it is now, to be turned into saved records off the main thread.
    private func notesSnapshot(touch: Bool) -> NotesSnapshot? {
        guard let deck else { return nil }
        if touch { notesUpdated = .now }
        return NotesSnapshot(drawings: drawings, orphans: orphanedNotes, deck: deck, updated: notesUpdated)
    }

    // MARK: Companion file

    /// Writes the companion file a couple of seconds after the last change (ink or prep notes).
    func scheduleCompanionWrite() {
        guard PresentationState.shared.companionEnabled, companion != nil else { return }
        companionWriteTask?.cancel()
        companionWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.writeCompanionNow()
        }
    }

    /// Writes the companion file now, if one is pending (going to the background, closing).
    func flushCompanion() {
        guard companionWriteTask != nil else { return }
        companionWriteTask?.cancel()
        writeCompanionNow()
    }

    private func writeCompanionNow() {
        companionWriteTask = nil
        guard PresentationState.shared.companionEnabled, let companion, let deck,
              let snapshot = notesSnapshot(touch: false) else { return }
        let prep = isPrimary ? PrepStore.shared.currentSaved() : companionPrep
        let cached = companionInserts
        let notesID = notesID
        let title = deck.title
        // Reading inserted photos and encoding everything happens off the main thread, in order with the saves.
        Self.saveQueue.async { [weak self] in
            let inserts = cached ?? notesID.flatMap(Inserts.saved)
            if cached == nil, let inserts {
                // Only while the same PDF is still open here.
                DispatchQueue.main.async { if let self, self.fileID == notesID { self.companionInserts = inserts } }
            }
            Companion.write(CompanionFile(updated: .now, title: title, ink: snapshot.notes(), prep: prep, inserts: inserts),
                            to: companion)
        }
    }
}

/// Ink captured on the main thread, turned into saved records on the save queue.
struct NotesSnapshot: @unchecked Sendable {
    let drawings: [String: PKDrawing]
    let orphans: [SavedNotes.Record]
    let deck: Deck
    let updated: Date?

    func notes() -> SavedNotes {
        SavedNotes(title: deck.title, records: Notes.records(from: drawings, deck: deck) + orphans, updated: updated)
    }
}
