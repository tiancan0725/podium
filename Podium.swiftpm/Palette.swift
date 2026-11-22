import UIKit

struct Palette: Identifiable {
    let id: String
    let name: String
    let inks: [UIColor]
    let highlighters: [UIColor]
    let pointer: UIColor

    static let builtIn: [Palette] = [
        // Black and grey, then a rainbow: Penn red, Claude orange, ochre, forest green, Carolina blue,
        // Penn blue, Northwestern purple.
        Palette(id: "podium", name: "Podium",
                inks: ["#111111", "#808080", "#990000", "#D97757", "#D4A72C", "#23744B", "#4B9CD3", "#011F5B", "#4E2A84"],
                highlighters: ["#FFE066", "#8FD3FE", "#B8F2B0", "#FFB3C6"],
                pointer: "#FF3B30"),
        Palette(id: "chalk", name: "Chalk",
                inks: ["#1F2430", "#D1495B", "#2E86AB", "#3A9D5D", "#E8A33D", "#7B5EA7"],
                highlighters: ["#FFE066", "#8FD3FE", "#B8F2B0", "#FFB3C6"],
                pointer: "#FF3B30"),
        Palette(id: "nord", name: "Muted",
                inks: ["#2E3440", "#BF616A", "#5E81AC", "#6E9E5A", "#D08770", "#B48EAD"],
                highlighters: ["#EBCB8B", "#88C0D0", "#A3BE8C", "#E5B6C8"],
                pointer: "#BF616A"),
        Palette(id: "vivid", name: "Vivid",
                inks: ["#000000", "#E63946", "#1D4ED8", "#059669", "#F59E0B", "#9333EA"],
                highlighters: ["#FDE047", "#67E8F9", "#86EFAC", "#F9A8D4"],
                pointer: "#E63946"),
        Palette(id: "dark", name: "For dark slides",
                inks: ["#F8F9FA", "#FF8FA3", "#7CC6FE", "#9EF01A", "#FFD166", "#CDB4DB"],
                highlighters: ["#FFD166", "#7CC6FE", "#9EF01A", "#FF8FA3"],
                pointer: "#FFD166"),
    ]

    init(id: String, name: String, inks: [UIColor], highlighters: [UIColor], pointer: UIColor) {
        self.id = id
        self.name = name
        self.inks = inks
        self.highlighters = highlighters
        self.pointer = pointer
    }

    init(id: String, name: String, inks: [String], highlighters: [String], pointer: String) {
        self.init(id: id, name: name,
                  inks: inks.map(UIColor.init(hex:)),
                  highlighters: highlighters.map(UIColor.init(hex:)),
                  pointer: UIColor(hex: pointer))
    }
}

extension UIColor {
    convenience init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    convenience init(h: CGFloat, s: CGFloat, v: CGFloat) {
        self.init(hue: h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: v, alpha: 1)
    }
}

/// Builds a palette that matches a deck: samples the title slide and a middle slide,
/// finds the theme's dominant accent hues, and derives readable inks, highlighters
/// and a pointer colour from them.
enum SlideTheme {
    @MainActor
    static func palette(for deck: Deck) -> Palette? {
        // Title slide plus a few slides spread through the talk.
        let samplePages = Set([0, deck.pageCount / 4, deck.pageCount / 2, 3 * deck.pageCount / 4]).sorted()

        let binCount = 24
        var weights = [Double](repeating: 0, count: binCount)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: binCount)
        var luminance = 0.0
        var pixels = 0.0

        for page in samplePages {
            guard let image = deck.image(page: page, width: 192, scale: 1)?.cgImage else { continue }
            let w = image.width, h = image.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            data.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: w, height: h,
                                              bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return }
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            for i in stride(from: 0, to: data.count, by: 4) {
                let r = Double(data[i]) / 255, g = Double(data[i + 1]) / 255, b = Double(data[i + 2]) / 255
                luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b
                pixels += 1
                let (hue, sat, val) = hsv(r, g, b)
                guard sat > 0.35, val > 0.3 else { continue }
                let bin = min(binCount - 1, Int(hue * Double(binCount)))
                let weight = sat * val
                weights[bin] += weight
                sums[bin].r += r * weight
                sums[bin].g += g * weight
                sums[bin].b += b * weight
            }
        }
        guard pixels > 0 else { return nil }
        let isDark = luminance / pixels < 0.4

        // Pick up to three accent colours that are far enough apart to read as different.
        // Accents are usually thin (titles, rules, bullets), so the bar is low.
        var accents: [(hue: Double, color: UIColor)] = []
        let ranked = weights.indices.sorted { weights[$0] > weights[$1] }
        let topWeight = weights[ranked[0]]
        for bin in ranked where weights[bin] > pixels * 0.0005 && weights[bin] > topWeight * 0.15 {
            let r = sums[bin].r / weights[bin], g = sums[bin].g / weights[bin], b = sums[bin].b / weights[bin]
            let (hue, sat, val) = hsv(r, g, b)
            let farEnough = accents.allSatisfy { a in
                let d = abs(a.hue - hue)
                return min(d, 1 - d) > 0.11
            }
            guard farEnough else { continue }
            // Keep the theme's exact colour, only nudging brightness so it reads as ink.
            let v = isDark ? max(val, 0.8) : min(max(val, 0.35), 0.75)
            accents.append((hue, UIColor(h: hue, s: max(sat, 0.5), v: v)))
            if accents.count == 3 { break }
        }
        guard let primary = accents.first?.hue else { return nil }

        // Fill out the palette with hues that complement the theme.
        var extraHues: [Double] = []
        for offset in [0.5, 0.58, 0.33] where accents.count + extraHues.count < 5 {
            extraHues.append((primary + offset).truncatingRemainder(dividingBy: 1))
        }
        let inkS: CGFloat = isDark ? 0.5 : 0.65
        let inkV: CGFloat = isDark ? 0.95 : 0.7
        let base = UIColor(hex: isDark ? "#F5F5F5" : "#1F2430")
        let inks = [base] + accents.map { $0.color } + extraHues.map { UIColor(h: $0, s: inkS, v: inkV) }

        let allHues = accents.map { $0.hue } + extraHues
        let highlighters = allHues.prefix(4).map { UIColor(h: $0, s: isDark ? 0.6 : 0.4, v: isDark ? 0.9 : 1) }
        let pointer = UIColor(h: primary, s: 0.95, v: isDark ? 1 : 0.95)

        return Palette(id: "slides", name: "From these slides",
                       inks: inks, highlighters: highlighters, pointer: pointer)
    }

    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maxC == 0 ? 0 : delta / maxC, maxC)
    }
}
