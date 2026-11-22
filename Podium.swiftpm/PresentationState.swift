import SwiftUI
import PencilKit
import Observation

enum Tool: String, CaseIterable, Identifiable {
    case pen, highlighter, eraser, pointer
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .pointer: "smallcircle.filled.circle"
        }
    }
}

enum PointerStyle: String, CaseIterable, Identifiable {
    case dot, trail, highlight
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dot: "Dot"
        case .trail: "Trail"
        case .highlight: "Highlight"
        }
    }

    var symbol: String {
        switch self {
        case .dot: "circle.fill"
        case .trail: "scribble"
        case .highlight: "highlighter"
        }
    }
}

enum PenStyle: String, CaseIterable, Identifiable {
    case pen, monoline, fountain
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: "Pen (pressure)"
        case .monoline: "Monoline (even)"
        case .fountain: "Fountain"
        }
    }

    var inkType: PKInkingTool.InkType {
        switch self {
        case .pen: .pen
        case .monoline: .monoline
        case .fountain: .fountainPen
        }
    }
}

/// The stroke currently being written, mirrored live to the audience screen.
/// PencilKit only reports a stroke once it is finished, so without this the room
/// would see each stroke pop in after the pen lifts.
struct LiveStroke {
    var id: Int
    var points: [CGPoint]          // unit coordinates (0...1) on the page
    var color: UIColor
    var widthFraction: CGFloat     // stroke width as a fraction of page width
    var isMarker: Bool
    var ended = false
}

@MainActor @Observable
final class PresentationState {
    static let shared = PresentationState()

    // MARK: Documents

    /// The deck being presented.
    let primary = DocumentState(isPrimary: true)
    /// A second PDF shown beside the deck (a paper, notes, another deck), if any.
    private(set) var secondary: DocumentState?
    /// Which side the tool bar, keyboard and Pencil clicker act on: the one last touched.
    var activeIsSecondary = false
    /// Put the side document on the projector instead of the deck.
    var projectSecondary = false

    var active: DocumentState { activeIsSecondary ? (secondary ?? primary) : primary }

    /// Open PDFs, shown as tabs. The main pane shows the current tab; another tab can sit beside it.
    private(set) var tabs: [OpenTab] = []
    private(set) var currentTabID: String?
    /// The tab shown in the side pane, if any.
    var besideTabID: String? { secondary?.fileID }

    // Split layout: side by side or stacked, which document comes first, and the first one's share.
    var splitVertical = UserDefaults.standard.bool(forKey: "split.vertical") {
        didSet { UserDefaults.standard.set(splitVertical, forKey: "split.vertical") }
    }
    var primaryFirst = UserDefaults.standard.object(forKey: "split.primaryFirst") as? Bool ?? true {
        didSet { UserDefaults.standard.set(primaryFirst, forKey: "split.primaryFirst") }
    }
    /// The first pane's share of the space (0.2...0.8).
    var splitFraction: CGFloat = UserDefaults.standard.object(forKey: "split.fraction") as? CGFloat ?? 0.5 {
        didSet { UserDefaults.standard.set(Double(splitFraction), forKey: "split.fraction") }
    }

    enum Edge { case leading, trailing, top, bottom }

    /// Drop a document's pane on an edge: it goes there and the other one takes the opposite side.
    func place(_ doc: DocumentState, at edge: Edge) {
        let first = edge == .leading || edge == .top
        splitVertical = edge == .top || edge == .bottom
        primaryFirst = (doc === primary) == first
    }
    var projected: DocumentState { projectSecondary ? (secondary ?? primary) : primary }

    func activate(_ doc: DocumentState) {
        let isSecondary = doc !== primary
        if activeIsSecondary != isSecondary { activeIsSecondary = isSecondary }
    }

    var blackout = false
    var externalConnected = false
    nonisolated static let boardKey = "board"

    // Eraser: whole strokes or partial (area), and its size in on-screen points.
    var eraserPartial = UserDefaults.standard.bool(forKey: "eraser.partial") {
        didSet { UserDefaults.standard.set(eraserPartial, forKey: "eraser.partial") }
    }
    var eraserWidth: CGFloat = UserDefaults.standard.object(forKey: "eraser.width") as? CGFloat ?? 20 {
        didSet { UserDefaults.standard.set(Double(eraserWidth), forKey: "eraser.width") }
    }
    /// What PencilKit's fixed-width eraser accepts (about 16–80 pt).
    static let eraserWidths: ClosedRange<CGFloat> = {
        let range = PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange
        return range.upperBound > range.lowerBound ? range : 16...80
    }()

    /// Pen widths are fractions of this many screen points, so a pen draws equally thick on every page
    /// (a wide Beamer slide, a narrow portrait PDF, a Markdown page, side by side or scrolling).
    static let inkReferenceWidth: CGFloat = 1000

    /// A pen or highlighter width (a fraction of the slide) in on-screen points, as PencilKit draws it.
    func points(forWidth fraction: CGFloat) -> CGFloat {
        let range = inkType.validWidthRange
        return min(max(fraction * Self.inkReferenceWidth, range.lowerBound), range.upperBound)
    }

    // Look of the iPad screen (never the projector)
    var appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .dark {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }
    var pageTint = PageTint(rawValue: UserDefaults.standard.string(forKey: "pageTint") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(pageTint.rawValue, forKey: "pageTint") }
    }

    // Timer: hidden unless turned on, and only runs once started.
    var timerShown = UserDefaults.standard.bool(forKey: "timer.shown") {
        didSet { UserDefaults.standard.set(timerShown, forKey: "timer.shown") }
    }
    private(set) var timerStarted: Date?
    private(set) var timerElapsed: TimeInterval = 0

    /// Pencil double-tap turns the page while the pointer tool is active (squeeze goes back).
    var pencilTapAdvances = UserDefaults.standard.object(forKey: "pencil.tapAdvances") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pencilTapAdvances, forKey: "pencil.tapAdvances") }
    }

    /// Also keep each PDF's notes in a ".podium" file next to it (linked folders only).
    var companionEnabled = Companion.enabled {
        didSet {
            UserDefaults.standard.set(companionEnabled, forKey: Companion.defaultsKey)
            if companionEnabled { scheduleCompanionWrite() }
        }
    }
    // Tools
    var tool: Tool = .pen {
        didSet {
            if oldValue != tool { previousTool = oldValue }
            if tool == .pen || tool == .highlighter { lastInkTool = tool }
        }
    }
    @ObservationIgnored private(set) var previousTool: Tool = .pen
    @ObservationIgnored private(set) var lastInkTool: Tool = .pen
    /// Bumped when the Pencil asks for the colour palette; the toolbar shows it.
    var colorPaletteRequest = 0
    // The pen style, colours and stroke size you last used come back next time (monoline by default).
    var pointerStyle: PointerStyle = PointerStyle(rawValue: UserDefaults.standard.string(forKey: "last.pointerStyle") ?? "") ?? .trail {
        didSet { UserDefaults.standard.set(pointerStyle.rawValue, forKey: "last.pointerStyle") }
    }
    var penStyle: PenStyle = PenStyle(rawValue: UserDefaults.standard.string(forKey: "last.penStyle") ?? "") ?? .monoline {
        didSet { UserDefaults.standard.set(penStyle.rawValue, forKey: "last.penStyle") }
    }
    var inkIndex = UserDefaults.standard.integer(forKey: "last.inkIndex") {
        didSet { UserDefaults.standard.set(inkIndex, forKey: "last.inkIndex") }
    }
    var highlighterIndex = UserDefaults.standard.integer(forKey: "last.highlighterIndex") {
        didSet { UserDefaults.standard.set(highlighterIndex, forKey: "last.highlighterIndex") }
    }
    var pointerIndex = UserDefaults.standard.integer(forKey: "last.pointerIndex") {
        didSet { UserDefaults.standard.set(pointerIndex, forKey: "last.pointerIndex") }
    }
    var widthIndex = UserDefaults.standard.object(forKey: "last.widthIndex") as? Int ?? 1 {
        didSet { UserDefaults.standard.set(widthIndex, forKey: "last.widthIndex") }
    }

    // Colours the user added, per tool, after the palette's own.
    var customInks: [UIColor] = PresentationState.loadColors("custom.inks") {
        didSet { Self.saveColors(customInks, "custom.inks") }
    }
    var customHighlighters: [UIColor] = PresentationState.loadColors("custom.highlighters") {
        didSet { Self.saveColors(customHighlighters, "custom.highlighters") }
    }
    var customPointers: [UIColor] = PresentationState.loadColors("custom.pointers") {
        didSet { Self.saveColors(customPointers, "custom.pointers") }
    }

    // Settings
    var inkFollowsSlide = true
    var fingerDraws = false
    var showNextPreview = true

    // Palettes
    var paletteID: String
    var slidePalette: Palette?

    private init() {
        paletteID = UserDefaults.standard.string(forKey: "paletteID") ?? Palette.builtIn[0].id
        // The Podium palette became the default (11-22); move people off the old default once.
        if !UserDefaults.standard.bool(forKey: "palette.podiumDefault") {
            UserDefaults.standard.set(true, forKey: "palette.podiumDefault")
            if paletteID == "chalk" {
                paletteID = "podium"
                UserDefaults.standard.set("podium", forKey: "paletteID")
            }
        }
    }

    // MARK: Opening and closing

    /// Opens the deck to present (see `DocumentState.open`). Tabs remembered from last time come back
    /// beside it (loaded when you switch to them); if this PDF was one of them, it reopens where you left it.
    func open(_ deck: Deck, notesID: String?, companion: CompanionTarget? = nil, companionFile: CompanionFile? = nil,
              source: TabSource? = nil) {
        closeSecondary()
        let id = notesID ?? UUID().uuidString
        tabs = SavedTabs.load()
        // The same file remembered under an older id (its path changed, e.g. after reinstalling): drop that tab.
        if let here = source?.resolve()?.url.standardizedFileURL {
            tabs.removeAll { $0.id != id && $0.source?.resolve()?.url.standardizedFileURL == here }
        }
        let tab = tabs.first { $0.id == id } ?? {
            let tab = OpenTab(id: id, companion: companion, deck: deck, source: source)
            tabs.append(tab)
            return tab
        }()
        tab.deck = deck
        if let source { tab.source = source }
        currentTabID = id
        primary.open(deck, notesID: notesID, companion: companion, companionFile: companionFile)
        tab.restore(into: primary)
        activeIsSecondary = false
        blackout = false
        resetTimer()
        slidePalette = SlideTheme.palette(for: deck)
        saveTabs()
    }

    /// Opens a second PDF beside the deck; it becomes the active side (and gets a tab if it hasn't one).
    func openSecondary(_ deck: Deck, notesID: String?, companion: CompanionTarget?, companionFile: CompanionFile?,
                       source: TabSource? = nil) {
        let id = notesID ?? UUID().uuidString
        if id == currentTabID { return }
        stashSecondary()
        secondary?.close()
        let tab = tabs.first { $0.id == id } ?? {
            let tab = OpenTab(id: id, companion: companion, deck: deck, source: source)
            tabs.append(tab)
            return tab
        }()
        tab.deck = deck
        let doc = DocumentState(isPrimary: false)
        doc.open(deck, notesID: id, companion: tab.companion, companionFile: companionFile)
        tab.restore(into: doc)
        secondary = doc
        activeIsSecondary = true
        saveTabs()
    }

    func closeSecondary() {
        stashSecondary()
        secondary?.close()
        secondary = nil
        activeIsSecondary = false
        projectSecondary = false
    }

    // MARK: Tabs

    var currentTab: OpenTab? { tabs.first { $0.id == currentTabID } }
    /// The tab being loaded after a tap, if its PDF wasn't loaded yet.
    private(set) var loadingTabID: String?

    /// Opens a PDF in a new tab (or switches to it if it's already open).
    func openTab(_ deck: Deck, notesID: String, companion: CompanionTarget?, companionFile: CompanionFile?,
                 source: TabSource? = nil) {
        if let existing = tabs.first(where: { $0.id == notesID }) {
            existing.deck = deck
            select(existing, companionFile: companionFile)
            return
        }
        let tab = OpenTab(id: notesID, companion: companion, deck: deck, source: source)
        tabs.append(tab)
        show(tab, companionFile: companionFile)
    }

    /// Tapping a tab: show it in the main pane, or, if it's already beside, make that side active.
    func select(_ tab: OpenTab, companionFile: CompanionFile? = nil) {
        if tab.id == besideTabID, let secondary {
            activate(secondary)
        } else if tab.id != currentTabID {
            show(tab, companionFile: companionFile)
        } else {
            activate(primary)
        }
    }

    /// Dragging a tab onto another tab: it takes that tab's place.
    func moveTab(_ id: String, to target: OpenTab) {
        guard let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target.id }), from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        saveTabs()
    }

    /// Dragging a tab onto the page: show it beside the current one.
    func showBeside(_ tab: OpenTab) {
        guard tab.id != currentTabID else { return }
        withLoaded(tab) { [weak self] deck, file in
            self?.openSecondary(deck, notesID: tab.id, companion: tab.companion, companionFile: file)
        }
    }

    /// Closes a tab. Returns false when it was the last one (the presenter then closes).
    func closeTab(_ tab: OpenTab) -> Bool {
        if tab.id == besideTabID { closeSecondary() }
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return true }
        let wasCurrent = tab.id == currentTabID
        if wasCurrent { stashCurrent() }
        tabs.remove(at: index)
        saveTabs()
        guard !tabs.isEmpty else { return false }
        if wasCurrent {
            let next = tabs[min(index, tabs.count - 1)]
            if next.id == besideTabID { closeSecondary() }
            show(next, companionFile: nil, stash: false)
        }
        return true
    }

    /// Puts a tab in the main pane, keeping the side pane as it is.
    private func show(_ tab: OpenTab, companionFile: CompanionFile?, stash: Bool = true) {
        withLoaded(tab) { [weak self] deck, loadedFile in
            guard let self else { return }
            if stash { stashCurrent() }
            closePrimary()
            primary.open(deck, notesID: tab.id, companion: tab.companion, companionFile: companionFile ?? loadedFile)
            tab.restore(into: primary)
            currentTabID = tab.id
            activeIsSecondary = false
            slidePalette = SlideTheme.palette(for: deck)
            saveTabs()
        }
    }

    /// Runs `body` with the tab's deck, reading the PDF first if this tab was remembered from last time.
    /// A PDF that can't be found any more loses its tab.
    /// The companion file read along the way (if any) goes to `body` too, so newer notes from another iPad are used.
    /// The last tab asked for wins: a slower load finishing later is dropped.
    private func withLoaded(_ tab: OpenTab, _ body: @escaping (Deck, CompanionFile?) -> Void) {
        if let deck = tab.deck {
            loadingTabID = nil
            body(deck, nil)
            return
        }
        guard let source = tab.source, let location = source.resolve() else {
            dropTab(tab)
            return
        }
        loadingTabID = tab.id
        Task { @MainActor in
            let loaded = await LibraryStore.loadDeck(at: location.url, scope: location.scope, title: source.title,
                                                     companion: tab.companion)
            guard let deck = loaded?.deck else {
                if loadingTabID == tab.id { loadingTabID = nil }
                dropTab(tab)
                return
            }
            tab.deck = deck
            guard loadingTabID == tab.id, tabs.contains(where: { $0.id == tab.id }) else { return }
            loadingTabID = nil
            body(deck, loaded?.companion)
        }
    }

    private func dropTab(_ tab: OpenTab) {
        tabs.removeAll { $0.id == tab.id }
        saveTabs()
    }

    /// Remembers where the main pane's tab was (page, scrolling, margins, inserted pages).
    private func stashCurrent() {
        currentTab?.stash(from: primary)
    }

    private func stashSecondary() {
        guard let secondary, let tab = tabs.first(where: { $0.id == secondary.fileID }) else { return }
        tab.stash(from: secondary)
    }

    /// Writes the open tabs (and where each one was) so they come back next time.
    func saveTabs() {
        guard !tabs.isEmpty else {
            SavedTabs.save([])
            return
        }
        stashCurrent()
        stashSecondary()
        SavedTabs.save(tabs)
    }

    func close() {
        saveTabs()
        closeSecondary()
        tabs = []
        currentTabID = nil
        closePrimary()
        slidePalette = nil
    }

    /// Saves and closes the main pane's PDF; the Claude chat and prep notes belong to it, so they go too.
    private func closePrimary() {
        primary.close()
        AssistantStore.shared.resetAll()
        PrepStore.shared.unload()
    }

    func saveNotesNow() {
        primary.saveNotesNow()
        secondary?.saveNotesNow()
        // Going to the background: don't leave the companion file waiting on its 2-second timer.
        primary.flushCompanion()
        secondary?.flushCompanion()
        if !tabs.isEmpty { saveTabs() }
    }

    func scheduleCompanionWrite() {
        primary.scheduleCompanionWrite()
        secondary?.scheduleCompanionWrite()
    }

    // MARK: The active side
    // The tool bar, keyboard shortcuts and Pencil clicker act on whichever side was last touched.

    var deck: Deck? { active.deck }
    var pageIndex: Int { active.pageIndex }
    var drawings: [String: PKDrawing] { active.drawings }
    var whiteboardShown: Bool {
        get { active.whiteboardShown }
        set { active.whiteboardShown = newValue }
    }
    var slidePosition: (slide: Int, slideCount: Int, step: Int, stepCount: Int)? { active.slidePosition }

    func next() { active.next() }
    func previous() { active.previous() }
    func go(toPage page: Int) { active.go(toPage: page) }
    func nextSlide() { active.nextSlide() }
    func previousSlide() { active.previousSlide() }
    func startSeeking(forward: Bool) { active.startSeeking(forward: forward) }
    func stopSeeking() { active.stopSeeking() }
    func zoom(by factor: CGFloat, around anchor: CGPoint) { active.zoom(by: factor, around: anchor) }
    func commitZoom() { active.commitZoom() }
    func clearInk() { active.clearInk() }
    func clearAllInk() { active.clearAllInk() }
    func undo() { active.undo() }

    // MARK: Timer

    var timerRunning: Bool { timerStarted != nil }

    func startTimer() {
        if timerStarted == nil { timerStarted = .now }
    }

    func pauseTimer() {
        if let started = timerStarted { timerElapsed += Date.now.timeIntervalSince(started) }
        timerStarted = nil
    }

    func resetTimer() {
        timerStarted = nil
        timerElapsed = 0
    }

    /// White board, or a dark one when the palette is made for dark slides (its first ink is light).
    var boardIsDark: Bool {
        var white: CGFloat = 0
        palette.inks.first?.getWhite(&white, alpha: nil)
        return white > 0.5
    }

    // MARK: Palette and tools

    var palettes: [Palette] {
        (slidePalette.map { [$0] } ?? []) + Palette.builtIn
    }

    var palette: Palette {
        palettes.first { $0.id == paletteID } ?? Palette.builtIn[0]
    }

    func selectPalette(_ palette: Palette) {
        paletteID = palette.id
        UserDefaults.standard.set(palette.id, forKey: "paletteID")
    }

    static let pointerPresets: [UIColor] = ["#FF3B30", "#FFD60A", "#30D158", "#0A84FF", "#FF2D92", "#FFFFFF"]
        .map(UIColor.init(hex:))

    /// The palette's colours for the active tool (pointer, highlighter or ink).
    var paletteColors: [UIColor] {
        switch tool {
        case .highlighter: palette.highlighters
        case .pointer: [palette.pointer] + Self.pointerPresets
        default: palette.inks
        }
    }

    var customColors: [UIColor] {
        get {
            switch tool {
            case .highlighter: customHighlighters
            case .pointer: customPointers
            default: customInks
            }
        }
        set {
            switch tool {
            case .highlighter: customHighlighters = newValue
            case .pointer: customPointers = newValue
            default: customInks = newValue
            }
        }
    }

    var currentColors: [UIColor] { paletteColors + customColors }

    var currentColorIndex: Int {
        get {
            switch tool {
            case .highlighter: highlighterIndex
            case .pointer: pointerIndex
            default: inkIndex
            }
        }
        set {
            switch tool {
            case .highlighter: highlighterIndex = newValue
            case .pointer: pointerIndex = newValue
            default: inkIndex = newValue
            }
        }
    }

    var currentColor: UIColor {
        let colors = currentColors
        return colors[min(currentColorIndex, colors.count - 1)]
    }

    /// The highlighter's colour, whichever tool is active (for highlighting selected text).
    var highlighterColor: UIColor {
        let colors = palette.highlighters + customHighlighters
        return colors[min(highlighterIndex, colors.count - 1)]
    }

    var pointerColor: UIColor {
        let colors = [palette.pointer] + Self.pointerPresets + customPointers
        return colors[min(pointerIndex, colors.count - 1)]
    }

    /// Adds a colour from the colour picker and selects it. The picker reports every
    /// change while you drag, so a burst of changes edits the colour it just added.
    func pickColor(_ color: UIColor) {
        let now = Date()
        let offset = paletteColors.count
        if let last = lastPicked, last.tool == tool, now.timeIntervalSince(last.time) < 2,
           customColors.indices.contains(last.index), currentColorIndex == offset + last.index {
            customColors[last.index] = color
        } else {
            if customColors.count >= Self.maxCustomColors { customColors.removeFirst() }
            customColors.append(color)
        }
        let index = customColors.count - 1
        lastPicked = (tool, index, now)
        currentColorIndex = offset + index
    }

    func removeCustomColor(at index: Int) {
        guard customColors.indices.contains(index) else { return }
        let selected = currentColorIndex
        customColors.remove(at: index)
        let removed = paletteColors.count + index
        if selected == removed { currentColorIndex = 0 }
        else if selected > removed { currentColorIndex = selected - 1 }
        lastPicked = nil
    }

    static let maxCustomColors = 6
    @ObservationIgnored private var lastPicked: (tool: Tool, index: Int, time: Date)?

    private static func loadColors(_ key: String) -> [UIColor] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map(UIColor.init(hex:))
    }

    private static func saveColors(_ colors: [UIColor], _ key: String) {
        UserDefaults.standard.set(colors.map(\.hexString), forKey: key)
    }

    // MARK: Stroke widths

    /// Three width presets per pen style and for the highlighter, as fractions of the slide's width.
    /// Monoline looks heavier than the pressure pen at the same nominal width, so it starts thinner.
    static let defaultWidths: [String: [CGFloat]] = [
        PenStyle.pen.rawValue: [0.0035, 0.006, 0.010],
        PenStyle.monoline.rawValue: [0.002, 0.0035, 0.006],
        PenStyle.fountain.rawValue: [0.0035, 0.006, 0.010],
        "highlighter": [0.02, 0.035, 0.055],
    ]
    static let penWidthRange: ClosedRange<CGFloat> = 0.0008...0.016
    static let highlighterWidthRange: ClosedRange<CGFloat> = 0.01...0.07

    var widthPresets: [String: [CGFloat]] = PresentationState.loadWidths() {
        didSet { UserDefaults.standard.set(widthPresets.mapValues { $0.map(Double.init) }, forKey: "widthPresets") }
    }

    private var widthKey: String { tool == .highlighter ? "highlighter" : penStyle.rawValue }

    var widthRange: ClosedRange<CGFloat> { tool == .highlighter ? Self.highlighterWidthRange : Self.penWidthRange }

    /// The active tool's three presets.
    var currentWidths: [CGFloat] {
        widthPresets[widthKey] ?? Self.defaultWidths[widthKey] ?? Self.defaultWidths[PenStyle.pen.rawValue]!
    }

    func setWidth(_ width: CGFloat, preset index: Int) {
        var widths = currentWidths
        guard widths.indices.contains(index) else { return }
        widths[index] = min(max(width, widthRange.lowerBound), widthRange.upperBound)
        widthPresets[widthKey] = widths
    }

    func resetWidths() {
        widthPresets[widthKey] = nil
    }

    /// Stroke width as a fraction of `inkReferenceWidth`.
    var widthFraction: CGFloat { currentWidths[min(widthIndex, 2)] }

    var inkType: PKInkingTool.InkType { tool == .highlighter ? .marker : penStyle.inkType }

    private static func loadWidths() -> [String: [CGFloat]] {
        let saved = UserDefaults.standard.dictionary(forKey: "widthPresets") as? [String: [Double]] ?? [:]
        return saved.filter { $0.value.count == 3 }.mapValues { $0.map { CGFloat($0) } }
    }
}

/// An open PDF in the tab bar. Its deck stays loaded once read, so switching back is instant.
@MainActor
final class OpenTab: Identifiable {
    /// The PDF's notes id.
    let id: String
    let companion: CompanionTarget?
    /// Nil for a tab remembered from last time, until you switch to it.
    var deck: Deck?
    /// Where the PDF is, so the tab can come back after the app restarts.
    var source: TabSource?
    var title: String { deck?.title ?? source?.title ?? "PDF" }
    /// Where the PDF is ("Dropbox › Teaching › ECON720"), to tell same-named PDFs apart.
    lazy var place: String? = {
        guard let url = source?.resolve()?.url else { return nil }
        let place = LibraryStore.displayPath(of: url.deletingLastPathComponent())
        return place.isEmpty ? nil : place
    }()
    /// The last folder of `place`, shown in the tab.
    var folder: String? {
        place?.components(separatedBy: " › ").last.flatMap { $0 == "…" ? nil : $0 }
    }
    fileprivate(set) var page = 0
    fileprivate(set) var scrollMode = false
    fileprivate(set) var margins = false

    init(id: String, companion: CompanionTarget?, deck: Deck?, source: TabSource?) {
        self.id = id
        self.companion = companion
        self.deck = deck
        self.source = source
        // Markdown and text open as a scrolling reader.
        scrollMode = deck?.isReader ?? false
    }

    func stash(from doc: DocumentState) {
        if let deck = doc.deck { self.deck = deck }
        page = doc.pageIndex
        scrollMode = doc.scrollMode
        margins = doc.margins
    }

    func restore(into doc: DocumentState) {
        doc.margins = margins
        doc.scrollMode = scrollMode
        if page > 0 { doc.go(toPage: page) }
    }
}

/// Where a tab's PDF lives: a bookmark to the file, or to its linked folder plus the path inside it.
struct TabSource: Codable, Sendable {
    var scopeBookmark: Data
    var relativePath: String?
    var title: String
    var linkedFolder: Bool

    init?(url: URL, scope: URL, title: String) {
        let accessing = scope.startAccessingSecurityScopedResource()
        defer { if accessing { scope.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? scope.bookmarkData() else { return nil }
        scopeBookmark = bookmark
        let scopePath = scope.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath != scopePath, filePath.hasPrefix(scopePath + "/") {
            relativePath = String(filePath.dropFirst(scopePath.count + 1))
            linkedFolder = true
        } else {
            relativePath = nil
            linkedFolder = false
        }
        self.title = title
    }

    func resolve() -> (url: URL, scope: URL)? {
        var stale = false
        guard let scope = try? URL(resolvingBookmarkData: scopeBookmark, bookmarkDataIsStale: &stale) else { return nil }
        let url = relativePath.map { scope.appendingPathComponent($0) } ?? scope
        return (url, scope)
    }

    var companion: CompanionTarget? {
        guard linkedFolder, let location = resolve() else { return nil }
        return CompanionTarget(url: Companion.url(for: location.url), scope: location.scope)
    }
}

/// The tabs, remembered between sessions.
@MainActor
enum SavedTabs {
    private struct Record: Codable {
        var id: String
        var source: TabSource
        var page: Int
        var scrollMode: Bool
        var margins: Bool
    }
    private static let key = "tabs.open"

    static func save(_ tabs: [OpenTab]) {
        let records = tabs.compactMap { tab in
            tab.source.map { Record(id: tab.id, source: $0, page: tab.page, scrollMode: tab.scrollMode, margins: tab.margins) }
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: key)
    }

    static func load() -> [OpenTab] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return records.map { record in
            let tab = OpenTab(id: record.id, companion: record.source.companion, deck: nil, source: record.source)
            tab.page = record.page
            tab.scrollMode = record.scrollMode
            tab.margins = record.margins
            return tab
        }
    }
}
