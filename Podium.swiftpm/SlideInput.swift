import SwiftUI
import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PDFKit

/// The presenter's interactive layer over a slide: PencilKit ink, the pointer,
/// finger taps and swipes for navigation, and Pencil hover.
struct SlideInputView: UIViewRepresentable {
    /// The document this view draws on (the deck, or the PDF beside it).
    let doc: DocumentState
    /// In continuous scrolling, the page this view covers; nil for the single-page view.
    var page: Int? = nil
    /// The sheet's size in page points (the page, plus margins if they're on).
    let pageSize: CGSize
    /// Where the page starts inside the sheet (the left margin), in page points; ink is stored relative to the page.
    var inkOffset: CGFloat = 0
    /// Bumped when another view of the same ink (an overlay step in scroll mode) changes it.
    var keyRevision: Int = 0
    let zoom: CGFloat
    /// The part of the (possibly zoomed) page that's on screen, in the page view's own points.
    let visibleRect: CGRect
    let inkKey: String
    let inkRevision: Int
    let tool: Tool
    let inkColor: UIColor
    let widthFraction: CGFloat
    let penStyle: PenStyle
    let fingerDraws: Bool
    let navigationEnabled: Bool
    let eraserWidth: CGFloat
    let eraserPartial: Bool

    func makeCoordinator() -> SlideInputCoordinator { SlideInputCoordinator() }

    func makeUIView(context: Context) -> SlideInputHost {
        let host = SlideInputHost()
        context.coordinator.attach(to: host)
        return host
    }

    func updateUIView(_ host: SlideInputHost, context: Context) {
        context.coordinator.config = self
        context.coordinator.apply()
    }
}

final class SlideInputHost: UIView {
    let canvas = PageCanvas()
    let pointerView = PointerCaptureView()
    var onLayout: (() -> Void)?
    /// Touches outside this rect go to whatever is on screen there (e.g. the tool bar), not the hidden page.
    var visibleRect: CGRect?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        return visibleRect.map { $0.contains(point) } ?? true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.contentInsetAdjustmentBehavior = .never
        // PencilKit inverts ink colours in dark mode; keep the palette exactly as chosen.
        canvas.overrideUserInterfaceStyle = .light
        pointerView.backgroundColor = .clear
        addSubview(canvas)
        addSubview(pointerView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        pointerView.frame = bounds
        onLayout?()
    }
}

@MainActor
final class SlideInputCoordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate,
                                   @preconcurrency UIEditMenuInteractionDelegate {   // UIKit always calls it on the main thread
    var config: SlideInputView?
    private let state = PresentationState.shared
    /// The document this page belongs to.
    private var doc: DocumentState { config?.doc ?? state.primary }
    private weak var host: SlideInputHost?
    private var tap: UITapGestureRecognizer?
    private var swipes: [UISwipeGestureRecognizer] = []
    private var marginHold: UILongPressGestureRecognizer?
    private var pinch: UIPinchGestureRecognizer?
    private var pan: UIPanGestureRecognizer?
    private var lastSeekEnd: TimeInterval = 0
    private var liveInk: LiveInkRecognizer?
    private var textHold: UILongPressGestureRecognizer?
    private var editMenu: UIEditMenuInteraction?
    /// Selected text (hold a finger on the page, then drag), shown as a tinted overlay.
    private var selection: PDFSelection?
    private var selectionAnchor: CGPoint = .zero
    private let selectionLayer = CAShapeLayer()

    private var loadedKey: String?
    private var loadedRevision = -1
    private var loadedKeyRevision = -1
    private var loadedWidth: CGFloat = 0
    private var isLoadingDrawing = false

    func attach(to host: SlideInputHost) {
        self.host = host
        host.canvas.delegate = self
        // Any touch on this page makes its document the active side.
        let activity = TouchActivityRecognizer(target: nil, action: nil)
        activity.onTouch = { [weak self, weak host] in
            guard let self, let host else { return }
            self.state.activate(self.doc)
            // In scroll mode, the page you touch becomes current, and undo works on it.
            if let page = self.config?.page {
                self.doc.activeCanvas = host.canvas
                self.doc.setCurrentPage(page)
            }
        }
        host.addGestureRecognizer(activity)
        host.onLayout = { [weak self] in self?.apply() }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.delegate = self
        host.addGestureRecognizer(tap)
        self.tap = tap

        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            swipe.delegate = self
            host.addGestureRecognizer(swipe)
            swipes.append(swipe)
        }

        // Press and hold in the left or right margin to fast-seek by whole slides.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleMarginHold(_:)))
        hold.minimumPressDuration = 0.4
        hold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        hold.delegate = self
        host.addGestureRecognizer(hold)
        self.marginHold = hold

        // Hold a finger on text to select it; drag to extend; a menu offers Copy, Highlight and Look Up.
        let textHold = UILongPressGestureRecognizer(target: self, action: #selector(handleTextHold(_:)))
        textHold.minimumPressDuration = 0.45
        textHold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        textHold.delegate = self
        host.addGestureRecognizer(textHold)
        self.textHold = textHold
        let editMenu = UIEditMenuInteraction(delegate: self)
        host.addInteraction(editMenu)
        self.editMenu = editMenu
        selectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.25).cgColor
        host.layer.addSublayer(selectionLayer)

        // Pinch to zoom and two-finger pan (fingers only; the Pencil keeps writing).
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pinch.delegate = self
        host.addGestureRecognizer(pinch)
        self.pinch = pinch
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.delegate = self
        host.addGestureRecognizer(pan)
        self.pan = pan


        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        host.addGestureRecognizer(hover)

        let liveInk = LiveInkRecognizer(target: nil, action: nil)
        liveInk.delegate = self
        liveInk.onPoints = { [weak self] points, began in self?.liveInk(points, began: began) }
        liveInk.onEnd = { [weak self] in self?.liveInkEnded() }
        host.canvas.addGestureRecognizer(liveInk)
        self.liveInk = liveInk

        let pointerView = host.pointerView
        pointerView.onBegin = { [weak self] p in
            guard let self else { return }
            self.pointerStarts()
            self.doc.pointer.begin(p, hover: false)
        }
        pointerView.onMove = { [weak self] p in self?.doc.pointer.move(p) }
        pointerView.onEnd = { [weak self] p, wasTap in
            guard let self else { return }
            if wasTap {
                self.doc.pointer.discardActive()
                if self.config?.navigationEnabled ?? true { self.navigate(tapAt: p.x) }
            } else {
                self.doc.pointer.end()
            }
        }
    }

    /// Pushes the current tool and slide ink into the canvas.
    func apply() {
        guard let config, let host else { return }
        let canvas = host.canvas
        let width = canvas.bounds.width
        guard width > 0, config.pageSize.width > 0 else { return }

        host.visibleRect = config.zoom > 1 ? config.visibleRect : nil
        if config.page == nil { config.doc.activeCanvas = canvas }
        let scrolling = config.page != nil
        // Pencil double-tap (and squeeze on Pencil Pro), following the user's system setting.
        // Only the main page listens, so a tap isn't handled twice when two documents are open.
        if config.doc.isPrimary, host.interactions.allSatisfy({ !($0 is UIPencilInteraction) }) {
            let pencil = UIPencilInteraction()
            pencil.delegate = self
            host.addInteraction(pencil)
        }
        let isPointer = config.tool == .pointer
        canvas.isUserInteractionEnabled = !isPointer
        host.pointerView.isHidden = !isPointer
        canvas.drawingPolicy = config.fingerDraws ? .anyInput : .pencilOnly
        // Scrolling pages: fingers scroll the list, and the list itself handles pinch-to-zoom
        // (see ScrollZoom), so no navigation or zoom gestures on the pages.
        // Taps follow hyperref links everywhere (also while scrolling); elsewhere on the page they turn it.
        tap?.isEnabled = config.navigationEnabled && (!config.fingerDraws || isPointer)
        pinch?.isEnabled = !scrolling
        pan?.isEnabled = !scrolling
        swipes.forEach { $0.isEnabled = !scrolling && config.navigationEnabled && !config.fingerDraws && config.zoom <= 1 }
        // Zoomed in, one finger drags the page around (two still pinch); swipes are off meanwhile.
        pan?.minimumNumberOfTouches = config.zoom > 1 && !config.fingerDraws ? 1 : 2
        textHold?.isEnabled = !config.fingerDraws && !isPointer && !doc.whiteboardShown
        marginHold?.isEnabled = !scrolling && config.navigationEnabled && (!config.fingerDraws || isPointer) && config.zoom <= 1
        liveInk?.acceptsFinger = config.fingerDraws
        host.pointerView.acceptsFinger = config.fingerDraws

        switch config.tool {
        case .pen:
            canvas.tool = PKInkingTool(config.penStyle.inkType, color: config.inkColor,
                                       width: drawnWidth(config.penStyle.inkType, zoomedFraction(config, width), width))
        case .highlighter:
            canvas.tool = PKInkingTool(.marker, color: config.inkColor,
                                       width: drawnWidth(.marker, zoomedFraction(config, width), width))
        case .eraser:
            // Whole strokes (PencilKit gives these no size) or partial with a fixed width in screen points.
            if config.eraserPartial {
                let range = PresentationState.eraserWidths
                canvas.tool = PKEraserTool(.fixedWidthBitmap, width: min(max(config.eraserWidth, range.lowerBound), range.upperBound))
            } else {
                canvas.tool = PKEraserTool(.vector)
            }
        case .pointer:
            break
        }

        let keyChanged = loadedKey != config.inkKey
        if keyChanged || loadedRevision != config.inkRevision || config.keyRevision > loadedKeyRevision
            || abs(loadedWidth - width) > 0.5 {
            let scale = width / config.pageSize.width
            isLoadingDrawing = true
            canvas.drawing = (config.doc.drawings[config.inkKey] ?? PKDrawing())
                .transformed(using: CGAffineTransform(translationX: config.inkOffset, y: 0)
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
            isLoadingDrawing = false
            // Undo belongs to one page of one document. A new document (or a cleared page) can reuse the
            // same key ("s0" is every deck's title slide), and undoing then would paste the old page's ink here.
            if keyChanged || loadedRevision != config.inkRevision { canvas.undoManager?.removeAllActions() }
            loadedKey = config.inkKey
            loadedRevision = config.inkRevision
            loadedKeyRevision = config.keyRevision
            loadedWidth = width
        }
    }

    /// The pen's width as a fraction of this canvas: the same thickness on screen whatever the page's size,
    /// and zoomed in it stays that thick, so you can write small in the margins.
    private func zoomedFraction(_ config: SlideInputView, _ canvasWidth: CGFloat) -> CGFloat {
        // Zoomed out (scrolling small pages), it shrinks with the page instead.
        config.widthFraction * PresentationState.inkReferenceWidth * min(config.zoom, 1) / max(canvasWidth, 1)
    }

    /// Width in canvas points, clamped to what the ink supports so the projector's live stroke can match it.
    private func drawnWidth(_ inkType: PKInkingTool.InkType, _ fraction: CGFloat, _ canvasWidth: CGFloat) -> CGFloat {
        let range = inkType.validWidthRange
        return min(max(fraction * canvasWidth, range.lowerBound), range.upperBound)
    }

    // MARK: Ink

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isLoadingDrawing, let key = loadedKey, let config, canvasView.bounds.width > 0 else { return }
        let scale = config.pageSize.width / canvasView.bounds.width
        let drawing = canvasView.drawing.transformed(using: CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: -config.inkOffset, y: 0)))
        doc.drawings[key] = drawing.strokes.isEmpty ? nil : drawing
        // Other views of this ink (another overlay step in scroll mode) reload it; this one already has it.
        let revision = (doc.keyRevisions[key] ?? 0) + 1
        doc.keyRevisions[key] = revision
        loadedKeyRevision = revision
        // The projector keeps showing the live stroke until its ink image is redrawn (see InkImage),
        // so the stroke never blinks out; liveInkEnded's timer clears it if no projector is attached.
    }

    private func liveInk(_ points: [CGPoint], began: Bool) {
        guard let config, config.tool == .pen || config.tool == .highlighter,
              let bounds = host?.canvas.bounds, bounds.width > 0, bounds.height > 0 else { return }
        let unit = points.map { CGPoint(x: $0.x / bounds.width, y: $0.y / bounds.height) }
        if began || doc.liveStroke == nil || doc.liveStroke?.ended == true {
            let inkType: PKInkingTool.InkType = config.tool == .highlighter ? .marker : config.penStyle.inkType
            doc.beginLiveStroke(at: unit,
                                  widthFraction: drawnWidth(inkType, zoomedFraction(config, bounds.width), bounds.width) / bounds.width)
        } else {
            doc.liveStroke?.points.append(contentsOf: unit)
        }
    }

    private func liveInkEnded() {
        let doc = doc
        guard let id = doc.liveStroke?.id else { return }
        doc.liveStroke?.ended = true
        // Fallback in case PencilKit discards the stroke and never reports a change.
        Task { @MainActor [weak doc] in
            try? await Task.sleep(for: .milliseconds(500))
            if let doc, doc.liveStroke?.id == id { doc.liveStroke = nil }
        }
    }

    // MARK: Navigation and pointer

    private func navigate(tapAt unitX: CGFloat) {
        if unitX < 0.3 { doc.previous() } else { doc.next() }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        // A hold that just finished seeking shouldn't also count as a tap.
        guard let host, host.bounds.width > 0, !doc.isSeeking,
              ProcessInfo.processInfo.systemUptime - lastSeekEnd > 0.4 else { return }
        // A tap away from selected text just clears the selection.
        if selection != nil {
            editMenu?.dismissMenu()
            clearSelection()
            return
        }
        let point = recognizer.location(in: host)
        if followLink(at: point, in: host) { return }
        guard config?.page == nil else { return }
        navigate(tapAt: point.x / host.bounds.width)
    }

    /// A link in the PDF under the finger (hyperref, Beamer's navigation symbols): follows it.
    private func followLink(at point: CGPoint, in host: UIView) -> Bool {
        guard let config, let deck = doc.deck, !doc.whiteboardShown, host.bounds.width > 0 else { return false }
        let index = config.page ?? doc.pageIndex
        guard let page = deck.document.page(at: index), page.rotation % 360 == 0 else { return false }
        // Host points → sheet points → page points (left of the margin) → PDF points (origin bottom left).
        let scale = config.pageSize.width / host.bounds.width
        let crop = page.bounds(for: .cropBox)
        let pdfPoint = CGPoint(x: crop.minX + point.x * scale - config.inkOffset, y: crop.maxY - point.y * scale)
        let links = page.annotations.filter { $0.type == "Link" || $0.action != nil || $0.destination != nil }
        // A fingertip is bigger than Beamer's small links, so allow a little slack.
        let slack = 10 * scale
        guard let link = links.first(where: { $0.bounds.contains(pdfPoint) })
                ?? links.first(where: { $0.bounds.insetBy(dx: -slack, dy: -slack).contains(pdfPoint) }) else { return false }

        if let destination = link.destination ?? (link.action as? PDFActionGoTo)?.destination,
           let target = destination.page {
            let targetIndex = deck.document.index(for: target)
            guard targetIndex != NSNotFound else { return false }
            doc.follow(linkTo: targetIndex)
            return true
        }
        if let named = link.action as? PDFActionNamed {
            switch named.name {
            case .nextPage: doc.next()
            case .previousPage: doc.previous()
            case .firstPage: doc.follow(linkTo: 0)
            case .lastPage: doc.follow(linkTo: deck.pageCount - 1)
            case .goBack: if !doc.goBackFromLink() { doc.previous() }
            case .goForward: doc.next()
            default: return false
            }
            return true
        }
        if let url = (link.action as? PDFActionURL)?.url ?? link.url {
            UIApplication.shared.open(url)
            return true
        }
        return false
    }

    // MARK: Text selection

    /// The PDF page under this view and a point on it, in PDF coordinates (origin bottom left).
    private func pdfLocation(of point: CGPoint) -> (PDFPage, CGPoint)? {
        guard let config, let deck = doc.deck, let host, host.bounds.width > 0 else { return nil }
        guard let page = deck.document.page(at: config.page ?? doc.pageIndex), page.rotation % 360 == 0 else { return nil }
        let scale = config.pageSize.width / host.bounds.width
        let crop = page.bounds(for: .cropBox)
        return (page, CGPoint(x: crop.minX + point.x * scale - config.inkOffset, y: crop.maxY - point.y * scale))
    }

    /// A rectangle in PDF coordinates, in this view's points.
    private func viewRect(_ rect: CGRect, on page: PDFPage) -> CGRect? {
        guard let config, let host, host.bounds.width > 0, config.pageSize.width > 0 else { return nil }
        let scale = config.pageSize.width / host.bounds.width
        let crop = page.bounds(for: .cropBox)
        return CGRect(x: (rect.minX - crop.minX + config.inkOffset) / scale, y: (crop.maxY - rect.maxY) / scale,
                      width: rect.width / scale, height: rect.height / scale)
    }

    private func lineRects(_ selection: PDFSelection) -> [CGRect] {
        guard let page = selection.pages.first else { return [] }
        return selection.selectionsByLine().compactMap { viewRect($0.bounds(for: page), on: page) }
            .filter { $0.width > 0.5 && $0.height > 0.5 }
    }

    @objc private func handleTextHold(_ recognizer: UILongPressGestureRecognizer) {
        guard let host, let (page, point) = pdfLocation(of: recognizer.location(in: host)) else { return }
        switch recognizer.state {
        case .began:
            editMenu?.dismissMenu()
            doc.pointer.discardActive()
            selectionAnchor = point
            selection = page.selectionForWord(at: point)
        case .changed:
            guard let word = page.selectionForWord(at: selectionAnchor) else { return }
            if let span = page.selection(from: selectionAnchor, to: point) {
                span.add(word)
                if let end = page.selectionForWord(at: point) { span.add(end) }
                selection = span
            }
        case .ended:
            showSelection()
            if let rect = selectionBounds() {
                editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil,
                                                                        sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
            }
            return
        default:
            clearSelection()
            return
        }
        showSelection()
    }

    private func showSelection() {
        let path = UIBezierPath()
        for rect in selection.map(lineRects) ?? [] { path.append(UIBezierPath(rect: rect.insetBy(dx: -1, dy: -1))) }
        selectionLayer.frame = host?.bounds ?? .zero
        selectionLayer.path = path.cgPath
    }

    private func selectionBounds() -> CGRect? {
        let rects = selection.map(lineRects) ?? []
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private func clearSelection() {
        selection = nil
        selectionLayer.path = nil
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let text = selection?.string, !text.isEmpty else { return nil }
        // PDFs break lines with hard returns; copy it as running text.
        let running = text.replacingOccurrences(of: "-\n", with: "").replacingOccurrences(of: "\n", with: " ")
        return UIMenu(children: [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = running
            },
            UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
                self?.highlightSelection()
            },
            UIAction(title: "Look Up", image: UIImage(systemName: "character.book.closed")) { _ in
                let term = running.trimmingCharacters(in: .whitespacesAndNewlines)
                UIApplication.topViewController?.present(UIReferenceLibraryViewController(term: term), animated: true)
            },
        ])
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        selectionBounds() ?? .zero
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        animator.addCompletion { [weak self] in self?.clearSelection() }
    }

    /// Highlighter ink over each selected line, in the highlighter's colour (undo removes it).
    private func highlightSelection() {
        guard let canvas = host?.canvas, let selection else { return }
        let range = PKInkingTool.InkType.marker.validWidthRange
        let strokes = lineRects(selection).map { rect -> PKStroke in
            // The marker is thinner than a line of text, so one stroke goes back and forth to cover the line.
            let band = rect.insetBy(dx: 0, dy: -rect.height * 0.05)
            let width = min(max(band.height, range.lowerBound), range.upperBound)
            let rows = max(1, Int(ceil((band.height - width) / (width * 0.7))) + 1)
            var points: [PKStrokePoint] = []
            for row in 0..<rows {
                let y = rows == 1 ? band.midY : band.minY + width / 2 + CGFloat(row) * (band.height - width) / CGFloat(rows - 1)
                let xs = row % 2 == 0 ? [band.minX, band.maxX] : [band.maxX, band.minX]
                for x in xs {
                    points.append(PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: TimeInterval(points.count) * 0.05,
                                                size: CGSize(width: width, height: width), opacity: 1, force: 1,
                                                azimuth: .pi / 2, altitude: .pi / 2))   // chisel tip across the line
                }
            }
            return PKStroke(ink: PKInk(.marker, color: state.highlighterColor),
                            path: PKStrokePath(controlPoints: points, creationDate: .now))
        }
        guard !strokes.isEmpty else { return }
        let before = canvas.drawing
        var after = before
        after.strokes.append(contentsOf: strokes)
        setDrawing(after, on: canvas, undoTo: before)
    }

    private func setDrawing(_ drawing: PKDrawing, on canvas: PKCanvasView, undoTo previous: PKDrawing) {
        canvas.drawing = drawing
        canvas.undoManager?.registerUndo(withTarget: self) { [weak canvas] coordinator in
            guard let canvas else { return }
            coordinator.setDrawing(previous, on: canvas, undoTo: drawing)
        }
    }

    @objc private func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
        if recognizer.direction == .left { doc.next() } else { doc.previous() }
    }

    /// In scroll mode the pointer belongs to the page it's on; that page becomes the projected one.
    private func pointerStarts() {
        guard let page = config?.page else { return }
        if doc.pointerPage != page {
            doc.pointer.reset()
            doc.pointerPage = page
        }
        doc.setCurrentPage(page)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let host, host.bounds.width > 0, host.bounds.height > 0 else { return }
        switch recognizer.state {
        case .began, .changed:
            let p = recognizer.location(in: host)
            doc.zoom(by: recognizer.scale, around: CGPoint(x: p.x / host.bounds.width, y: p.y / host.bounds.height))
            recognizer.scale = 1
        default:
            doc.commitZoom()
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        // Measured in window points: the page itself moves while panning.
        guard let host, let window = host.window, host.bounds.width > 0, host.bounds.height > 0 else { return }
        let t = recognizer.translation(in: window)
        doc.panZoom(by: CGSize(width: t.x / host.bounds.width, height: t.y / host.bounds.height))
        recognizer.setTranslation(.zero, in: window)
    }

    @objc private func handleMarginHold(_ recognizer: UILongPressGestureRecognizer) {
        guard let host else { return }
        switch recognizer.state {
        case .began:
            doc.pointer.discardActive()
            doc.startSeeking(forward: recognizer.location(in: host).x > host.bounds.width / 2)
        case .ended, .cancelled, .failed:
            doc.stopSeeking()
            lastSeekEnd = ProcessInfo.processInfo.systemUptime
        default:
            break
        }
    }

    /// Fast-seek only starts from the outer ~12% on each side, so a hold elsewhere stays a pointer hold.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === textHold, let host {
            guard let (page, point) = pdfLocation(of: gestureRecognizer.location(in: host)) else { return false }
            return !(page.selectionForWord(at: point)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard gestureRecognizer === marginHold, let host, host.bounds.width > 0 else { return true }
        let x = gestureRecognizer.location(in: host).x / host.bounds.width
        return x < 0.12 || x > 0.88
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard config?.tool == .pointer, let host, host.bounds.width > 0 else { return }
        let p = recognizer.location(in: host)
        let unit = CGPoint(x: p.x / host.bounds.width, y: p.y / host.bounds.height)
        switch recognizer.state {
        case .began:
            state.activate(doc)
            pointerStarts()
            doc.pointer.begin(unit, hover: true)
        case .changed: doc.pointer.move(unit)
        default: doc.pointer.end()
        }
    }

    // MARK: Pencil double-tap and squeeze

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        if clicker(forward: true) { return }
        perform(UIPencilInteraction.preferredTapAction)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        if clicker(forward: false) { return }
        perform(UIPencilInteraction.preferredSqueezeAction)
    }

    /// Before iOS 17.5 only double-tap exists.
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        if clicker(forward: true) { return }
        perform(UIPencilInteraction.preferredTapAction)
    }

    /// In pointer mode the Pencil is a clicker: double-tap for the next step, squeeze for the previous one.
    private func clicker(forward: Bool) -> Bool {
        guard state.tool == .pointer, state.pencilTapAdvances else { return false }
        guard Self.firstToHandlePencil() else { return true }
        forward ? state.next() : state.previous()
        return true
    }

    /// With several pages on screen (continuous scrolling) each page listens for the Pencil;
    /// only the first to hear a tap acts on it.
    private static var lastPencilAction: TimeInterval = 0
    private static func firstToHandlePencil() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPencilAction > 0.25 else { return false }
        lastPencilAction = now
        return true
    }

    private func perform(_ action: UIPencilPreferredAction) {
        guard Self.firstToHandlePencil() else { return }
        switch action {
        case .switchEraser:
            state.tool = state.tool == .eraser ? state.lastInkTool : .eraser
        case .switchPrevious:
            state.tool = state.previousTool
        case .showColorPalette, .showInkAttributes:
            state.colorPaletteRequest += 1
        default:
            if #available(iOS 17.5, *), action == .showContextualPalette {
                state.colorPaletteRequest += 1
            }
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // With "draw with finger" on, the pointer view handles finger taps and drags itself.
        // Otherwise fingers only navigate, even in pointer mode.
        if gestureRecognizer === tap || swipes.contains(where: { $0 === gestureRecognizer }) {
            return !(config?.fingerDraws ?? false) || touch.view !== host?.pointerView
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let zoomGestures: [UIGestureRecognizer?] = [pinch, pan]
        let bothZoom = zoomGestures.contains { $0 === gestureRecognizer } && zoomGestures.contains { $0 === other }
        return bothZoom || gestureRecognizer === liveInk || other === liveInk
    }
}

/// Watches Pencil touches on the canvas without taking part in drawing,
/// so the in-progress stroke can be mirrored to the audience screen.
final class LiveInkRecognizer: UIGestureRecognizer {
    var onPoints: (([CGPoint], Bool) -> Void)?
    var onEnd: (() -> Void)?
    var acceptsFinger = false
    private var tracking: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracking == nil,
              let touch = touches.first(where: { $0.type == .pencil || acceptsFinger }) else { return }
        tracking = touch
        onPoints?([touch.location(in: view)], true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracking, touches.contains(touch) else { return }
        let samples = event.coalescedTouches(for: touch) ?? [touch]
        onPoints?(samples.map { $0.location(in: view) }, false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        guard let touch = tracking, touches.contains(touch) else { return }
        tracking = nil
        onEnd?()
        state = .failed
    }

    override func reset() {
        super.reset()
        tracking = nil
    }
}

/// Captures pointer drags from the Pencil, and from fingers only when "draw with finger" is on
/// (then a quick finger tap still means "next slide"). Other finger touches are left to the
/// navigation gestures, so they never leave a pointer dot or trail.
final class PointerCaptureView: UIView {
    var acceptsFinger = false
    var onBegin: ((CGPoint) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onEnd: ((CGPoint, Bool) -> Void)?

    private var tracking: UITouch?
    private var startPoint: CGPoint = .zero
    private var startTime: TimeInterval = 0
    private var travelled: CGFloat = 0

    private func unit(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / max(bounds.width, 1), y: p.y / max(bounds.height, 1))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracking == nil,
              let touch = touches.first(where: { $0.type != .direct || acceptsFinger }) else { return }
        tracking = touch
        startPoint = touch.location(in: self)
        startTime = touch.timestamp
        travelled = 0
        onBegin?(unit(startPoint))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracking, touches.contains(touch) else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            let p = sample.location(in: self)
            travelled = max(travelled, hypot(p.x - startPoint.x, p.y - startPoint.y))
            onMove?(unit(p))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracking, touches.contains(touch) else { return }
        tracking = nil
        let wasTap = touch.type == .direct && travelled < 12 && touch.timestamp - startTime < 0.3
        onEnd?(unit(touch.location(in: self)), wasTap)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracking, touches.contains(touch) else { return }
        tracking = nil
        onEnd?(unit(touch.location(in: self)), false)
    }
}

/// Notices any touch on a page (finger or Pencil) without taking part, to mark that side active.
final class TouchActivityRecognizer: UIGestureRecognizer {
    var onTouch: (() -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch?()
        state = .failed
    }
}

/// A canvas with its own undo history, so clearing one page's undo (when it shows other ink) doesn't
/// clear the page being written on (scroll mode, side by side).
final class PageCanvas: PKCanvasView {
    private let ownUndoManager = UndoManager()
    override var undoManager: UndoManager? { ownUndoManager }
    // PencilKit's own menu (Select All, Insert Space) has no use here.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
}
