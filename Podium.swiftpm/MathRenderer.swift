import UIKit
import WebKit

/// One formula from a Markdown file: `$…$`, `\(…\)` inline; `$$…$$`, `\[…\]`, `\begin{…}…\end{…}` displayed.
struct Formula: Hashable, Sendable {
    let tex: String
    let display: Bool
    /// `tex` is HTML (a table, with math inside it) rather than one formula.
    var html: Bool = false
}

/// A formula drawn as a picture, sized for 14 pt text.
struct RenderedFormula: @unchecked Sendable {
    let image: UIImage
    /// Size in points at the base text size.
    let size: CGSize
    /// How far it reaches below the baseline (so inline math sits on the line like text).
    let descent: CGFloat
    /// Tables: where each row ends, in points from the top, so a long table can break across pages.
    var rowEnds: [CGFloat] = []
}

/// Typesets TeX math with KaTeX (bundled, works offline) in a hidden web view and takes a picture of
/// each formula, which the Markdown reader then places in the text like a character.
@MainActor
enum MathRenderer {
    static let baseSize: CGFloat = 14
    /// Pictures are taken at this many times their size, so they stay sharp when zoomed or projected.
    static let sharpness: CGFloat = 3
    private static var cache: [Formula: RenderedFormula] = [:]

    static func render(_ formulas: [Formula]) async -> [Formula: RenderedFormula] {
        let missing = Array(Set(formulas.filter { cache[$0] == nil }))
        if !missing.isEmpty, let rendered = await typeset(missing) {
            for (formula, picture) in rendered { cache[formula] = picture }
        }
        var out: [Formula: RenderedFormula] = [:]
        for formula in formulas { out[formula] = cache[formula] }
        return out
    }

    private static func typeset(_ formulas: [Formula]) async -> [Formula: RenderedFormula]? {
        // The web view lays out in a window, underneath everything else (it's never seen).
        guard let window = UIApplication.mainWindow else { return nil }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2400, height: 800))
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.isUserInteractionEnabled = false
        window.insertSubview(webView, at: 0)
        defer { webView.removeFromSuperview() }

        let loader = Loader()
        webView.navigationDelegate = loader
        webView.loadHTMLString(page(for: formulas), baseURL: nil)
        // Never wait forever: if the page doesn't load, the file opens with formulas shown as TeX.
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            loader.give(up: true)
        }
        defer { timeout.cancel() }
        guard await loader.finished() else { return nil }

        // Wait for the fonts, then measure each formula and where its baseline is.
        let script = """
        // Fonts load when first used; ask for each one KaTeX uses, then wait for two paints.
        const families = new Set();
        document.querySelectorAll('.katex *, .tbl *').forEach(el => families.add(getComputedStyle(el).fontFamily.split(',')[0].trim()));
        await Promise.all([...families].map(f => document.fonts.load('16px ' + f).catch(() => null)));
        await Promise.race([document.fonts.ready, new Promise(r => setTimeout(r, 4000))]);
        await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
        await new Promise(r => setTimeout(r, 400));
        const out = [];
        const ends = [];
        for (let i = 0; i < count; i++) {
            const box = document.getElementById('k' + i).getBoundingClientRect();
            const base = document.getElementById('b' + i).getBoundingClientRect();
            out.push([box.left, box.top, box.width, box.height, base.bottom]);
            ends.push([...document.getElementById('k' + i).querySelectorAll('tr')]
                .map(tr => tr.getBoundingClientRect().bottom - box.top));
        }
        return JSON.stringify({ rects: out, ends: ends, height: document.body.scrollHeight });
        """
        guard let json = try? await webView.callAsyncJavaScript(script, arguments: ["count": formulas.count],
                                                                 contentWorld: .page) as? String,
              let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let rects = parsed["rects"] as? [[Double]],
              let ends = parsed["ends"] as? [[Double]],
              let height = parsed["height"] as? Double else { return nil }
        webView.frame.size.height = CGFloat(height) + 40

        var out: [Formula: RenderedFormula] = [:]
        for (index, formula) in formulas.enumerated() where index < rects.count {
            let r = rects[index]
            let rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).insetBy(dx: -1, dy: -1).integral
            guard rect.width > 1, rect.height > 1 else { continue }
            // WebKit's PDF export draws the formula as vectors (a plain snapshot can miss web-font glyphs on iOS);
            // it's then drawn into a sharp picture.
            let configuration = WKPDFConfiguration()
            configuration.rect = rect
            guard let pdf = try? await webView.pdf(configuration: configuration),
                  let image = Self.picture(fromPDF: pdf, size: rect.size) else { continue }
            let descent = max(0, rect.maxY - CGFloat(r[4]))
            let top = CGFloat(r[1]) - rect.minY
            let rowEnds = index < ends.count ? ends[index].map { CGFloat($0) + top } : []
            out[formula] = RenderedFormula(image: image, size: rect.size, descent: descent, rowEnds: rowEnds)
        }
        return out
    }

    private static func picture(fromPDF data: Data, size: CGSize) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = sharpness * 2
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: size.width / max(box.width, 1), y: -size.height / max(box.height, 1))
            cg.translateBy(x: -box.minX, y: -box.minY)
            cg.drawPDFPage(page)
        }
    }

    /// Every formula on its own line, with a zero-height marker after it that sits on the baseline.
    private static func page(for formulas: [Formula]) -> String {
        let items = formulas.map { ["t": $0.tex, "d": $0.display, "h": $0.html] as [String: Any] }
        let data = (try? JSONSerialization.data(withJSONObject: items)) ?? Data("[]".utf8)
        let list = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
        let boxes = formulas.indices.map {
            "<div class=\"f\"><span class=\"k\" id=\"k\($0)\"></span><span class=\"b\" id=\"b\($0)\"></span></div>"
        }.joined()
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>\(KaTeXAssets.style)</style>
        <style>
        html, body { margin: 0; background: transparent; }
        body { padding: 24px; font-size: \(baseSize)px; color: #121212; font-family: -apple-system; }
        .f { margin: 0 0 36px 0; white-space: nowrap; }
        .k { display: inline-block; }
        .k .katex { font-size: 1.12em; }
        .k .katex-display { margin: 0; }
        .tbl { white-space: normal; }
        .tbl table { border-collapse: collapse; max-width: \(Int(Reader.pageSize.width - 2 * Reader.margin))px;
                     font-family: KaTeX_Main, 'Times New Roman', serif; color: #121212;
                     font-size: \(Markdown.bodySize)px; line-height: 1.3; }
        /* Ruled like LaTeX's booktabs: thick rules at top and bottom, a thin one under the header. */
        .tbl th, .tbl td { padding: 3px 7px; vertical-align: top; }
        .tbl th { font-weight: 700; border-top: 1px solid #121212; border-bottom: 0.6px solid #121212; }
        .tbl tbody tr:last-child td { border-bottom: 1px solid #121212; }
        .tbl code { font-family: KaTeX_Typewriter, Menlo, monospace; font-size: 0.95em; overflow-wrap: anywhere; hyphens: manual; -webkit-hyphens: manual; }
        /* Long words hyphenate and file names may break, so no column is squeezed to a word per line. */
        .tbl td, .tbl th { hyphens: auto; -webkit-hyphens: auto; }
        .tbl a { color: #1a5cbf; text-decoration: none; }
        .tbl .katex { white-space: nowrap; font-size: 1em; }
        .b { display: inline-block; width: 1px; height: 0; }
        .err { font-family: Menlo, monospace; color: #b00; font-size: 12px; }
        </style></head><body>\(boxes)
        <script>\(KaTeXAssets.script)</script>
        <script>
        const items = \(list);
        items.forEach((item, i) => {
            const el = document.getElementById('k' + i);
            if (item.h) {
                // A table: its HTML, then each formula inside it.
                el.className = 'k tbl';
                el.innerHTML = item.t;
                el.querySelectorAll('.mi').forEach(m => {
                    try { katex.render(m.dataset.tex, m, { throwOnError: false, strict: false }); }
                    catch (e) { m.textContent = m.dataset.tex; }
                });
                return;
            }
            try { katex.render(item.t, el, { displayMode: item.d, throwOnError: false, strict: false, trust: false }); }
            catch (e) { el.className = 'k err'; el.textContent = item.t; }
        });
        </script></body></html>
        """
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        func finished() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }

        func give(up: Bool) { finish(false) }

        private func finish(_ ok: Bool) {
            guard result == nil else { return }
            result = ok
            continuation?.resume(returning: ok)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(false) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(false)
        }
        // No links or network: the page only ever shows the formulas.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}
