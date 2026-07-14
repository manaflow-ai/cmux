import Foundation

/// Converts stable terminal measurements into echo-safe resize decisions.
public struct CmuxResizePolicy: Sendable {
    /// Creates a stateless resize policy.
    public init() {}

    /// Selects a resize using the last client send, latest replay, and final bounds.
    ///
    /// An echoed replay never schedules another resize, a foreign replay is
    /// accepted without ping-pong when the local grid is unchanged, and a
    /// genuinely changed local grid is returned for debounce.
    /// - Parameters:
    ///   - lastSent: The last grid successfully sent by this client.
    ///   - incomingResized: The most recent authoritative replay grid.
    ///   - measurement: Final container bounds and Ghostty cell metrics.
    /// - Returns: No action or the newly measured grid.
    public func action(
        lastSent: CmuxSurfaceSize?,
        incomingResized: CmuxSurfaceSize?,
        measurement: CmuxTerminalMeasurement
    ) -> CmuxResizeAction {
        guard let measured = grid(for: measurement) else { return .none }
        if let lastSent, incomingResized == lastSent, measured == lastSent {
            return .none
        }
        guard measured != lastSent, measured != incomingResized else {
            return .none
        }
        return .resize(measured)
    }

    /// Floors final backing-pixel bounds by Ghostty's cell dimensions.
    /// - Parameter measurement: Final container bounds and cell metrics.
    /// - Returns: A positive grid, or `nil` for incomplete layout metrics.
    public func grid(for measurement: CmuxTerminalMeasurement) -> CmuxSurfaceSize? {
        if let fittedGrid = measurement.fittedGrid,
           fittedGrid.cols > 0,
           fittedGrid.rows > 0
        {
            return fittedGrid
        }

        guard measurement.widthPixels.isFinite,
              measurement.heightPixels.isFinite,
              measurement.widthPixels > 0,
              measurement.heightPixels > 0,
              measurement.cellWidthPixels > 0,
              measurement.cellHeightPixels > 0
        else { return nil }

        let columns = min(
            floor(measurement.widthPixels / Double(measurement.cellWidthPixels)),
            Double(UInt16.max)
        )
        let rows = min(
            floor(measurement.heightPixels / Double(measurement.cellHeightPixels)),
            Double(UInt16.max)
        )
        guard columns >= 1, rows >= 1 else { return nil }
        return CmuxSurfaceSize(cols: UInt16(columns), rows: UInt16(rows))
    }
}
