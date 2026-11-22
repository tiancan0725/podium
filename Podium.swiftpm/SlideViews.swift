import SwiftUI
import PencilKit

struct PageImage: View {
    let deck: Deck
    let page: Int
    let width: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // Zoomed pages are rendered at most ~4000 px wide, then scaled.
        if let image = deck.image(page: page, width: min(width, 4096 / displayScale), scale: displayScale) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Color.white
        }
    }
}

/// The presenter's slide: page, ink canvas and pointer, fitted to the available space.
struct SlideStage: View {
    let deck: Deck
    /// The document shown here: the deck, or the PDF beside it.
    let doc: DocumentState

    var body: some View {
        let state = PresentationState.shared
        GeometryReader { geo in
            let pageSize = deck.pageSize(doc.pageIndex)
            let sheet = Sheet(page: pageSize, margins: doc.margins)
            let fit = fitted(sheet.size, in: geo.size)
            let layout = ZoomLayout(fit: fit, container: geo.size, zoom: doc.zoom, focus: doc.zoomFocus)
            ZStack {
                if sheet.hasMargins {
                    MarginPaper(pageShare: sheet.pageShare, color: deck.backgroundColor(page: doc.pageIndex),
                                tint: state.pageTint.color)
                }
                ZStack {
                    PageImage(deck: deck, page: doc.pageIndex, width: fit.width * sheet.pageShare * doc.renderZoom)
                    if let tint = state.pageTint.color {
                        tint.blendMode(.multiply).allowsHitTesting(false)
                    }
                }
                .pageInSheet(width: layout.size.width * sheet.pageShare)
                if doc.whiteboardShown {
                    BoardSurface(dark: state.boardIsDark)
                        .transition(.move(edge: .top))
                }
                SlideInputView(doc: doc,
                               pageSize: sheet.size,
                               inkOffset: sheet.leftMargin,
                               zoom: doc.zoom,
                               visibleRect: layout.visibleRect(in: geo.size),
                               inkKey: doc.inkKey,
                               inkRevision: doc.inkRevision,
                               tool: state.tool,
                               inkColor: state.currentColor,
                               widthFraction: state.widthFraction,
                               penStyle: state.penStyle,
                               fingerDraws: state.fingerDraws,
                               navigationEnabled: !doc.whiteboardShown,
                               eraserWidth: state.eraserWidth,
                               eraserPartial: state.eraserPartial)
                PointerLayer(doc: doc)
                if doc.whiteboardShown {
                    BoardHandle(doc: doc, dark: state.boardIsDark)
                        .transition(.move(edge: .top))
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)
            .clipped()
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .position(layout.center)
            .task(id: doc.pageIndex) {
                // Render the next step ahead of time so advancing is instant.
                if doc.pageIndex + 1 < deck.pageCount {
                    _ = deck.image(page: doc.pageIndex + 1, width: fit.width, scale: UITraitCollection.current.displayScale)
                }
            }
        }
        .clipped()
        .overlay(alignment: .top) {
            if doc.isSeeking, let position = doc.slidePosition {
                Label("Slide \(position.slide) of \(position.slideCount)", systemImage: "forward.fill")
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 16)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if doc.zoom > 1 {
                Button {
                    withAnimation(.snappy) { doc.resetZoom() }
                } label: {
                    Label(String(format: "%.1f×", doc.zoom), systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.callout.monospacedDigit())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(12)
                .help("Back to the whole page")
            }
        }
    }
}

/// Where the page sits when zoomed: its size, and its centre inside the view. The focus point
/// stays at the middle of the view except near the page's edges, which never come inside the view.
struct ZoomLayout {
    let size: CGSize
    let center: CGPoint

    init(fit: CGSize, container: CGSize, zoom: CGFloat, focus: CGPoint) {
        size = CGSize(width: fit.width * zoom, height: fit.height * zoom)
        func axis(_ length: CGFloat, _ box: CGFloat, _ focus: CGFloat) -> CGFloat {
            guard length > box else { return box / 2 }
            let half = box / 2 / length
            return box / 2 + (0.5 - min(max(focus, half), 1 - half)) * length
        }
        center = CGPoint(x: axis(size.width, container.width, focus.x),
                         y: axis(size.height, container.height, focus.y))
    }

    /// The on-screen part of the page, in the page's own coordinates.
    func visibleRect(in container: CGSize) -> CGRect {
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        return CGRect(origin: .zero, size: size)
            .intersection(CGRect(x: -origin.x, y: -origin.y, width: container.width, height: container.height))
    }
}

/// A page plus, optionally, blank margins on both sides for notes. Ink is stored in page coordinates
/// (so it lines up with or without margins); the sheet is what's laid out on screen and the projector.
struct Sheet {
    /// The margin to the right of the page, as a share of the page's width.
    static let marginFraction: CGFloat = 1

    let page: CGSize
    /// Where the page starts in the sheet (no left margin for now), in page points.
    let leftMargin: CGFloat = 0
    let rightMargin: CGFloat

    init(page: CGSize, margins: Bool) {
        self.page = page
        rightMargin = margins ? page.width * Self.marginFraction : 0
    }

    var hasMargins: Bool { rightMargin > 0 }
    var size: CGSize { CGSize(width: page.width + leftMargin + rightMargin, height: page.height) }
    /// The page's share of the sheet's width.
    var pageShare: CGFloat { size.width > 0 ? page.width / size.width : 1 }
}

/// The blank paper beside a page when margins are on: the PDF's own background colour (and the
/// iPad's page tint), with a faint line at the page's edge.
struct MarginPaper: View {
    let pageShare: CGFloat
    let color: UIColor
    var tint: Color? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color(uiColor: color)
                if let tint { tint.blendMode(.multiply) }
                Rectangle()
                    .fill(Color.black.opacity(0.12))
                    .frame(width: 1)
                    .offset(x: geo.size.width * pageShare)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The page sitting at the left of its sheet (the margin, if any, is to its right).
extension View {
    func pageInSheet(width: CGFloat) -> some View {
        frame(width: width).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The whiteboard's blank page.
struct BoardSurface: View {
    let dark: Bool

    var body: some View {
        Rectangle()
            .fill(dark ? Color(white: 0.12) : .white)
            .allowsHitTesting(false)
    }
}

/// A grabber along the board's bottom edge: swipe up (or tap) to lift the board.
struct BoardHandle: View {
    let doc: DocumentState
    let dark: Bool

    var body: some View {
        VStack {
            Spacer()
            Capsule()
                .fill(dark ? Color.white.opacity(0.35) : Color.black.opacity(0.2))
                .frame(width: 80, height: 6)
                .frame(width: 160, height: 30)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 10).onEnded { value in
                    if value.translation.height < -30 { liftBoard() }
                })
                .onTapGesture { liftBoard() }
        }
    }

    private func liftBoard() {
        withAnimation(.snappy) { doc.whiteboardShown = false }
    }
}

/// The current slide's ink as an image, for screens that only display (the audience).
/// Rendering a slide full of ink at projector resolution takes a while, so it's done off the main
/// thread: otherwise the Pencil would stall right after each stroke while the projector catches up.
struct InkImage: View {
    let doc: DocumentState
    let sheet: Sheet
    let width: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var rendered: (key: String, image: UIImage)?

    var body: some View {
        let drawing = doc.drawings[doc.inkKey]
        let key = renderKey(drawing)
        ZStack {
            // An image of another slide's ink is never shown, even for a moment.
            if drawing != nil, let rendered, rendered.key.hasPrefix(doc.inkKey + "|") {
                Image(uiImage: rendered.image)
                    .resizable()
                    .allowsHitTesting(false)
            }
        }
        .task(id: key) {
            guard let drawing, sheet.size.width > 0 else { return }
            let scale = width / sheet.size.width * displayScale
            let rect = CGRect(origin: CGPoint(x: -sheet.leftMargin, y: 0), size: sheet.size)
            let image = await Task.detached(priority: .userInitiated) {
                InkImage.render(drawing, rect: rect, scale: scale)
            }.value
            guard !Task.isCancelled else { return }
            rendered = (key, image)
            // The projector's quick copy of the last stroke can go now that the real ink is up.
            if doc.liveStroke?.ended == true { doc.liveStroke = nil }
        }
    }

    /// Changes whenever the ink does (a stroke added, erased or moved) or the size does.
    private func renderKey(_ drawing: PKDrawing?) -> String {
        guard let drawing else { return doc.inkKey + "|none" }
        let b = drawing.bounds
        return "\(doc.inkKey)|\(drawing.strokes.count)|\(b.minX),\(b.minY),\(b.width),\(b.height)|\(width)|\(sheet.size.width)|\(sheet.leftMargin)"
    }

    nonisolated private static func render(_ drawing: PKDrawing, rect: CGRect, scale: CGFloat) -> UIImage {
        var image = UIImage()
        // Render in light mode so PencilKit doesn't invert the colours.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            // The sheet in page coordinates: margins sit at negative x and past the page's width.
            image = drawing.image(from: rect, scale: scale)
        }
        return image
    }
}

/// The stroke being written right now, drawn as a simple path until PencilKit finishes it.
struct LiveStrokeLayer: View {
    let doc: DocumentState

    var body: some View {
        let stroke = doc.liveStroke
        Canvas { context, size in
            guard let stroke, let first = stroke.points.first else { return }
            func place(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
            var path = Path()
            path.move(to: place(first))
            for p in stroke.points.dropFirst() { path.addLine(to: place(p)) }
            if stroke.points.count == 1 { path.addLine(to: place(first)) }
            let color = Color(uiColor: stroke.color).opacity(stroke.isMarker ? 0.45 : 1)
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: stroke.widthFraction * size.width * 0.85,
                                              lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

/// What the room sees on the projector: slide (or whiteboard), ink and pointer, nothing else.
struct AudienceView: View {
    var body: some View {
        let state = PresentationState.shared
        // The deck, or the PDF beside it when that side is set to be projected.
        let doc = state.projected
        ZStack {
            Color.black.ignoresSafeArea()
            if let deck = doc.deck, !state.blackout {
                GeometryReader { geo in
                    let pageSize = deck.pageSize(doc.pageIndex)
                    let sheet = Sheet(page: pageSize, margins: doc.margins)
                    let fit = fitted(sheet.size, in: geo.size)
                    // In continuous scrolling the zoom only widens the iPad's page list; project the whole page.
                    let zoom = doc.scrollMode ? 1 : doc.zoom
                    let renderZoom = doc.scrollMode ? 1 : doc.renderZoom
                    let layout = ZoomLayout(fit: fit, container: geo.size, zoom: zoom, focus: doc.zoomFocus)
                    ZStack {
                        if sheet.hasMargins {
                            MarginPaper(pageShare: sheet.pageShare, color: deck.backgroundColor(page: doc.pageIndex))
                        }
                        PageImage(deck: deck, page: doc.pageIndex, width: fit.width * sheet.pageShare * renderZoom)
                            .pageInSheet(width: layout.size.width * sheet.pageShare)
                        if doc.whiteboardShown {
                            BoardSurface(dark: state.boardIsDark)
                                .transition(.move(edge: .top))
                        }
                        InkImage(doc: doc, sheet: sheet, width: fit.width * renderZoom)
                        LiveStrokeLayer(doc: doc)
                        PointerLayer(doc: doc)
                    }
                    .frame(width: layout.size.width, height: layout.size.height)
                    .clipped()
                    .position(layout.center)
                }
                .clipped()
            }
        }
        .animation(.snappy, value: doc.whiteboardShown)
        .ignoresSafeArea()
    }
}

/// A grid of every slide (showing its last overlay step) to jump around during questions.
struct OverviewSheet: View {
    let deck: Deck
    @Environment(\.dismiss) private var dismiss
    /// Thumbnail width; pinch to change it.
    @AppStorage("overview.thumbWidth") private var thumbWidth = 220.0
    @State private var pinchStart: Double?
    static let thumbRange = 140.0...600.0

    var body: some View {
        let state = PresentationState.shared
        let current = deck.slideIndex(ofPage: state.pageIndex)
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbWidth), spacing: 20)], spacing: 20) {
                        ForEach(deck.slides) { slide in
                            Button {
                                state.go(toPage: slide.pages.lowerBound)
                                dismiss()
                            } label: {
                                VStack(spacing: 6) {
                                    // Render at the size the pinch settled on, so zooming doesn't re-render every frame.
                                    PageImage(deck: deck, page: slide.pages.upperBound, width: pinchStart ?? thumbWidth)
                                        .aspectRatio(deck.pageSize(slide.pages.upperBound), contentMode: .fit)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(slide.id == current ? Color.accentColor : .clear, lineWidth: 3)
                                        }
                                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                                    Text(slide.pages.count > 1 ? "\(slide.number) · \(slide.pages.count) steps" : "\(slide.number)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .id(slide.id)
                        }
                    }
                    .padding(20)
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let start = pinchStart ?? thumbWidth
                            pinchStart = start
                            thumbWidth = min(max(start * value.magnification, Self.thumbRange.lowerBound),
                                             Self.thumbRange.upperBound)
                        }
                        .onEnded { _ in pinchStart = nil }
                )
            }
            .navigationTitle(deck.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Smaller", systemImage: "minus.magnifyingglass") { zoom(by: 0.8) }
                    Button("Larger", systemImage: "plus.magnifyingglass") { zoom(by: 1.25) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func zoom(by factor: Double) {
        withAnimation(.snappy) {
            thumbWidth = min(max(thumbWidth * factor, Self.thumbRange.lowerBound), Self.thumbRange.upperBound)
        }
    }
}
