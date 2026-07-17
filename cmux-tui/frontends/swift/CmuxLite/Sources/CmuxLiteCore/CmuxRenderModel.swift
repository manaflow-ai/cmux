import Foundation

/// Holds one immutable, normalized protocol-v7 terminal viewport.
public struct CmuxRenderModel: Sendable, Equatable {
    /// The attached surface identifier.
    public let surface: UInt64

    /// The authoritative terminal grid.
    public let size: CmuxSurfaceSize

    /// The latest authoritative cursor state.
    public let cursor: CmuxRenderCursor

    /// The current default foreground RGB string.
    public let defaultForeground: String

    /// The current default background RGB string.
    public let defaultBackground: String

    /// The current retained scrollback-row count.
    public let scrollbackRows: UInt32

    /// Exactly `size.rows` rows indexed by their `row` field.
    public let rows: [CmuxRenderRow]

    /// Normalizes a complete snapshot into indexed viewport rows.
    /// - Parameter snapshot: The initial render-state event.
    /// - Returns: A complete immutable render model.
    public static func applySnapshot(_ snapshot: CmuxRenderStateEvent) -> Self {
        Self(
            surface: snapshot.surface,
            size: snapshot.size,
            cursor: snapshot.cursor,
            defaultForeground: snapshot.defaultForeground,
            defaultBackground: snapshot.defaultBackground,
            scrollbackRows: snapshot.scrollbackRows,
            rows: normalize(snapshot.rows, height: Int(snapshot.size.rows))
        )
    }

    /// Applies an ordered delta and returns a replacement immutable model.
    /// - Parameter delta: A render-delta event from the same attachment stream.
    /// - Returns: The updated model, or this model for another surface's stale delta.
    public func applyDelta(_ delta: CmuxRenderDeltaEvent) -> Self {
        guard delta.surface == surface else { return self }
        let nextSize = delta.size ?? size
        let replacesViewport = delta.full || delta.size != nil
        let nextRows: [CmuxRenderRow]
        if replacesViewport {
            nextRows = Self.normalize(delta.rows, height: Int(nextSize.rows))
        } else if delta.rows.isEmpty {
            nextRows = rows
        } else {
            var updated = rows
            for candidate in delta.rows where updated.indices.contains(candidate.row) {
                updated[candidate.row] = CmuxRenderRow(row: candidate.row, runs: candidate.runs)
            }
            nextRows = updated
        }
        return Self(
            surface: surface,
            size: nextSize,
            cursor: delta.cursor,
            defaultForeground: delta.defaultForeground ?? defaultForeground,
            defaultBackground: delta.defaultBackground ?? defaultBackground,
            scrollbackRows: delta.scrollbackRows ?? scrollbackRows,
            rows: nextRows
        )
    }

    /// Joins the normalized viewport rows for exact state-dump verification.
    public var text: String {
        rows.map(\.text).joined(separator: "\n")
    }

    private static func normalize(_ candidates: [CmuxRenderRow], height: Int) -> [CmuxRenderRow] {
        var normalized = (0..<max(0, height)).map { CmuxRenderRow(row: $0, runs: []) }
        for candidate in candidates where normalized.indices.contains(candidate.row) {
            normalized[candidate.row] = CmuxRenderRow(row: candidate.row, runs: candidate.runs)
        }
        return normalized
    }
}
