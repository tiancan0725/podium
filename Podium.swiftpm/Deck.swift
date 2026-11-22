import PDFKit
import UIKit

/// One Beamer frame. Every overlay step (\pause, \item<+->) is its own PDF page.
struct Slide: Identifiable {
    let id: Int
    let pages: ClosedRange<Int>
    var number: Int { id + 1 }
}

/// Its pages and slides don't change after init (built off the main thread); only the image and
/// background caches fill in later, from the main thread.
final class Deck: @unchecked Sendable {
    let title: String
    let document: PDFDocument
    let slides: [Slide]
    /// A stable identity per slide (its title and first lines of text), so saved notes find
    /// their slide again after the deck is recompiled with frames added or removed.
    let fingerprints: [String]
    private let slideIndexOfPage: [Int]
    private let cache = NSCache<NSString, UIImage>()
    private var backgrounds: [Int: UIColor] = [:]

    /// A document to read (Markdown, text) rather than slides: it opens scrolling.
    let isReader: Bool
    /// The PDF as loaded, before any pages were inserted (to rebuild the deck when inserts change).
    let sourceData: Data
    /// Pages added in Podium (blank pages, photos), by page index in `document`.
    let insertedPages: [Int: InsertedPage]

    /// Parses the PDF, splices in pages added in Podium, and groups pages into slides.
    /// Safe to call off the main thread.
    init?(data: Data, title: String, inserts: [LoadedInsert] = [], isReader: Bool = false) {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        self.title = title
        self.isReader = isReader
        self.sourceData = data

        // Each insert goes after the slide it was added to (found by its text, else by position),
        // in the order they were added.
        var inserted: [Int: InsertedPage] = [:]
        if !inserts.isEmpty {
            let original = Deck.group(document)
            var index: [String: Int] = [:]
            for (i, fingerprint) in original.fingerprints.enumerated() { index[fingerprint] = i }
            // A page added after another added page follows that page's anchor back to a slide of the PDF.
            let byID = Dictionary(inserts.map { ("inserted-\($0.record.id.uuidString)", $0.record) }, uniquingKeysWith: { a, _ in a })
            func anchor(_ record: InsertedPage) -> InsertedPage {
                var current = record
                for _ in 0..<inserts.count {
                    guard let key = current.afterFingerprint, let previous = byID[key] else { break }
                    current = previous
                }
                return current
            }
            // A page that can't be made (a missing photo) is left out entirely, so later positions stay right.
            var placements: [(after: Int, insert: LoadedInsert, page: PDFPage)] = []
            for insert in inserts {
                guard let page = insert.makePage() else { continue }
                let base = anchor(insert.record)
                let slide = base.afterFingerprint.flatMap { index[$0] }
                    ?? min(max(base.afterSlide, -1), original.slides.count - 1)
                let afterPage = slide < 0 ? -1 : original.slides[slide].pages.upperBound
                placements.append((afterPage, insert, page))
            }
            // Insert from the back so earlier positions stay valid; inserts after the same page keep their order.
            for (_, placement) in placements.enumerated().sorted(by: {
                $0.element.after != $1.element.after ? $0.element.after > $1.element.after : $0.offset > $1.offset
            }) {
                document.insert(placement.page, at: placement.after + 1)
            }
            // Find where each inserted page ended up.
            var cursor = 0
            var byAfter: [Int: [LoadedInsert]] = [:]
            for placement in placements { byAfter[placement.after, default: []].append(placement.insert) }
            for originalPage in -1..<original.pageCount {
                if originalPage >= 0 { cursor += 1 }
                for insert in byAfter[originalPage] ?? [] {
                    inserted[cursor] = insert.record
                    cursor += 1
                }
            }
        }
        self.document = document
        self.insertedPages = inserted

        let grouped = Deck.group(document, inserted: inserted)
        self.slides = grouped.slides
        self.fingerprints = grouped.fingerprints
        self.slideIndexOfPage = grouped.slideIndexOfPage
        cache.totalCostLimit = 300 * 1024 * 1024
    }

    /// Groups pages into slides (overlay steps of one frame together) and fingerprints each slide.
    /// Inserted pages are always slides of their own, identified by their id.
    private static func group(_ document: PDFDocument, inserted: [Int: InsertedPage] = [:])
        -> (slides: [Slide], fingerprints: [String], slideIndexOfPage: [Int], pageCount: Int) {
        var slides: [Slide] = []
        var slideIndexOfPage: [Int] = []
        var fingerprints: [String] = []
        var seen: [String: Int] = [:]
        var start = 0
        var previous = Deck.textLines(of: document, at: 0)
        var firstLines = previous
        for i in 1...document.pageCount {
            let current = i < document.pageCount ? Deck.textLines(of: document, at: i) : []
            let boundary = inserted[i] != nil || inserted[i - 1] != nil
            if i == document.pageCount || boundary || !Deck.isOverlayStep(previous, then: current) {
                slides.append(Slide(id: slides.count, pages: start...(i - 1)))
                slideIndexOfPage += Array(repeating: slides.count - 1, count: i - start)
                if let insert = inserted[start] {
                    fingerprints.append("inserted-\(insert.id.uuidString)")
                } else {
                    let base = Deck.fingerprint(firstLines)
                    let occurrence = seen[base, default: 0]
                    seen[base] = occurrence + 1
                    fingerprints.append("\(base)#\(occurrence)")
                }
                start = i
                firstLines = current
            }
            previous = current
        }
        return (slides, fingerprints, slideIndexOfPage, document.pageCount)
    }

    /// Title plus the first few lines, lowercased and with whitespace collapsed. Frame counters
    /// ("3 / 20") and number-only lines are dropped, since they shift when frames are added.
    private static func fingerprint(_ lines: [String]) -> String {
        lines
            .filter { line in line.contains { $0.isLetter } }
            .prefix(4)
            .map { $0.replacing(#/\d+\s*/\s*\d+/#, with: "") }
            .map { $0.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .joined(separator: "\n")
    }

    private static func textLines(of document: PDFDocument, at index: Int) -> [String] {
        (document.page(at: index)?.string ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Two consecutive pages are steps of one frame when they share a title and the
    /// later page contains all the text of the earlier one. Beamer keeps text hidden by
    /// \pause in the PDF (just not drawn), so steps usually have identical text.
    /// Page labels would be the obvious signal, but XeLaTeX writes them one page late
    /// and unnumbered section slides share a number, so they can't be trusted.
    private static func isOverlayStep(_ earlier: [String], then later: [String]) -> Bool {
        guard let title = earlier.first, title == later.first else { return false }
        var available: [String: Int] = [:]
        for line in later { available[line, default: 0] += 1 }
        for line in earlier {
            guard let count = available[line], count > 0 else { return false }
            available[line] = count - 1
        }
        return true
    }

    var pageCount: Int { document.pageCount }

    /// "--- Slide N ---" and the text of each slide's last step, cut off after about `limit` characters.
    func slideByslideText(limit: Int) -> String {
        var text = ""
        for slide in slides {
            text += "\n--- Slide \(slide.number) ---\n\(document.page(at: slide.pages.upperBound)?.string ?? "")\n"
            if text.count > limit { return String(text.prefix(limit)) + "\n[Deck text truncated here.]" }
        }
        return text
    }

    func slideIndex(ofPage page: Int) -> Int { slideIndexOfPage[page] }
    func slide(ofPage page: Int) -> Slide { slides[slideIndexOfPage[page]] }

    func pageSize(_ index: Int) -> CGSize {
        guard let page = document.page(at: index) else { return CGSize(width: 4, height: 3) }
        let bounds = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
    }

    /// The page's background colour: the most common colour down its right edge (so a coloured
    /// footline or a figure doesn't count). Used for the note margin beside the page.
    func backgroundColor(page index: Int) -> UIColor {
        if let known = backgrounds[index] { return known }
        var color = UIColor.white
        if let cg = image(page: index, width: 96, scale: 1)?.cgImage {
            let w = cg.width, h = cg.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            data.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            // Group near-identical shades (5 bits per channel), then average the real pixels of the biggest group.
            var groups: [UInt32: (count: Int, r: Int, g: Int, b: Int)] = [:]
            for y in 0..<h {
                for x in max(0, w - 3)..<w {
                    let i = (y * w + x) * 4
                    let key = UInt32(data[i] >> 3) << 10 | UInt32(data[i + 1] >> 3) << 5 | UInt32(data[i + 2] >> 3)
                    var group = groups[key] ?? (0, 0, 0, 0)
                    group.count += 1
                    group.r += Int(data[i]); group.g += Int(data[i + 1]); group.b += Int(data[i + 2])
                    groups[key] = group
                }
            }
            if let group = groups.values.max(by: { $0.count < $1.count }) {
                let n = CGFloat(group.count) * 255
                color = UIColor(red: CGFloat(group.r) / n, green: CGFloat(group.g) / n, blue: CGFloat(group.b) / n, alpha: 1)
            }
        }
        backgrounds[index] = color
        return color
    }

    /// Renders a page at roughly `width` points. Widths are bucketed so nearby sizes share a cache entry.
    func image(page index: Int, width: CGFloat, scale: CGFloat) -> UIImage? {
        let pixelWidth = max(64, (width * scale / 64).rounded(.up) * 64)
        let key = "\(index)-\(Int(pixelWidth))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let page = document.page(at: index) else { return nil }
        let size = pageSize(index)
        let pixelSize = CGSize(width: pixelWidth, height: (pixelWidth * size.height / size.width).rounded())
        guard let cgImage = page.thumbnail(of: pixelSize, for: .cropBox).cgImage else { return nil }
        let image = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}

/// Size of `content` scaled to fit inside `box`, keeping its aspect ratio.
func fitted(_ content: CGSize, in box: CGSize) -> CGSize {
    guard content.width > 0, content.height > 0, box.width > 0, box.height > 0 else { return .zero }
    let s = min(box.width / content.width, box.height / content.height)
    return CGSize(width: content.width * s, height: content.height * s)
}
