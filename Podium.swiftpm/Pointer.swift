import SwiftUI
import Observation

struct PointerSample {
    var point: CGPoint             // unit coordinates (0...1) on the page
    var time: TimeInterval
}

struct PointerStroke {
    var samples: [PointerSample]
    var ended: TimeInterval?
    var isHover: Bool
}

/// Pointer motion shared by the presenter and audience screens.
@MainActor @Observable
final class PointerState {
    var strokes: [PointerStroke] = []

    /// How long the trail's tail lingers, in seconds. Adjustable in the pointer controls.
    var trailLife: TimeInterval = UserDefaults.standard.object(forKey: "pointer.trailLife") as? Double ?? 0.9 {
        didSet { UserDefaults.standard.set(trailLife, forKey: "pointer.trailLife") }
    }
    static let trailRange: ClosedRange<TimeInterval> = 0.3...2.0
    nonisolated static let highlightHold: TimeInterval = 1.5
    nonisolated static let highlightFade: TimeInterval = 0.6

    private var now: TimeInterval { Date().timeIntervalSinceReferenceDate }

    func begin(_ point: CGPoint, hover: Bool) {
        prune()
        strokes.append(PointerStroke(samples: [PointerSample(point: point, time: now)], ended: nil, isHover: hover))
    }

    func move(_ point: CGPoint) {
        guard let last = strokes.indices.last, strokes[last].ended == nil else { return }
        strokes[last].samples.append(PointerSample(point: point, time: now))
        if strokes[last].samples.count > 4000 {
            strokes[last].samples.removeFirst(1000)
        }
    }

    func end() {
        guard let last = strokes.indices.last, strokes[last].ended == nil else { return }
        strokes[last].ended = now
        // Let the fade play out, then drop finished strokes so the animation can pause.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(PointerState.highlightHold + PointerState.highlightFade,
                                                    self?.trailLife ?? 0) + 0.2))
            self?.prune()
        }
    }

    /// Drops the active stroke, used when a quick finger tap turns out to be "next slide".
    func discardActive() {
        if let last = strokes.indices.last, strokes[last].ended == nil {
            strokes.removeLast()
        }
    }

    func reset() {
        strokes.removeAll()
    }

    private func prune() {
        let cutoff = now - max(Self.highlightHold + Self.highlightFade, trailLife)
        strokes.removeAll { stroke in
            guard let ended = stroke.ended else { return false }
            return ended < cutoff
        }
    }
}

/// Draws the pointer in one of three styles: a laser dot, a dot with a fading tail,
/// or a translucent marker stroke that fades away shortly after you lift.
struct PointerLayer: View {
    let doc: DocumentState
    /// In continuous scrolling, the page this layer sits on; it draws only if the pointer is there.
    var page: Int? = nil

    var body: some View {
        let state = PresentationState.shared
        let pointer = doc.pointer
        let onThisPage = page == nil || doc.pointerPage == page
        let style = state.pointerStyle
        let color = Color(uiColor: state.pointerColor)
        let strokes = onThisPage ? pointer.strokes : []
        let trailLife = pointer.trailLife

        TimelineView(.animation(minimumInterval: nil, paused: strokes.isEmpty)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                PointerRenderer(context: context, size: size, color: color, now: now, trailLife: trailLife)
                    .draw(strokes, style: style)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct PointerRenderer {
    var context: GraphicsContext
    let size: CGSize
    let color: Color
    let now: TimeInterval
    let trailLife: TimeInterval

    private var radius: CGFloat { size.width * 0.009 }

    private func place(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    func draw(_ strokes: [PointerStroke], style: PointerStyle) {
        switch style {
        case .dot:
            if let last = strokes.last { drawHead(of: last) }
        case .trail:
            if let last = strokes.last {
                drawTrail(of: last)
                drawHead(of: last)
            }
        case .highlight:
            for stroke in strokes where !stroke.isHover {
                drawHighlight(stroke)
            }
            if let last = strokes.last { drawHead(of: last) }
        }
    }

    private func headOpacity(_ stroke: PointerStroke) -> Double {
        guard let ended = stroke.ended else { return 1 }
        return max(0, 1 - (now - ended) / 0.25)
    }

    private func drawHead(of stroke: PointerStroke) {
        let opacity = headOpacity(stroke)
        guard opacity > 0, let sample = stroke.samples.last else { return }
        let c = place(sample.point)
        func circle(_ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        context.fill(circle(radius * 2.4), with: .color(color.opacity(0.22 * opacity)))
        context.fill(circle(radius * 1.5), with: .color(color.opacity(0.35 * opacity)))
        context.fill(circle(radius), with: .color(color.opacity(opacity)))
        context.fill(circle(radius * 0.35), with: .color(.white.opacity(0.85 * opacity)))
    }

    private func drawTrail(of stroke: PointerStroke) {
        let recent = stroke.samples.filter { now - $0.time < trailLife }
        guard recent.count > 1 else { return }
        for (a, b) in zip(recent, recent.dropFirst()) {
            let freshness = max(0, 1 - (now - b.time) / trailLife)
            var segment = Path()
            segment.move(to: place(a.point))
            segment.addLine(to: place(b.point))
            context.stroke(segment, with: .color(color.opacity(0.75 * freshness)),
                           style: StrokeStyle(lineWidth: radius * 1.8 * freshness, lineCap: .round))
        }
    }

    private func drawHighlight(_ stroke: PointerStroke) {
        var opacity = 1.0
        if let ended = stroke.ended {
            let age = now - ended - PointerState.highlightHold
            opacity = min(1, max(0, 1 - age / PointerState.highlightFade))
        }
        guard opacity > 0, let first = stroke.samples.first else { return }
        var path = Path()
        path.move(to: place(first.point))
        for sample in stroke.samples.dropFirst() {
            path.addLine(to: place(sample.point))
        }
        context.stroke(path, with: .color(color.opacity(0.32 * opacity)),
                       style: StrokeStyle(lineWidth: size.width * 0.03, lineCap: .round, lineJoin: .round))
    }
}
