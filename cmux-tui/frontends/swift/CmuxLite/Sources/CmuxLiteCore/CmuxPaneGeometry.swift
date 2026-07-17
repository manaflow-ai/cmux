import Foundation

/// Pane rectangles and directional-neighbor selection derived from a view layout.
public struct CmuxPaneGeometry: Sendable, Equatable {
    /// Pane rectangles keyed by pane identifier.
    public let rectangles: [UInt64: CmuxLayoutRect]

    private let order: [UInt64]

    /// Lays out a pane tree inside normalized or pixel bounds.
    /// - Parameters:
    ///   - layout: The recursive visible pane layout.
    ///   - bounds: The containing rectangle, defaulting to a unit square.
    public init(
        layout: CmuxPaneLayoutView,
        bounds: CmuxLayoutRect = CmuxLayoutRect(x: 0, y: 0, width: 1, height: 1)
    ) {
        var rectangles: [UInt64: CmuxLayoutRect] = [:]
        layout.collectRectangles(in: bounds, into: &rectangles)
        self.rectangles = rectangles
        order = layout.paneIDs
    }

    /// Finds the best local pane in one direction using overlap before axial distance.
    /// - Parameters:
    ///   - pane: The source pane identifier.
    ///   - direction: The requested direction.
    /// - Returns: The neighboring pane without wraparound, when one exists.
    public func neighbor(of pane: UInt64, toward direction: CmuxPaneDirection) -> UInt64? {
        guard let current = rectangles[pane] else { return nil }
        var best: (pane: UInt64, overlap: Double, distance: Double, index: Int)?
        for (index, candidatePane) in order.enumerated() {
            guard candidatePane != pane,
                  let candidate = rectangles[candidatePane],
                  candidate.width > 0,
                  candidate.height > 0,
                  let score = Self.score(
                    current: current,
                    candidate: candidate,
                    direction: direction
                  )
            else { continue }
            let candidateScore = (
                pane: candidatePane,
                overlap: score.overlap,
                distance: score.distance,
                index: index
            )
            guard let currentBest = best else {
                best = candidateScore
                continue
            }
            if candidateScore.overlap > currentBest.overlap
                || (candidateScore.overlap == currentBest.overlap
                    && candidateScore.distance < currentBest.distance)
                || (candidateScore.overlap == currentBest.overlap
                    && candidateScore.distance == currentBest.distance
                    && candidateScore.index < currentBest.index)
            {
                best = candidateScore
            }
        }
        return best?.pane
    }

    private static func score(
        current: CmuxLayoutRect,
        candidate: CmuxLayoutRect,
        direction: CmuxPaneDirection
    ) -> (overlap: Double, distance: Double)? {
        let overlap: Double
        let distance: Double
        switch direction {
        case .left:
            guard candidate.x + candidate.width <= current.x else { return nil }
            overlap = overlapLength(
                current.y, current.height,
                candidate.y, candidate.height
            )
            distance = current.x - candidate.x - candidate.width
        case .right:
            guard candidate.x >= current.x + current.width else { return nil }
            overlap = overlapLength(
                current.y, current.height,
                candidate.y, candidate.height
            )
            distance = candidate.x - current.x - current.width
        case .up:
            guard candidate.y + candidate.height <= current.y else { return nil }
            overlap = overlapLength(
                current.x, current.width,
                candidate.x, candidate.width
            )
            distance = current.y - candidate.y - candidate.height
        case .down:
            guard candidate.y >= current.y + current.height else { return nil }
            overlap = overlapLength(
                current.x, current.width,
                candidate.x, candidate.width
            )
            distance = candidate.y - current.y - current.height
        }
        return overlap > 0 ? (overlap, distance) : nil
    }

    private static func overlapLength(
        _ firstStart: Double,
        _ firstExtent: Double,
        _ secondStart: Double,
        _ secondExtent: Double
    ) -> Double {
        max(0, min(firstStart + firstExtent, secondStart + secondExtent)
            - max(firstStart, secondStart))
    }
}

private extension CmuxPaneLayoutView {
    func collectRectangles(
        in bounds: CmuxLayoutRect,
        into result: inout [UInt64: CmuxLayoutRect]
    ) {
        switch self {
        case let .pane(pane):
            result[pane] = bounds
        case let .group(direction, ratio, first, second):
            switch direction {
            case .right:
                let firstWidth = bounds.width * ratio
                first.collectRectangles(
                    in: CmuxLayoutRect(
                        x: bounds.x,
                        y: bounds.y,
                        width: firstWidth,
                        height: bounds.height
                    ),
                    into: &result
                )
                second.collectRectangles(
                    in: CmuxLayoutRect(
                        x: bounds.x + firstWidth,
                        y: bounds.y,
                        width: bounds.width - firstWidth,
                        height: bounds.height
                    ),
                    into: &result
                )
            case .down:
                let firstHeight = bounds.height * ratio
                first.collectRectangles(
                    in: CmuxLayoutRect(
                        x: bounds.x,
                        y: bounds.y,
                        width: bounds.width,
                        height: firstHeight
                    ),
                    into: &result
                )
                second.collectRectangles(
                    in: CmuxLayoutRect(
                        x: bounds.x,
                        y: bounds.y + firstHeight,
                        width: bounds.width,
                        height: bounds.height - firstHeight
                    ),
                    into: &result
                )
            }
        }
    }
}
