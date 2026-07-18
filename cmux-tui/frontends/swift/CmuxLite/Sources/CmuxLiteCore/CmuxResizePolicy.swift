import Foundation

/// Converts stable terminal measurements into echo-safe resize decisions.
public struct CmuxResizePolicy: Sendable {
    /// Creates a stateless resize policy.
    public init() {}

    /// Selects a resize using this client's last report and final bounds.
    ///
    /// Every client must report its initial grid even when it matches the shared
    /// surface. Later shared-size updates do not trigger a report unless this
    /// client's own available grid changed.
    /// - Parameters:
    ///   - lastSent: The last grid successfully sent by this client.
    ///   - measurement: Final container bounds and native cell metrics.
    /// - Returns: No action or the newly measured grid.
    public func action(
        lastSent: CmuxSurfaceSize?,
        measurement: CmuxTerminalMeasurement
    ) -> CmuxResizeAction {
        guard let measured = grid(for: measurement) else { return .none }
        guard measured != lastSent else { return .none }
        return .resize(measured)
    }

    /// Floors final backing-pixel bounds by the native renderer's cell dimensions.
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
