import SwiftUI

/// The document area: one PDF, or two side by side or stacked, with a draggable divider.
/// Drag a pane's header to an edge to move it there.
struct DocumentArea: View {
    let deck: Deck
    /// The deck's own extras (the "next" preview) that sit over its page.
    let primaryOverlay: AnyView

    @State private var dragging: (doc: DocumentState, edge: PresentationState.Edge)?

    var body: some View {
        let state = PresentationState.shared
        if let side = state.secondary, let sideDeck = side.deck {
            GeometryReader { geo in
                let vertical = state.splitVertical
                let total = vertical ? geo.size.height : geo.size.width
                let firstShare = min(max(state.splitFraction, 0.2), 0.8)
                let firstLength = max(0, total * firstShare - DividerHandle.thickness / 2)
                let secondLength = max(0, total - firstLength - DividerHandle.thickness)
                let (first, second) = state.primaryFirst
                    ? ((state.primary, deck), (side, sideDeck))
                    : ((side, sideDeck), (state.primary, deck))
                let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
                layout {
                    pane(first.0, first.1, split: true)
                        .frame(width: vertical ? nil : firstLength, height: vertical ? firstLength : nil)
                    DividerHandle(vertical: vertical) { location in
                        state.splitFraction = min(max((vertical ? location.y : location.x) / max(total, 1), 0.2), 0.8)
                    }
                    pane(second.0, second.1, split: true)
                        .frame(width: vertical ? nil : secondLength, height: vertical ? secondLength : nil)
                }
                .overlay { dropTarget(in: geo.size) }
            }
            .coordinateSpace(name: Self.space)
        } else {
            pane(state.primary, deck, split: false)
        }
    }

    static let space = "documentArea"

    private func pane(_ doc: DocumentState, _ deck: Deck, split: Bool) -> some View {
        let state = PresentationState.shared
        return VStack(spacing: 0) {
            if split {
                PaneHeader(doc: doc, deck: deck) { location, ended in
                    dragHeader(of: doc, to: location, ended: ended)
                }
            }
            ZStack(alignment: .bottomTrailing) {
                if doc.scrollMode {
                    ScrollingPages(deck: deck, doc: doc)
                } else {
                    SlideStage(deck: deck, doc: doc)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                if doc.isPrimary && !doc.scrollMode { primaryOverlay }
            }
            .overlay(alignment: .bottomLeading) {
                if let back = doc.linkHistory.last { BackChip(doc: doc, page: back, deck: deck) }
            }
            .clipped()
        }
        .overlay {
            // With two documents open, a thin outline shows which one the tool bar and keys act on.
            if split && state.active === doc {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.7), lineWidth: 2)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Moving a pane

    private func dragHeader(of doc: DocumentState, to location: CGPoint?, ended: Bool) {
        guard let location else {
            dragging = nil
            return
        }
        if ended {
            if let target = dragging?.edge {
                withAnimation(.snappy) { PresentationState.shared.place(doc, at: target) }
            }
            dragging = nil
        } else {
            dragging = (doc, edge(for: location))
        }
    }

    @State private var areaSize: CGSize = .zero

    /// The edge nearest to where the header is being dragged.
    private func edge(for point: CGPoint) -> PresentationState.Edge {
        let size = areaSize == .zero ? CGSize(width: 1, height: 1) : areaSize
        let x = point.x / size.width, y = point.y / size.height
        let distances: [(PresentationState.Edge, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// While dragging a header, shade the half the pane will move to.
    private func dropTarget(in size: CGSize) -> some View {
        Color.clear
            .onAppear { areaSize = size }
            .onChange(of: size) { _, new in areaSize = new }
            .overlay(alignment: alignment(for: dragging?.edge)) {
                if let edge = dragging?.edge {
                    let horizontal = edge == .leading || edge == .trailing
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: horizontal ? size.width / 2 : size.width,
                               height: horizontal ? size.height : size.height / 2)
                        .padding(4)
                }
            }
            .allowsHitTesting(false)
    }

    private func alignment(for edge: PresentationState.Edge?) -> Alignment {
        switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        case nil: .center
        }
    }
}

/// The bar above each pane when two documents are open: drag it to move the pane; it also
/// has the pages, scrolling, projecting and (for the second PDF) closing.
private struct PaneHeader: View {
    let doc: DocumentState
    let deck: Deck
    /// Drag location in the document area's space (nil when the drag is cancelled), and whether it ended.
    let onDrag: (CGPoint?, Bool) -> Void

    var body: some View {
        let state = PresentationState.shared
        let projected = state.projected === doc
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 36)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named(DocumentArea.space))
                        .onChanged { onDrag($0.location, false) }
                        .onEnded { onDrag($0.location, true) }
                )
                .help("Drag to move this document left, right, up or down")
            Text(deck.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Button { doc.previous() } label: { Image(systemName: "chevron.left") }
                .disabled(doc.scrollMode)
            Text("\(doc.pageIndex + 1) / \(deck.pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button { doc.next() } label: { Image(systemName: "chevron.right") }
                .disabled(doc.scrollMode)
            Button {
                withAnimation(.snappy) { doc.margins.toggle() }
            } label: {
                Image(systemName: "arrow.left.and.right.square")
                    .frame(width: 32, height: 28)
                    .background(doc.margins ? Color.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .help("Blank margins beside the pages for notes")
            Button {
                toggleScroll(doc)
            } label: {
                Image(systemName: "scroll")
                    .frame(width: 32, height: 28)
                    .background(doc.scrollMode ? Color.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .help("Continuous scrolling")
            Button {
                state.projectSecondary = !doc.isPrimary
            } label: {
                Image(systemName: projected ? "display" : "display.2")
                    .frame(width: 32, height: 28)
                    .background(projected ? Color.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .help(projected ? "On the projector" : "Project this document")
            if !doc.isPrimary {
                Button {
                    withAnimation(.snappy) { state.closeSecondary() }
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Close this document")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Color.barBackground)
    }
}

/// Continuous scrolling on or off for a document; turning it on lifts the whiteboard.
@MainActor
func toggleScroll(_ doc: DocumentState) {
    doc.whiteboardShown = false
    doc.resetZoom()
    withAnimation(.snappy) { doc.scrollMode.toggle() }
}

/// The bar between the panes; drag it to change their sizes.
private struct DividerHandle: View {
    static let thickness: CGFloat = 12
    let vertical: Bool
    let onDrag: (CGPoint) -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(Color.barBackground)
            Capsule()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: vertical ? 44 : 4, height: vertical ? 4 : 44)
        }
        .frame(width: vertical ? nil : Self.thickness, height: vertical ? Self.thickness : nil)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(DocumentArea.space))
            .onChanged { onDrag($0.location) })
        .help("Drag to resize")
    }
}

/// All pages in one scrolling column, for reading and note-taking. Each page has its own ink;
/// the page you're on is the current one (and the one the projector shows). Pinch on a page to widen them.
struct ScrollingPages: View {
    let deck: Deck
    let doc: DocumentState
    @State private var scrolledPage: Int?

    var body: some View {
        GeometryReader { geo in
            let width = max(120, (geo.size.width - 24) * doc.zoom)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 14) {
                    ForEach(0..<deck.pageCount, id: \.self) { page in
                        ScrollPage(deck: deck, doc: doc, page: page, width: width)
                            .id(page)
                    }
                }
                .padding(12)
                // Shrunk pages stay centred.
                .frame(minWidth: geo.size.width)
                .scrollTargetLayout()
                .background(ScrollZoom(doc: doc))
            }
            .scrollPosition(id: $scrolledPage, anchor: .top)
            .onAppear { scrolledPage = doc.pageIndex }
            .onChange(of: scrolledPage) { _, page in
                if let page { doc.setCurrentPage(page) }
            }
            // Deliberate jumps (keys, the slide grid, a new inserted page) scroll the list to that page.
            // Touching or writing on a page also makes it current, but must never move the list under the pen.
            .onChange(of: doc.jumpRequest) { _, _ in
                let page = doc.pageIndex
                if scrolledPage != page { withAnimation { scrolledPage = page } }
            }
        }
    }
}

private struct ScrollPage: View {
    let deck: Deck
    let doc: DocumentState
    let page: Int
    /// The sheet's width on screen (the page, plus margins if they're on).
    let width: CGFloat

    var body: some View {
        let state = PresentationState.shared
        let sheet = Sheet(page: deck.pageSize(page), margins: doc.margins)
        let height = sheet.size.width > 0 ? width * sheet.size.height / sheet.size.width : width
        ZStack {
            if sheet.hasMargins {
                MarginPaper(pageShare: sheet.pageShare, color: deck.backgroundColor(page: page), tint: state.pageTint.color)
            }
            ZStack {
                PageImage(deck: deck, page: page, width: width * sheet.pageShare)
                if let tint = state.pageTint.color {
                    tint.blendMode(.multiply).allowsHitTesting(false)
                }
            }
            .pageInSheet(width: width * sheet.pageShare)
            SlideInputView(doc: doc,
                           page: page,
                           pageSize: sheet.size,
                           inkOffset: sheet.leftMargin,
                           keyRevision: doc.keyRevisions[doc.inkKey(forPage: page)] ?? 0,
                           zoom: doc.zoom,
                           visibleRect: CGRect(origin: .zero, size: CGSize(width: width, height: height)),
                           inkKey: doc.inkKey(forPage: page),
                           inkRevision: doc.inkRevision,
                           tool: state.tool,
                           inkColor: state.currentColor,
                           widthFraction: state.widthFraction,
                           penStyle: state.penStyle,
                           fingerDraws: state.fingerDraws,
                           navigationEnabled: !doc.whiteboardShown,
                           eraserWidth: state.eraserWidth,
                           eraserPartial: state.eraserPartial)
            PointerLayer(doc: doc, page: page)
        }
        .frame(width: width, height: height)
        .clipped()
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }
}

/// Pinch-to-zoom for the scrolling pages, attached to the scroll view itself so it works however
/// the fingers land (a pinch on the pages alone loses out once the list starts scrolling).
private struct ScrollZoom: UIViewRepresentable {
    let doc: DocumentState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.isUserInteractionEnabled = false
        view.onAttach = { [weak coordinator = context.coordinator] scrollView in
            coordinator?.install(on: scrollView)
        }
        return view
    }

    func updateUIView(_ view: FinderView, context: Context) {
        context.coordinator.doc = doc
    }

    /// Finds the enclosing scroll view once it's in the hierarchy.
    final class FinderView: UIView {
        var onAttach: ((UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    onAttach?(scrollView)
                    return
                }
                view = current.superview
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var doc: DocumentState?
        private weak var installedOn: UIScrollView?

        func install(on scrollView: UIScrollView) {
            guard installedOn !== scrollView else { return }
            installedOn = scrollView
            // Only fingers scroll: the Pencil writes (or points), it never drags the pages along.
            scrollView.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pinch.delegate = self
            scrollView.addGestureRecognizer(pinch)
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let doc else { return }
            switch recognizer.state {
            case .began, .changed:
                doc.zoom(by: recognizer.scale, around: CGPoint(x: 0.5, y: 0.5))
                recognizer.scale = 1
            default:
                doc.commitZoom()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// After following a link (to a reference, an equation, the appendix), a chip to jump back to where you were.
/// It stays until you go back or dismiss it, so you can look around first. Only on the iPad, never on the projector.
private struct BackChip: View {
    let doc: DocumentState
    let page: Int
    let deck: Deck

    var body: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { _ = doc.goBackFromLink() }
            } label: {
                Label("Back to slide \(deck.slideIndex(ofPage: page) + 1)", systemImage: "arrow.uturn.backward")
                    .font(.callout.weight(.semibold))
                    .padding(.leading, 14)
                    .padding(.trailing, 8)
                    .padding(.vertical, 9)
            }
            Divider().frame(height: 20)
            Button {
                withAnimation(.snappy) { doc.clearLinkHistory() }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
            }
            .foregroundStyle(.secondary)
        }
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .padding(14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
