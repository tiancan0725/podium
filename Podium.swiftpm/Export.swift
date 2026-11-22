import UIKit
import PencilKit

/// Makes a copy of the deck with the ink drawn on its pages (plus the whiteboard, and optionally
/// the prep notes as an appendix), then offers it through the share sheet: Save to Files, Mail, AirDrop.
@MainActor
enum Exporter {
    static func share(includePrepNotes: Bool) {
        let state = PresentationState.shared
        guard let deck = state.deck else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(deck.title) (annotated).pdf")
        // Prep notes belong to the deck, so they're only added when exporting it.
        let notes = includePrepNotes && state.active.isPrimary ? PrepStore.shared.notes : [:]
        // With margins on, pages are exported with their margins so notes written there are kept.
        guard write(deck: deck, drawings: state.drawings, notes: notes, margins: state.active.margins, to: url) else { return }

        guard let presenter = UIApplication.topViewController else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.maxX - 80, y: 40, width: 1, height: 1)
        presenter.present(sheet, animated: true)
    }

    private static func write(deck: Deck, drawings: [String: PKDrawing], notes: [Int: PrepNote],
                              margins: Bool, to url: URL) -> Bool {
        let first = deck.pageSize(0)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first))
        do {
            try renderer.writePDF(to: url) { context in
                for index in 0..<deck.pageCount {
                    guard let page = deck.document.page(at: index) else { continue }
                    let size = deck.pageSize(index)
                    let sheet = Sheet(page: size, margins: margins)
                    let bounds = CGRect(origin: .zero, size: sheet.size)
                    context.beginPage(withBounds: bounds, pageInfo: pageInfo(bounds))
                    let cg = context.cgContext
                    if sheet.hasMargins {
                        deck.backgroundColor(page: index).setFill()
                        context.fill(bounds)
                    }
                    // PDFKit draws with the origin at the bottom left; UIKit's is at the top left.
                    cg.saveGState()
                    cg.translateBy(x: sheet.leftMargin, y: size.height)
                    cg.scaleBy(x: 1, y: -1)
                    page.draw(with: .cropBox, to: cg)
                    cg.restoreGState()
                    let slide = deck.slideIndex(ofPage: index)
                    for key in ["s\(slide)", "p\(index)"] {
                        if let drawing = drawings[key] {
                            draw(drawing, from: CGRect(origin: CGPoint(x: -sheet.leftMargin, y: 0), size: sheet.size), in: bounds)
                        }
                    }
                }
                if let board = drawings[PresentationState.boardKey] {
                    let bounds = CGRect(origin: .zero, size: first)
                    context.beginPage(withBounds: bounds, pageInfo: pageInfo(bounds))
                    UIColor(white: PresentationState.shared.boardIsDark ? 0.12 : 1, alpha: 1).setFill()
                    context.fill(bounds)
                    draw(board, from: bounds, in: bounds)
                }
                if !notes.isEmpty { appendNotes(notes, deck: deck, context: context) }
            }
            return true
        } catch {
            return false
        }
    }

    /// Page size has to go in the page info too, or every page keeps the first page's size.
    private static func pageInfo(_ bounds: CGRect) -> [String: Any] {
        var box = bounds
        let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        return [kCGPDFContextMediaBox as String: data, kCGPDFContextCropBox as String: data]
    }

    /// Ink is stored in page coordinates, so it lines up with the page at any size.
    /// `source` is the area to draw, in page coordinates (with margins it reaches past the page's edges).
    private static func draw(_ drawing: PKDrawing, from source: CGRect, in bounds: CGRect) {
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            drawing.image(from: source, scale: 3).draw(in: bounds)
        }
    }

    /// The prep notes on letter-size pages after the slides, one block per slide.
    private static func appendNotes(_ notes: [Int: PrepNote], deck: Deck, context: UIGraphicsPDFRendererContext) {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 48
        let width = page.width - 2 * margin
        var y = CGFloat.infinity
        func newPage() {
            context.beginPage(withBounds: page, pageInfo: pageInfo(page))
            y = margin
        }
        let heading: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 13)]
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11)]
        newPage()
        NSAttributedString(string: "Prep notes · \(deck.title)", attributes: [.font: UIFont.boldSystemFont(ofSize: 17)])
            .draw(at: CGPoint(x: margin, y: y))
        y += 34
        for slide in notes.keys.sorted() {
            guard let note = notes[slide], !note.isEmpty else { continue }
            let block = NSMutableAttributedString(string: "Slide \(slide + 1)\n", attributes: heading)
            block.append(NSAttributedString(string: note.text + "\n", attributes: body))
            let height = block.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin], context: nil).height
            if y + height > page.height - margin { newPage() }
            block.draw(with: CGRect(x: margin, y: y, width: width, height: height),
                       options: [.usesLineFragmentOrigin], context: nil)
            y += height + 12
        }
    }
}
