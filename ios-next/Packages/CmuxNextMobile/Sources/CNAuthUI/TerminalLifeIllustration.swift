#if os(iOS)
import CNDesign
import SwiftUI

/// The sign-in illustration: a hand-drawn terminal window whose cursor seeds
/// a Game of Life colony, gathers it back, types a few lines and starts over.
///
/// Everything is drawn in code on a 200 x 200 design box and animated on
/// twelves (12 fps): each tick redraws the monolines with one of three
/// "boil" variants, so the drawing feels hand-made against the 60/120 Hz UI.
/// Ink is the only line colour; `highlight` is the only accent (cursor and
/// cells). Reduce Motion shows one still frame.
struct TerminalLifeIllustration: View {
    /// When the drawing starts (the intro hand-off); nil shows nothing yet.
    let startDate: Date?
    var choreography: SignInChoreography = .standard

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let startDate {
                if reduceMotion {
                    canvas(time: TerminalLifeScene.heroTime)
                } else {
                    TimelineView(.periodic(from: startDate, by: 1 / choreography.illustrationFPS)) { context in
                        let elapsed = max(0, context.date.timeIntervalSince(startDate))
                        canvas(time: (elapsed * choreography.illustrationFPS).rounded(.down) / choreography.illustrationFPS)
                    }
                }
            } else {
                Color.clear
            }
        }
        .accessibilityHidden(true)
    }

    private func canvas(time: TimeInterval) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            TerminalLifeScene(time: time, fps: choreography.illustrationFPS)
                .draw(in: &context, size: size, ink: .cn(\.ink), accent: .cn(\.highlight))
        }
    }
}

/// Pure, time-indexed description of the illustration (testable, no state).
struct TerminalLifeScene {
    let time: TimeInterval
    let fps: Double

    /// A still frame with the window, prompt, typed lines and cursor.
    static let heroTime: TimeInterval = intro + 5.6

    // Intro beats (seconds from the hand-off).
    static let outlineEnd: TimeInterval = 0.7
    static let separatorEnd: TimeInterval = 0.85
    static let dotsAt: TimeInterval = 0.8
    static let promptEnd: TimeInterval = 1.05
    static let intro: TimeInterval = 1.1
    /// The repeating story after the intro.
    static let cycle: TimeInterval = 8.0

    // Design-box geometry.
    static let window = CGRect(x: 16, y: 34, width: 168, height: 128)
    static let separatorY: CGFloat = 58
    static let pitch: CGFloat = 12
    static let gridOrigin = CGPoint(x: 28, y: 64)
    static let columns = 13
    static let rows = 8
    static let promptOrigin = CGPoint(x: 30, y: 70)
    static let cursorHome = CGPoint(x: 50, y: 70)
    static let cursorSize = CGSize(width: 9, height: 15)
    static let lineWidth: CGFloat = 4.4
    static let typedLines: [CGFloat] = [104, 70, 122]

    private var tick: Int { Int((time * fps).rounded(.down)) }
    /// Three boil variants, cycling every tick.
    private var boil: Int { tick % 3 }

    func draw(in context: inout GraphicsContext, size: CGSize, ink: Color, accent: Color) {
        let scale = min(size.width, size.height) / 200
        context.translateBy(x: (size.width - 200 * scale) / 2, y: (size.height - 200 * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        let style = StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)

        // Window outline, drawn on from the top edge clockwise.
        let outline = Self.outlinePoints()
        stroke(outline, seed: 1, upTo: progress(0, Self.outlineEnd), in: &context, ink: ink, style: style)
        // Title-bar separator.
        let separator = Self.line(from: CGPoint(x: Self.window.minX, y: Self.separatorY),
                                  to: CGPoint(x: Self.window.maxX, y: Self.separatorY))
        stroke(separator, seed: 2, upTo: progress(Self.outlineEnd - 0.05, Self.separatorEnd), in: &context, ink: ink,
               style: StrokeStyle(lineWidth: Self.lineWidth * 0.6, lineCap: .round))
        // Three window dots pop in with a small overshoot.
        for index in 0..<3 {
            let start = Self.dotsAt + Double(index) * (1 / fps)
            let pop = popScale(since: start)
            guard pop > 0 else { continue }
            let center = CGPoint(x: Self.window.minX + 14 + CGFloat(index) * 11, y: 46)
            let radius = 3.2 * pop
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(ink), lineWidth: 2.2)
        }
        // Prompt chevron.
        let p = Self.promptOrigin
        let prompt = Self.polyline([CGPoint(x: p.x, y: p.y), CGPoint(x: p.x + 10, y: p.y + 7.5), CGPoint(x: p.x, y: p.y + 15)])
        stroke(prompt, seed: 3, upTo: progress(Self.dotsAt + 0.05, Self.promptEnd), in: &context, ink: ink, style: style)

        guard time >= Self.intro else { return }
        drawCycle(at: (time - Self.intro).truncatingRemainder(dividingBy: Self.cycle),
                   generation: Int((time - Self.intro) / Self.cycle), in: &context, ink: ink, accent: accent, style: style)
    }

    // MARK: Story

    private func drawCycle(at t: TimeInterval, generation cycleIndex: Int, in context: inout GraphicsContext,
                           ink: Color, accent: Color, style: StrokeStyle) {
        let lifeStart = 0.5, lifeEnd = 2.9, gatherEnd = 3.4
        let typeStart = 3.4, typeLine = 0.5, eraseStart = 6.4, eraseEnd = 7.0

        // Life: one generation every two ticks, seeded next to the cursor.
        if t >= lifeStart && t < gatherEnd {
            let lifeTicks = Int(((min(t, lifeEnd) - lifeStart) * fps).rounded(.down))
            let generation = lifeTicks / 2
            let colony = TerminalLifeColony(seed: cycleIndex, columns: Self.columns, rows: Self.rows)
            let cells = colony.generation(generation)
            let born = generation == 0 ? cells : cells.subtracting(colony.generation(generation - 1))
            let gather = t >= lifeEnd ? easeIn(progress(lifeEnd, gatherEnd, at: t)) : 0
            let cursor = CGPoint(x: Self.cursorHome.x + Self.cursorSize.width / 2, y: Self.cursorHome.y + Self.cursorSize.height / 2)

            func center(_ cell: TerminalLifeColony.Cell) -> CGPoint {
                let home = CGPoint(x: Self.gridOrigin.x + CGFloat(cell.column) * Self.pitch + Self.pitch / 2,
                                   y: Self.gridOrigin.y + CGFloat(cell.row) * Self.pitch + Self.pitch / 2)
                return CGPoint(x: home.x + (cursor.x - home.x) * gather, y: home.y + (cursor.y - home.y) * gather)
            }
            // Edges between live neighbours, under the cells.
            var edges = Path()
            for cell in cells {
                for neighbour in cell.forwardNeighbours where cells.contains(neighbour) {
                    edges.move(to: center(cell))
                    edges.addLine(to: center(neighbour))
                }
            }
            context.stroke(edges, with: .color(accent.opacity(0.55)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            for cell in cells {
                let isNew = born.contains(cell) && lifeTicks % 2 == 0 && t < lifeEnd
                let side = 7.4 * (isNew ? 0.6 : 1) * (1 - gather * 0.7)
                let c = center(cell)
                context.fill(Path(roundedRect: CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side), cornerRadius: side * 0.3),
                             with: .color(accent))
            }
        }

        // Typed output lines, then erased together.
        var cursorPosition = Self.cursorHome
        if t >= typeStart && t < eraseEnd {
            let erase = t >= eraseStart ? progress(eraseStart, eraseEnd, at: t) : 0
            for (index, length) in Self.typedLines.enumerated() {
                let begin = typeStart + Double(index) * typeLine
                let drawn = progress(begin, begin + typeLine * 0.85, at: t)
                guard drawn > 0 else { continue }
                let y = 100 + CGFloat(index) * 17
                let points = Self.line(from: CGPoint(x: 30, y: y), to: CGPoint(x: 30 + length, y: y))
                stroke(points, seed: 10 + index, from: erase, upTo: drawn, in: &context, ink: ink,
                       style: StrokeStyle(lineWidth: Self.lineWidth * 0.8, lineCap: .round))
                if erase == 0 {
                    cursorPosition = CGPoint(x: 30 + length * drawn + 7, y: y - Self.cursorSize.height / 2)
                }
            }
        }

        // The cursor: the illustration's one accent block. Hidden while the
        // colony is out, blinking (6 ticks on, 6 off) otherwise.
        let colonyOut = t >= lifeStart && t < gatherEnd
        let typing = t >= typeStart && t < typeStart + Double(Self.typedLines.count) * typeLine
        let blinkOn = typing || (Int((t * fps).rounded(.down)) / 6) % 2 == 0
        if !colonyOut || t >= gatherEnd - 0.1, blinkOn {
            let wobble = jitter(seed: 99, index: 0) * 0.5
            let rect = CGRect(origin: CGPoint(x: cursorPosition.x + wobble, y: cursorPosition.y), size: Self.cursorSize)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(accent))
        }
    }

    // MARK: Drawing helpers

    private func stroke(_ points: [CGPoint], seed: Int, from start: Double = 0, upTo end: Double,
                        in context: inout GraphicsContext, ink: Color, style: StrokeStyle) {
        guard end > start, points.count > 1 else { return }
        let boiled = points.enumerated().map { index, point in
            CGPoint(x: point.x + jitter(seed: seed, index: index * 2), y: point.y + jitter(seed: seed, index: index * 2 + 1))
        }
        context.stroke(Self.smoothPath(Self.trim(boiled, from: start, to: end)), with: .color(ink), style: style)
    }

    /// Deterministic ±0.6 pt offset for one point in the current boil variant.
    private func jitter(seed: Int, index: Int) -> CGFloat {
        var h = UInt64(truncatingIfNeeded: seed &* 73_856_093 ^ index &* 19_349_663 ^ boil &* 83_492_791)
        h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
        return (CGFloat(h % 1000) / 1000 - 0.5) * 1.2
    }

    private func progress(_ start: TimeInterval, _ end: TimeInterval, at t: TimeInterval? = nil) -> Double {
        let value = t ?? time
        return min(1, max(0, (value - start) / (end - start)))
    }

    private func popScale(since start: TimeInterval) -> CGFloat {
        guard time >= start else { return 0 }
        let ticks = Int(((time - start) * fps).rounded(.down))
        return ticks == 0 ? 1.35 : 1
    }

    private func easeIn(_ x: Double) -> CGFloat { CGFloat(x * x) }

    // MARK: Geometry

    static func outlinePoints() -> [CGPoint] {
        let r = window, radius: CGFloat = 16
        var points: [CGPoint] = []
        func arc(center: CGPoint, from a0: CGFloat, to a1: CGFloat) {
            for step in 0...6 {
                let a = a0 + (a1 - a0) * CGFloat(step) / 6
                points.append(CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a)))
            }
        }
        points.append(CGPoint(x: r.midX + 30, y: r.minY))
        arc(center: CGPoint(x: r.maxX - radius, y: r.minY + radius), from: -.pi / 2, to: 0)
        points += line(from: CGPoint(x: r.maxX, y: r.minY + radius), to: CGPoint(x: r.maxX, y: r.maxY - radius))
        arc(center: CGPoint(x: r.maxX - radius, y: r.maxY - radius), from: 0, to: .pi / 2)
        points += line(from: CGPoint(x: r.maxX - radius, y: r.maxY), to: CGPoint(x: r.minX + radius, y: r.maxY))
        arc(center: CGPoint(x: r.minX + radius, y: r.maxY - radius), from: .pi / 2, to: .pi)
        points += line(from: CGPoint(x: r.minX, y: r.maxY - radius), to: CGPoint(x: r.minX, y: r.minY + radius))
        arc(center: CGPoint(x: r.minX + radius, y: r.minY + radius), from: .pi, to: 1.5 * .pi)
        points += line(from: CGPoint(x: r.minX + radius, y: r.minY), to: CGPoint(x: r.midX + 26, y: r.minY))
        return points
    }

    static func line(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let count = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 10))
        return (0...count).map { i in
            let f = CGFloat(i) / CGFloat(count)
            return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        }
    }

    static func polyline(_ corners: [CGPoint]) -> [CGPoint] {
        zip(corners, corners.dropFirst()).flatMap { line(from: $0, to: $1).dropLast() } + [corners[corners.count - 1]]
    }

    /// The part of a polyline between fractions `start` and `end` of its length.
    static func trim(_ points: [CGPoint], from start: Double, to end: Double) -> [CGPoint] {
        var lengths: [CGFloat] = [0]
        for (a, b) in zip(points, points.dropFirst()) { lengths.append(lengths[lengths.count - 1] + hypot(b.x - a.x, b.y - a.y)) }
        let total = lengths[lengths.count - 1]
        let lo = total * CGFloat(start), hi = total * CGFloat(end)
        func point(at distance: CGFloat) -> CGPoint {
            let index = max(1, lengths.firstIndex { $0 >= distance } ?? lengths.count - 1)
            let a = points[index - 1], b = points[index]
            let span = lengths[index] - lengths[index - 1]
            let f = span > 0 ? (distance - lengths[index - 1]) / span : 0
            return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        }
        var result = [point(at: lo)]
        for (index, length) in lengths.enumerated() where length > lo && length < hi { result.append(points[index]) }
        result.append(point(at: hi))
        return result
    }

    /// Quadratic smoothing through midpoints, so the boil reads as a pen line.
    static func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else { points.dropFirst().forEach { path.addLine(to: $0) }; return path }
        for index in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

/// A small bounded Game of Life board seeded next to the cursor.
struct TerminalLifeColony {
    struct Cell: Hashable {
        var column: Int
        var row: Int

        /// Right, down-right, down and down-left: each edge once.
        var forwardNeighbours: [Cell] {
            [Cell(column: column + 1, row: row), Cell(column: column + 1, row: row + 1),
             Cell(column: column, row: row + 1), Cell(column: column - 1, row: row + 1)]
        }
    }

    let columns: Int
    let rows: Int
    let seedCells: Set<Cell>

    /// Patterns that grow for a few seconds inside a 13 x 8 board.
    static let seeds: [[(Int, Int)]] = [
        [(3, 1), (4, 1), (2, 2), (3, 2), (3, 3)],                 // R-pentomino
        [(2, 1), (3, 2), (1, 3), (2, 3), (3, 3), (6, 2), (7, 2), (8, 2)], // glider + blinker
        [(2, 1), (4, 2), (1, 3), (2, 3), (5, 3), (6, 3), (7, 3)], // acorn
    ]

    init(seed: Int, columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        let pattern = Self.seeds[((seed % Self.seeds.count) + Self.seeds.count) % Self.seeds.count]
        seedCells = Set(pattern.map { Cell(column: $0.0, row: $0.1) })
    }

    func generation(_ n: Int) -> Set<Cell> {
        var cells = seedCells
        for _ in 0..<max(0, n) { cells = step(cells) }
        return cells
    }

    private func step(_ cells: Set<Cell>) -> Set<Cell> {
        var counts: [Cell: Int] = [:]
        for cell in cells {
            for dc in -1...1 {
                for dr in -1...1 where dc != 0 || dr != 0 {
                    let n = Cell(column: cell.column + dc, row: cell.row + dr)
                    guard n.column >= 0, n.column < columns, n.row >= 0, n.row < rows else { continue }
                    counts[n, default: 0] += 1
                }
            }
        }
        return Set(counts.compactMap { cell, count in
            count == 3 || (count == 2 && cells.contains(cell)) ? cell : nil
        })
    }
}
#endif
