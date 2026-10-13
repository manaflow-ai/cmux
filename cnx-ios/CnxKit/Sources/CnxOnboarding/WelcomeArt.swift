#if os(iOS)
import CnxDesign
import SwiftUI

private let theme = CnxTheme.standard

/// Easing helpers for the welcome intro. Every value is a pure function of the
/// time since the intro started, so the intro is one clock and never drifts.
enum IntroEase {
    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    /// Linear progress of `t` through the window `a...b`, clamped to 0...1.
    static func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
    static func inOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func out(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func outQuint(_ x: Double) -> Double { 1 - pow(1 - x, 5) }
    static func inCubic(_ x: Double) -> Double { x * x * x }
    static func outBack(_ x: Double, overshoot s: Double = 1.6) -> Double {
        let c3 = s + 1
        return 1 + c3 * pow(x - 1, 3) + s * pow(x - 1, 2)
    }
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ x: Double) -> CGFloat { a + (b - a) * CGFloat(x) }
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ x: Double) -> CGPoint {
        CGPoint(x: lerp(a.x, b.x, x), y: lerp(a.y, b.y, x))
    }
}

/// The welcome illustration (SPEC 5.2): a Mac and an iPhone drawn as one white
/// line, a prompt on the Mac, a network of nodes that grows from the prompt to
/// the phone, then folds into the cmux chevron on the phone's screen.
/// `t` is seconds since the intro started (`.infinity` = settled);
/// `pulse` is seconds into an idle sync pulse, or nil.
struct WelcomeArt: View {
    var t: Double
    var pulse: Double?

    /// The drawing's own box, and how much it is scaled up on screen.
    static let size = CGSize(width: 260, height: 208)
    static let scale: CGFloat = 1.12
    /// When the intro's last element settles.
    static let introDuration: Double = 5.2
    static let pulseDuration: Double = 1.9

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: Self.scale, y: Self.scale)
            // Room above for the highest branch node.
            context.translateBy(x: 0, y: 8)
            draw(in: &context)
        }
        .frame(width: Self.size.width * Self.scale, height: Self.size.height * Self.scale)
            .accessibilityHidden(true)
    }

    // MARK: Geometry (260 x 200 drawing, drawn 8 pt down in the box)

    private static let lineWidth: CGFloat = 3.3
    private static let screen = CGRect(x: 18, y: 50, width: 140, height: 94)
    private static let phone = CGRect(x: 192, y: 54, width: 54, height: 104)
    private static var phoneCenter: CGPoint { CGPoint(x: phone.midX, y: phone.midY + 2) }

    /// A rounded rectangle traced clockwise from the middle of its top edge, so
    /// a trimmed stroke draws it like a pen would.
    private static func roundRect(_ r: CGRect, radius: CGFloat, into path: inout Path) {
        path.move(to: CGPoint(x: r.midX, y: r.minY))
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.midX, y: r.minY), radius: radius)
        path.closeSubpath()
    }

    private static let mac: Path = {
        var p = Path()
        roundRect(screen, radius: 10, into: &p)
        // The base: a lip wider than the screen, with the hinge notch.
        p.move(to: CGPoint(x: 4, y: 150))
        p.addLine(to: CGPoint(x: 70, y: 150))
        p.addQuadCurve(to: CGPoint(x: 106, y: 150), control: CGPoint(x: 88, y: 156))
        p.addLine(to: CGPoint(x: 172, y: 150))
        p.addQuadCurve(to: CGPoint(x: 160, y: 160), control: CGPoint(x: 170, y: 160))
        p.addLine(to: CGPoint(x: 16, y: 160))
        p.addQuadCurve(to: CGPoint(x: 4, y: 150), control: CGPoint(x: 6, y: 160))
        return p
    }()

    private static let iPhone: Path = {
        var p = Path()
        roundRect(phone, radius: 14, into: &p)
        p.move(to: CGPoint(x: phone.midX - 8, y: phone.minY + 9))
        p.addLine(to: CGPoint(x: phone.midX + 8, y: phone.minY + 9))
        return p
    }()

    private static let prompt: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 36, y: 72))
        p.addLine(to: CGPoint(x: 47, y: 81))
        p.addLine(to: CGPoint(x: 36, y: 90))
        p.move(to: CGPoint(x: 54, y: 91))
        p.addLine(to: CGPoint(x: 68, y: 91))
        return p
    }()

    private struct Node {
        var at: CGPoint
        var radius: CGFloat
        /// When the edge into this node starts and finishes growing.
        var grow: ClosedRange<Double>
        var parent: Int?
        var phase: Double
    }

    /// The trunk runs prompt → arc over the gap → phone; branches end in dots,
    /// like a constellation reaching out of the Mac.
    private static let nodes: [Node] = [
        Node(at: CGPoint(x: 96, y: 80), radius: 6, grow: 1.95...2.2, parent: nil, phase: 0.0),
        Node(at: CGPoint(x: 140, y: 34), radius: 7, grow: 2.15...2.5, parent: 0, phase: 1.1),
        Node(at: CGPoint(x: 176, y: 18), radius: 6.5, grow: 2.4...2.75, parent: 1, phase: 2.3),
        Node(at: CGPoint(x: 210, y: 30), radius: 7, grow: 2.65...3.0, parent: 2, phase: 3.2),
        Node(at: phoneCenter, radius: 7.5, grow: 2.9...3.3, parent: 3, phase: 4.0),
        Node(at: CGPoint(x: 112, y: 14), radius: 4.6, grow: 2.45...2.8, parent: 1, phase: 5.1),
        Node(at: CGPoint(x: 188, y: -2), radius: 4.6, grow: 2.7...3.0, parent: 2, phase: 0.7),
        Node(at: CGPoint(x: 244, y: 10), radius: 4.6, grow: 2.95...3.25, parent: 3, phase: 2.0),
        Node(at: CGPoint(x: 120, y: 58), radius: 4.2, grow: 2.3...2.6, parent: 0, phase: 4.6),
    ]

    /// The trunk, for the idle pulse.
    private static let trunk: [CGPoint] = (0...4).map { nodes[$0].at }

    /// The app icon's gradient, sampled across the drawing.
    private static func accent(atX x: CGFloat) -> Color {
        let stops: [(CGFloat, (Double, Double, Double))] = [
            (60, (0x06, 0xCD, 0xFE)), (160, (0x2A, 0xA0, 0xF9)), (240, (0x51, 0x70, 0xF3)),
        ]
        func rgb(_ c: (Double, Double, Double)) -> Color { Color(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255) }
        if x <= stops[0].0 { return rgb(stops[0].1) }
        for i in 1..<stops.count where x <= stops[i].0 {
            let (x0, a) = stops[i - 1], (x1, b) = stops[i]
            let f = Double((x - x0) / (x1 - x0))
            return rgb((a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f))
        }
        return rgb(stops[stops.count - 1].1)
    }

    private static let iconGradient = Gradient(colors: [Color(hex: "#06CDFE"), Color(hex: "#2AA0F9"), Color(hex: "#5170F3")])

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext) {
        typealias E = IntroEase
        let ink = theme.colors.label.color
        let stroke = StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
        let dark = colorScheme == .dark

        // 1. The Mac, then the phone, drawn as one pen line.
        let macDraw = E.inOut(E.seg(t, 0.3, 1.55))
        if macDraw > 0 { context.stroke(Self.mac.trimmedPath(from: 0, to: macDraw), with: .color(ink), style: stroke) }
        let phoneDraw = E.inOut(E.seg(t, 1.05, 2.0))
        if phoneDraw > 0 { context.stroke(Self.iPhone.trimmedPath(from: 0, to: phoneDraw), with: .color(ink), style: stroke) }

        // 2. The prompt on the Mac, in the icon's cyan.
        let promptDraw = E.out(E.seg(t, 1.55, 1.95))
        if promptDraw > 0 {
            context.stroke(
                Self.prompt.trimmedPath(from: 0, to: promptDraw),
                with: .linearGradient(Self.iconGradient, startPoint: CGPoint(x: 30, y: 0), endPoint: CGPoint(x: 120, y: 0)),
                style: stroke
            )
        }

        // 3. The network grows out of the prompt, sways, then folds into the phone.
        let collapse = t - 4.0
        if t > 1.95, t < 4.75 { drawNetwork(in: &context, collapse: collapse) }

        // 4. The chevron blooms on the phone's screen; an idle pulse makes it beat.
        let bloom = E.seg(t, 4.4, 5.15)
        if bloom > 0 {
            var scale = 0.25 + 0.75 * E.outBack(bloom, overshoot: 2.2)
            var glow = E.seg(t, 4.5, 5.2)
            if let pulse {
                let beat = sin(.pi * E.seg(pulse, 1.25, 1.75))
                scale *= 1 + 0.09 * beat
                glow += 0.6 * beat
            }
            let side = 30 * CGFloat(scale)
            let c = Self.phoneCenter
            let rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
            let mark = CmuxMark().path(in: rect)
            context.drawLayer { layer in
                layer.opacity = E.seg(t, 4.4, 4.6)
                layer.addFilter(.shadow(color: Color(hex: "#2AA0F9").opacity((dark ? 0.7 : 0.35) * min(glow, 1.4)), radius: 8 + 6 * glow))
                layer.fill(mark, with: .linearGradient(Self.iconGradient, startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
            }
        }

        if let pulse { drawPulse(in: &context, u: pulse) }
    }

    private func drawNetwork(in context: inout GraphicsContext, collapse: Double) {
        typealias E = IntroEase
        let target = Self.phoneCenter
        // Each node's current position: grown, swaying, then pulled into the phone.
        var points: [CGPoint] = []
        var fold: [Double] = []
        for node in Self.nodes {
            let sway = E.seg(t, 3.1, 3.4) * (1 - E.seg(t, 3.9, 4.2))
            let wobble = CGPoint(
                x: node.at.x + CGFloat(sin(t * 3.4 + node.phase) * 3.6 * sway),
                y: node.at.y + CGFloat(cos(t * 2.9 + node.phase) * 3.6 * sway)
            )
            // Farther nodes start folding first so they all land together.
            let distance = hypot(node.at.x - target.x, node.at.y - target.y)
            let start = 0.25 - Double(min(distance, 160) / 160) * 0.25
            let f = E.inCubic(E.seg(collapse, start, 0.65))
            fold.append(f)
            points.append(E.lerp(wobble, target, f))
        }
        let edgeStroke = StrokeStyle(lineWidth: 3, lineCap: .round)
        for (i, node) in Self.nodes.enumerated() {
            guard let parent = node.parent else { continue }
            let g = E.out(E.seg(t, node.grow.lowerBound, node.grow.upperBound))
            guard g > 0 else { continue }
            let from = points[parent], to = E.lerp(points[parent], points[i], g)
            var edge = Path()
            edge.move(to: from)
            edge.addLine(to: to)
            context.stroke(
                edge,
                with: .linearGradient(Gradient(colors: [Self.accent(atX: from.x), Self.accent(atX: to.x)]), startPoint: from, endPoint: to),
                style: edgeStroke
            )
        }
        for (i, node) in Self.nodes.enumerated() {
            // A node pops as its edge arrives (the root pops as the prompt finishes).
            let pop = E.seg(t, node.grow.upperBound - 0.12, node.grow.upperBound + 0.22)
            guard pop > 0 else { continue }
            let r = node.radius * CGFloat(E.outBack(pop)) * CGFloat(1 - 0.55 * fold[i])
            let p = points[i]
            context.opacity = 1 - E.seg(collapse, 0.55, 0.72)
            context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(Self.accent(atX: p.x)))
            context.opacity = 1
        }
    }

    /// Idle: three dots run along the trunk from the Mac to the phone, and the
    /// chevron beats as they arrive.
    private func drawPulse(in context: inout GraphicsContext, u: Double) {
        typealias E = IntroEase
        let trunk = Self.trunk
        var lengths: [CGFloat] = [0]
        for i in 1..<trunk.count { lengths.append(lengths[i - 1] + hypot(trunk[i].x - trunk[i - 1].x, trunk[i].y - trunk[i - 1].y)) }
        let total = lengths[lengths.count - 1]
        func point(_ s: Double) -> CGPoint {
            let d = CGFloat(s) * total
            for i in 1..<trunk.count where d <= lengths[i] {
                return E.lerp(trunk[i - 1], trunk[i], Double((d - lengths[i - 1]) / (lengths[i] - lengths[i - 1])))
            }
            return trunk[trunk.count - 1]
        }
        for k in 0..<3 {
            let s = E.inOut(E.seg(u, 0.1 + Double(k) * 0.12, 1.35 + Double(k) * 0.12))
            guard s > 0, s < 1 else { continue }
            let p = point(s)
            let r: CGFloat = 3.8 - CGFloat(k) * 0.6
            context.opacity = sin(.pi * s)
            context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(Self.accent(atX: p.x)))
        }
        context.opacity = 1
    }
}
#endif
