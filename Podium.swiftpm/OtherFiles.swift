import UIKit
import PDFKit
import UniformTypeIdentifiers

/// Files Podium opens besides PDFs. Each is turned into PDF pages when it's opened, so ink, notes,
/// links, scrolling and the projector work the same as for slides; the file itself is never changed.
enum OtherFiles {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    static let textExtensions: Set<String> = ["txt", "text"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff"]
    static let extensions: Set<String> = Set(["pdf"]).union(markdownExtensions).union(textExtensions).union(imageExtensions)

    static func canOpen(_ fileName: String) -> Bool {
        extensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// Markdown and plain text open as a scrolling reader rather than as slides.
    static func isReader(_ fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return markdownExtensions.contains(ext) || textExtensions.contains(ext)
    }

    /// The name shown in the library: PDFs without ".pdf", other files with their extension so
    /// "notes.md" and "notes.pdf" can be told apart.
    static func displayName(_ fileName: String) -> String {
        (fileName as NSString).pathExtension.lowercased() == "pdf" ? (fileName as NSString).deletingPathExtension : fileName
    }

    /// For the Files picker.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .image]
        for ext in markdownExtensions { if let type = UTType(filenameExtension: ext) { types.append(type) } }
        return types
    }

    /// The file's contents as a PDF. Math in Markdown is typeset first (on the main thread, by KaTeX);
    /// the rest runs in the background.
    static func pdfData(from data: Data, fileName: String) async -> Data? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if markdownExtensions.contains(ext) {
            let text = String(decoding: data, as: UTF8.self)
            let formulas = Markdown.formulas(in: text)
            let math = formulas.isEmpty ? [:] : await MathRenderer.render(formulas)
            return await Task.detached(priority: .userInitiated) {
                Reader.pdf(Markdown.render(text, math: math))
            }.value
        }
        return await Task.detached(priority: .userInitiated) { pdfData(other: data, ext: ext) }.value
    }

    private static func pdfData(other data: Data, ext: String) -> Data? {
        if textExtensions.contains(ext) {
            return Reader.pdf(Markdown.plain(String(decoding: data, as: UTF8.self)))
        }
        if imageExtensions.contains(ext) {
            guard let image = UIImage(data: data), let page = PDFPage(image: image) else { return nil }
            let document = PDFDocument()
            document.insert(page, at: 0)
            return document.dataRepresentation()
        }
        return data
    }
}

/// Lays out styled text on pages shaped like the iPad in portrait, and writes them as a PDF
/// (links stay tappable).
enum Reader {
    /// US Letter with one-inch margins, like a typical paper.
    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 72
    /// Where a link points (drawn as plain coloured text, like hyperref; becomes a link annotation).
    static let linkKey = NSAttributedString.Key("podiumLink")
    /// Pictures (formulas, table rows) are kept shorter than this, or the page break couldn't place them.
    static let tallest = pageSize.height - 2 * margin - 24

    static func pdf(_ text: NSAttributedString) -> Data {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let textSize = CGSize(width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            if NSMaxRange(range) >= layout.numberOfGlyphs || range.length == 0 { break }
        } while containers.count < 2000

        let origin = CGPoint(x: margin, y: margin)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        return renderer.pdfData { context in
            for container in containers {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: pageSize))
                let glyphs = layout.glyphRange(for: container)
                layout.drawBackground(forGlyphRange: glyphs, at: origin)
                layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
                // Links become link annotations, so tapping them works in Podium too.
                let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                storage.enumerateAttribute(Reader.linkKey, in: characters) { value, range, _ in
                    guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return }
                    let linkGlyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    layout.enumerateEnclosingRects(forGlyphRange: linkGlyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                   in: container) { rect, _ in
                        // Link rectangles are in PDF space (origin bottom left), unlike the drawing.
                        let r = rect.offsetBy(dx: origin.x, dy: origin.y)
                        context.setURL(url, for: CGRect(x: r.minX, y: pageSize.height - r.maxY, width: r.width, height: r.height))
                    }
                }
            }
        }
    }
}

/// Computer Modern, from the KaTeX fonts already bundled for the math, so Markdown pages look like
/// a compiled LaTeX document (text and formulas in the same typeface). Falls back to the iPad's serif.
enum ReaderFonts {
    private static let names: [String: String] = {
        // The KaTeX style sheet carries each font as a data URL; register Main (text) and Typewriter (code).
        var out: [String: String] = [:]
        let css = KaTeXAssets.style
        guard let regex = try? NSRegularExpression(
            pattern: "font-family:(KaTeX_Main|KaTeX_Typewriter);font-style:(\\w+);font-weight:(\\d+);src:url\\(data:font/woff2;base64,([A-Za-z0-9+/=]+)\\)")
        else { return out }
        for match in regex.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
            guard let family = Range(match.range(at: 1), in: css), let style = Range(match.range(at: 2), in: css),
                  let weight = Range(match.range(at: 3), in: css), let base64 = Range(match.range(at: 4), in: css),
                  let data = Data(base64Encoded: String(css[base64])),
                  let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider),
                  let name = font.postScriptName as String? else { continue }
            CTFontManagerRegisterGraphicsFont(font, nil)
            out["\(css[family])-\(css[style])-\(css[weight])"] = name
        }
        return out
    }()

    static func text(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        let key = "KaTeX_Main-\(italic ? "italic" : "normal")-\(bold ? 700 : 400)"
        if let name = names[key], let font = UIFont(name: name, size: size) { return font }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let base = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) ?? UIFont.systemFont(ofSize: size).fontDescriptor
        return UIFont(descriptor: base.withSymbolicTraits(traits) ?? base, size: size)
    }

    static func code(_ size: CGFloat) -> UIFont {
        if let name = names["KaTeX_Typewriter-normal-400"], let font = UIFont(name: name, size: size) { return font }
        return .monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
    }

    /// Bold and italic versions of a reader font (for **strong** and *emphasis* runs).
    static func styled(_ font: UIFont, bold: Bool, italic: Bool) -> UIFont {
        let traits = font.fontDescriptor.symbolicTraits
        return text(font.pointSize, bold: bold || traits.contains(.traitBold), italic: italic || traits.contains(.traitItalic))
    }
}

/// A small Markdown reader: headings, paragraphs, emphasis, inline code, links, lists (nested),
/// block quotes, code blocks, rules, tables, and math ($…$, $$…$$, \[…\], equation environments)
/// typeset by KaTeX (see MathRenderer).
enum Markdown {
    /// 11 pt, like a paper.
    static let bodySize: CGFloat = 11
    /// Formula pictures come from KaTeX at this text size (14 px at 1.12em); they're scaled to the text around them.
    static let mathTextSize: CGFloat = 15.68
    /// Spacing was tuned at 15.5 pt; it scales with the text.
    private static let unit = bodySize / 15.5
    static let ink = UIColor(white: 0.07, alpha: 1)
    static let muted = UIColor(white: 0.42, alpha: 1)
    static let linkColor = UIColor(red: 0.10, green: 0.36, blue: 0.75, alpha: 1)

    static func plain(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: ink, .paragraphStyle: style,
        ])
    }

    /// Typeset formulas, by TeX source; formulas without a picture show their TeX.
    @TaskLocal static var math: [Formula: RenderedFormula] = [:]
    /// Set while only listing the formulas a file needs.
    @TaskLocal static var collector: FormulaCollector?

    static func render(_ source: String, math: [Formula: RenderedFormula]) -> NSAttributedString {
        $math.withValue(math) { render(source) }
    }

    /// The formulas in a Markdown file, in the order they appear.
    static func formulas(in source: String) -> [Formula] {
        let collector = FormulaCollector()
        $collector.withValue(collector) { _ = render(source) }
        return collector.items
    }

    static func render(_ source: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var paragraph: [String] = []
        var i = 0
        // Like LaTeX: a paragraph that follows another starts indented, with little space between them.
        var afterParagraph = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            let style = paragraphStyle(before: 0, after: 4)
            if afterParagraph { style.firstLineHeadIndent = 1.5 * bodySize }
            out.append(inline(text, font: ReaderFonts.text(bodySize), style: style))
            out.append(NSAttributedString(string: "\n"))
            paragraph = []
            afterParagraph = true
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Anything but a paragraph line or a blank line breaks the run of paragraphs.
            if !trimmed.isEmpty && !isPlainParagraphLine(lines, at: i) {
                flushParagraph()
                afterParagraph = false
            }

            // Displayed math: $$…$$, \[…\], or an equation/align environment.
            if let block = displayMath(lines, at: i) {
                flushParagraph()
                out.append(displayFormula(block.tex))
                i += block.lines
                continue
            }
            // Fenced code block.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                out.append(codeBlock(code.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }
            // Heading.
            if let level = headingLevel(trimmed) {
                flushParagraph()
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
                // LaTeX's \\section, \\subsection, … sizes, relative to the text.
                let scales: [CGFloat] = [1.6, 1.36, 1.17, 1, 1, 1]
                let style = paragraphStyle(before: level <= 2 ? 20 : 14, after: level <= 2 ? 9 : 6)
                style.alignment = .natural
                style.hyphenationFactor = 0
                out.append(inline(text, font: ReaderFonts.text(bodySize * scales[level - 1], bold: true, italic: level >= 5),
                                  style: style))
                out.append(NSAttributedString(string: "\n"))
                i += 1
                continue
            }
            // Horizontal rule.
            if isRule(trimmed) {
                flushParagraph()
                let style = paragraphStyle(before: 6, after: 6)
                style.alignment = .center
                out.append(NSAttributedString(string: String(repeating: "─", count: 30) + "\n",
                                              attributes: [.font: UIFont.systemFont(ofSize: bodySize * 0.65, weight: .ultraLight), .foregroundColor: muted,
                                                           .paragraphStyle: style]))
                i += 1
                continue
            }
            // Block quote (consecutive "> " lines).
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                // Like LaTeX's quote environment: indented on both sides.
                let style = paragraphStyle(before: 4, after: 8)
                style.firstLineHeadIndent = 2.5 * bodySize
                style.headIndent = 2.5 * bodySize
                style.tailIndent = -2.5 * bodySize
                out.append(inline(quote.joined(separator: " "), font: ReaderFonts.text(bodySize), style: style))
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            // Table: a header row, a separator row (---, :---:), then rows; outer pipes optional.
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = tableCells(line)
                let aligns = tableCells(lines[i + 1]).map { cell -> String in
                    let c = cell.trimmingCharacters(in: .whitespaces)
                    if c.hasPrefix(":") && c.hasSuffix(":") { return "center" }
                    return c.hasSuffix(":") ? "right" : "left"
                }
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(tableCells(row))
                    i += 1
                }
                out.append(typesetTable(header: header, aligns: aligns, rows: rows))
                continue
            }
            // List item (bullets or numbers), nested by indentation.
            if let item = listItem(line) {
                flushParagraph()
                var text = item.text
                i += 1
                // Lazy continuation lines belong to the item.
                while i < lines.count {
                    let next = lines[i]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.isEmpty || listItem(next) != nil || headingLevel(nextTrimmed) != nil
                        || nextTrimmed.hasPrefix("```") || nextTrimmed.hasPrefix("~~~") || nextTrimmed.hasPrefix(">")
                        || nextTrimmed.hasPrefix("|") || displayMath(lines, at: i) != nil
                        || (nextTrimmed.contains("|") && i + 1 < lines.count && isTableSeparator(lines[i + 1])) { break }
                    text += " " + nextTrimmed
                    i += 1
                }
                let indent = 1.6 * bodySize + CGFloat(item.level) * 1.6 * bodySize
                let style = paragraphStyle(before: 1, after: 3)
                style.firstLineHeadIndent = indent - 1.1 * bodySize
                style.headIndent = indent
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                out.append(NSAttributedString(string: item.marker + "\t",
                                              attributes: [.font: ReaderFonts.text(bodySize), .foregroundColor: ink,
                                                           .paragraphStyle: style]))
                out.append(inline(text, font: ReaderFonts.text(bodySize), style: style))
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return out
    }

    // MARK: Blocks

    /// A line that would join a paragraph (not a heading, list, table, quote, code, rule or displayed math).
    private static func isPlainParagraphLine(_ lines: [String], at i: Int) -> Bool {
        let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
        return displayMath(lines, at: i) == nil && !trimmed.hasPrefix("```") && !trimmed.hasPrefix("~~~")
            && headingLevel(trimmed) == nil && !isRule(trimmed) && !trimmed.hasPrefix(">")
            && !(trimmed.contains("|") && i + 1 < lines.count && isTableSeparator(lines[i + 1]))
            && listItem(lines[i]) == nil
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.count == hashes || line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func isRule(_ line: String) -> Bool {
        let chars = line.filter { !$0.isWhitespace }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (level: Int, marker: String, text: String)? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let level = min(leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2, 4)
        let rest = line.dropFirst(leading.count)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            var text = String(rest.dropFirst(2))
            var marker = level == 0 ? "•" : (level == 1 ? "–" : "∗")
            // Task lists.
            if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) }
            else if text.lowercased().hasPrefix("[x] ") { marker = "☑︎"; text.removeFirst(4) }
            return (level, marker, text)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " {
                return (level, "\(digits).", String(after.dropFirst(2)))
            }
        }
        return nil
    }

    private static func codeBlock(_ code: String) -> NSAttributedString {
        let style = paragraphStyle(before: 4, after: 8)
        style.lineSpacing = 2
        style.firstLineHeadIndent = 1.5 * bodySize
        style.headIndent = 1.5 * bodySize
        style.alignment = .natural
        style.hyphenationFactor = 0
        // One paragraph (line separators, not newlines), so its lines aren't spaced apart like paragraphs.
        let lines = code.replacingOccurrences(of: "\n", with: "\u{2028}")
        return NSAttributedString(string: lines + "\n", attributes: [
            .font: ReaderFonts.code(bodySize * 0.87),
            .foregroundColor: ink, .paragraphStyle: style,
        ])
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return c.count >= 1 && c.contains("-") && c.allSatisfy { "-:".contains($0) }
        }
    }

    /// A row's cells. Pipes inside `code`, a formula, or escaped as \| don't split cells. Formulas are found
    /// with the same rule as in text, so a price like "$5" doesn't swallow the rest of the row.
    private static func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var formulas: [String] = []
        var protected = ""
        for part in splitMath(text) {
            if let tex = part.tex {
                protected += "\u{E030}\(formulas.count)\u{E031}"
                formulas.append(tex)
            } else {
                protected += part.text
            }
        }
        // Put each formula back as written (inline $…$), now that pipes inside it can't split the row.
        func restore(_ cell: String) -> String {
            var cell = cell
            for (i, tex) in formulas.enumerated() { cell = cell.replacingOccurrences(of: "\u{E030}\(i)\u{E031}", with: "$\(tex.trimmingCharacters(in: .whitespaces))$") }
            return cell
        }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var previous: Character = " "
        for ch in protected {
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode {
                if previous == "\\" {
                    current.removeLast()
                    current.append("|")
                } else {
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            } else {
                current.append(ch)
            }
            previous = ch
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map(restore)
    }

    /// A table typeset as a picture (formatting and math inside cells work); plain aligned text if that fails.
    private static func typesetTable(header: [String], aligns: [String], rows: [[String]]) -> NSAttributedString {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        func cells(_ row: [String], tag: String) -> String {
            (0..<columns).map { c in
                let align = c < aligns.count ? aligns[c] : "left"
                let text = c < row.count ? cellHTML(row[c]) : ""
                return "<\(tag) style=\"text-align:\(align)\">\(text)</\(tag)>"
            }.joined()
        }
        let html = "<table><thead><tr>\(cells(header, tag: "th"))</tr></thead><tbody>"
            + rows.map { "<tr>\(cells($0, tag: "td"))</tr>" }.joined() + "</tbody></table>"
        let key = Formula(tex: html, display: true, html: true)
        collector?.items.append(key)
        guard let picture = math[key] else { return table([header] + rows) }
        var scale: CGFloat = 1
        let widest = Reader.pageSize.width - 2 * Reader.margin
        if picture.size.width > widest { scale = widest / picture.size.width }
        // Cut the picture between rows, one strip per line, so a table longer than a page continues on the next.
        var cuts = picture.rowEnds.filter { $0 > 0 && $0 < picture.size.height - 1 }
        cuts.append(picture.size.height)
        let out = NSMutableAttributedString()
        var top: CGFloat = 0
        for (index, bottom) in cuts.enumerated() where bottom > top {
            guard let strip = slice(picture.image, from: top, to: bottom, height: picture.size.height) else { continue }
            let attachment = NSTextAttachment()
            attachment.image = strip
            let rowScale = min(scale, Reader.tallest / (bottom - top))   // a single row taller than a page shrinks
            attachment.bounds = CGRect(x: 0, y: 0, width: picture.size.width * rowScale, height: (bottom - top) * rowScale)
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = index == 0 ? 4 * unit : 0
            style.paragraphSpacing = index == cuts.count - 1 ? 10 * unit : 0
            let line = NSMutableAttributedString(attachment: attachment)
            line.append(NSAttributedString(string: "\n"))
            // A tiny font, so lines are exactly as tall as their strip and the rows join up seamlessly.
            line.addAttributes([.paragraphStyle: style, .font: UIFont.systemFont(ofSize: 1)],
                               range: NSRange(location: 0, length: line.length))
            out.append(line)
            top = bottom
        }
        return out
    }

    /// Part of a picture between two heights (in points of a picture `height` points tall).
    private static func slice(_ image: UIImage, from top: CGFloat, to bottom: CGFloat, height: CGFloat) -> UIImage? {
        guard let cg = image.cgImage, height > 0 else { return nil }
        let pixels = CGFloat(cg.height) / height
        let rect = CGRect(x: 0, y: (top * pixels).rounded(), width: CGFloat(cg.width),
                          height: ((bottom - top) * pixels).rounded())
        guard let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    /// A cell's Markdown as HTML: bold, italic, code, links, and $math$ (typeset by KaTeX in the page).
    private static func cellHTML(_ markdown: String) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func replace(_ pattern: String, _ template: String, in text: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
            return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        // Code spans first, so nothing inside them is read as math or emphasis.
        var codes: [String] = []
        var source = markdown
        if let codeSpan = try? NSRegularExpression(pattern: "`([^`]+)`") {
            for match in codeSpan.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
                guard let whole = Range(match.range, in: source), let inner = Range(match.range(at: 1), in: source) else { continue }
                codes.append(String(source[inner]))
                source.replaceSubrange(whole, with: "\u{E010}\(codes.count - 1)\u{E011}")
            }
        }
        var html = ""
        for part in splitMath(source) {
            if let tex = part.tex {
                html += "<span class=\"mi\" data-tex=\"\(escape(tex))\"></span>"
                continue
            }
            var text = escape(part.text.replacingOccurrences(of: "\\$", with: "$"))
            text = replace("\\*\\*(.+?)\\*\\*", "<b>$1</b>", in: text)
            text = replace("__(.+?)__", "<b>$1</b>", in: text)
            text = replace("(?<![\\w*])\\*(?!\\s)(.+?)(?<!\\s)\\*", "<i>$1</i>", in: text)
            text = replace("(?<!\\w)_(?!\\s)(.+?)(?<!\\s)_(?!\\w)", "<i>$1</i>", in: text)
            text = replace("~~(.+?)~~", "<s>$1</s>", in: text)
            text = replace("\\[([^\\]]+)\\]\\(([^)]+)\\)", "<a>$1</a>", in: text)
            html += text
        }
        for (index, code) in codes.enumerated() {
            html = html.replacingOccurrences(of: "\u{E010}\(index)\u{E011}", with: "<code>\(escape(code))</code>")
        }
        return html
    }

    private static func table(_ rows: [[String]]) -> NSAttributedString {
        let columns = rows.map(\.count).max() ?? 0
        var widths = Array(repeating: 0, count: columns)
        for row in rows { for (c, cell) in row.enumerated() { widths[c] = max(widths[c], cell.count) } }
        let text = rows.enumerated().map { r, row in
            (0..<columns).map { c in
                let cell = c < row.count ? row[c] : ""
                return cell.padding(toLength: widths[c], withPad: " ", startingAt: 0)
            }.joined(separator: "  │  ")
        }.joined(separator: "\u{2028}")
        let style = paragraphStyle(before: 4, after: 8)
        style.alignment = .natural
        style.hyphenationFactor = 0
        let out = NSMutableAttributedString(string: text + "\n", attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: bodySize * 0.8, weight: .regular), .foregroundColor: ink, .paragraphStyle: style,
        ])
        // Header row in bold.
        if let firstBreak = text.firstIndex(of: "\u{2028}") {
            let length = text.distance(from: text.startIndex, to: firstBreak)
            out.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: bodySize * 0.8, weight: .semibold),
                             range: NSRange(location: 0, length: length))
        }
        return out
    }

    private static func paragraphStyle(before: CGFloat = 0, after: CGFloat = 9) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.5 * unit
        style.alignment = .justified
        style.hyphenationFactor = 0.9
        style.paragraphSpacingBefore = before * unit
        style.paragraphSpacing = after * unit
        return style
    }

    // MARK: Math

    private static let environments = ["equation", "equation*", "align", "align*", "aligned", "gather", "gather*",
                                       "multline", "multline*", "eqnarray", "eqnarray*", "split", "cases", "array"]

    /// A displayed formula starting at line `start`, and how many lines it takes.
    private static func displayMath(_ lines: [String], at start: Int) -> (tex: String, lines: Int)? {
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        func collect(open: String, close: String, keepDelimiters: Bool) -> (String, Int)? {
            var body = String(first.dropFirst(open.count))
            if let end = body.range(of: close) {
                // All on one line; only a whole-line formula counts as displayed.
                guard body[end.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                body = String(body[..<end.lowerBound])
                return (keepDelimiters ? open + body + close : body, 1)
            }
            var parts = [body]
            var j = start + 1
            while j < lines.count {
                if let end = lines[j].range(of: close) {
                    parts.append(String(lines[j][..<end.lowerBound]))
                    let tex = parts.joined(separator: "\n")
                    return (keepDelimiters ? open + tex + close : tex, j - start + 1)
                }
                parts.append(lines[j])
                j += 1
            }
            return nil
        }
        if first.hasPrefix("$$") { return collect(open: "$$", close: "$$", keepDelimiters: false) }
        if first.hasPrefix("\\[") { return collect(open: "\\[", close: "\\]", keepDelimiters: false) }
        if first.hasPrefix("\\begin{"), let name = first.dropFirst(7).split(separator: "}").first.map(String.init),
           environments.contains(name) {
            return collect(open: "\\begin{\(name)}", close: "\\end{\(name)}", keepDelimiters: true)
        }
        return nil
    }

    private static func displayFormula(_ tex: String) -> NSAttributedString {
        let style = paragraphStyle(before: 4, after: 10)
        style.alignment = .center
        let out = NSMutableAttributedString(attributedString: formula(tex, display: true, font: ReaderFonts.text(bodySize)))
        out.append(NSAttributedString(string: "\n"))
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// A formula's picture, sized to the text around it (or its TeX if it couldn't be typeset).
    private static func formula(_ tex: String, display: Bool, font: UIFont) -> NSAttributedString {
        let key = Formula(tex: tex.trimmingCharacters(in: .whitespacesAndNewlines), display: display)
        collector?.items.append(key)
        guard let picture = math[key] else {
            let shown = display ? key.tex : "$\(key.tex)$"
            return NSAttributedString(string: shown, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.85, weight: .regular), .foregroundColor: muted,
            ])
        }
        var scale = (display ? bodySize : font.pointSize) / mathTextSize
        let widest = Reader.pageSize.width - 2 * Reader.margin
        if picture.size.width * scale > widest { scale = widest / picture.size.width }
        if picture.size.height * scale > Reader.tallest { scale = Reader.tallest / picture.size.height }
        let attachment = NSTextAttachment()
        attachment.image = picture.image
        attachment.bounds = CGRect(x: 0, y: -picture.descent * scale,
                                   width: picture.size.width * scale, height: picture.size.height * scale)
        return NSAttributedString(attachment: attachment)
    }

    /// Inline math, $…$ or \(…\), outside `code`. A $ must hug its formula ("$x$", not "$5 and $10").
    /// (An escaped \\$ is set aside first, so it never starts or ends a formula.)
    private static let inlineMath = #/\$\$(.+?)\$\$|\$(?!\$)(?=\S)([^$\n]*?[^\s\\])\$(?!\d)|\\\((.+?)\\\)/#

    /// Splits text into plain parts and inline formulas (code spans are left alone).
    private static func splitMath(_ input: String) -> [(text: String, tex: String?)] {
        let escaped = "\u{E002}"
        let text = input.replacingOccurrences(of: "\\$", with: escaped)
        func restore(_ part: (String, String?)) -> (text: String, tex: String?) {
            (part.0.replacingOccurrences(of: escaped, with: "\\$"), part.1?.replacingOccurrences(of: escaped, with: "\\$"))
        }
        var out: [(String, String?)] = []
        for (index, segment) in text.components(separatedBy: "`").enumerated() {
            let prefix = index == 0 ? "" : "`"
            guard index % 2 == 0 else {
                out.append((prefix + segment, nil))
                continue
            }
            var rest = Substring(segment)
            var first = true
            while let match = rest.firstMatch(of: inlineMath) {
                out.append(((first ? prefix : "") + String(rest[..<match.range.lowerBound]), nil))
                first = false
                // $$…$$ inside a line is set in display style, in the line.
                let tex = match.output.1.map { "\\displaystyle " + $0 } ?? match.output.2.map(String.init)
                    ?? match.output.3.map(String.init) ?? ""
                out.append(("", tex))
                rest = rest[match.range.upperBound...]
            }
            out.append(((first ? prefix : "") + String(rest), nil))
        }
        return out.map(restore)
    }

    // MARK: Inline

    /// Emphasis, strong, code, strikethrough, links and inline math. Formulas are swapped for
    /// placeholders while Foundation's Markdown parser reads the rest, then put back as pictures.
    private static func inline(_ text: String, font: UIFont, style: NSParagraphStyle,
                               color: UIColor = ink) -> NSAttributedString {
        var formulas: [String] = []
        var protected = ""
        for part in splitMath(text) {
            if let tex = part.tex {
                protected += "\u{E000}\(formulas.count)\u{E001}"
                formulas.append(tex)
            } else {
                protected += part.text
            }
        }
        let built = inlineText(protected, font: font, style: style, color: color)
        guard !formulas.isEmpty else { return built }
        let out = NSMutableAttributedString(attributedString: built)
        let placeholders = try? NSRegularExpression(pattern: "\u{E000}(\\d+)\u{E001}")
        for match in (placeholders?.matches(in: out.string, range: NSRange(location: 0, length: out.length)) ?? []).reversed() {
            guard let number = Int((out.string as NSString).substring(with: match.range(at: 1))),
                  formulas.indices.contains(number) else { continue }
            let picture = NSMutableAttributedString(attributedString: formula(formulas[number], display: false, font: font))
            picture.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: picture.length))
            out.replaceCharacters(in: match.range, with: picture)
        }
        return out
    }

    private static func inlineText(_ text: String, font: UIFont, style: NSParagraphStyle,
                                   color: UIColor) -> NSAttributedString {
        // Images aren't loaded; their alt text stands in.
        let cleaned = text.replacing(#/!\[([^\]]*)\]\([^)]*\)/#) { "[image: \($0.output.1)]" }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: cleaned, options: options) else {
            return NSAttributedString(string: cleaned, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: style]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) || intent.contains(.emphasized) {
                    runFont = ReaderFonts.styled(font, bold: intent.contains(.stronglyEmphasized),
                                                 italic: intent.contains(.emphasized))
                }
                if intent.contains(.code) {
                    runFont = ReaderFonts.code(font.pointSize * 0.95)
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link {
                attributes[Reader.linkKey] = link   // not .link, which TextKit underlines
                attributes[.foregroundColor] = linkColor
            }
            attributes[.font] = runFont
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }
}

/// Collects formulas during a dry run of the Markdown reader.
final class FormulaCollector: @unchecked Sendable {
    var items: [Formula] = []
}
