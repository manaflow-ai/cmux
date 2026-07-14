import Foundation

/// The native-pixel frame used to render a shared terminal grid without scaling it.
public struct CmuxTerminalGridGeometry: Sendable, Equatable {
    /// The authoritative shared terminal grid represented by this geometry.
    public let grid: CmuxSurfaceSize

    /// The grid frame in a top-left-origin container, expressed in points.
    public let gridFrame: CmuxLayoutRect

    /// The grid drawable width in native backing pixels.
    public let drawableWidthPixels: UInt32

    /// The grid drawable height in native backing pixels.
    public let drawableHeightPixels: UInt32

    /// Creates the exact point frame and native-pixel drawable for a shared grid.
    ///
    /// The frame intentionally remains the grid's native size even when it is smaller
    /// or larger than its container. The platform host clips any overflow and paints
    /// any unused container area with the terminal background.
    ///
    /// - Parameters:
    ///   - containerWidthPoints: The enclosing pane width in points.
    ///   - containerHeightPoints: The enclosing pane height in points.
    ///   - backingScale: The window backing scale for the enclosing pane.
    ///   - grid: The authoritative shared terminal grid.
    ///   - currentGrid: Ghostty's grid at the currently measured viewport size.
    ///   - currentWidthPixels: Ghostty's currently measured viewport width.
    ///   - currentHeightPixels: Ghostty's currently measured viewport height.
    ///   - cellWidthPixels: The native width of one terminal cell in backing pixels.
    ///   - cellHeightPixels: The native height of one terminal cell in backing pixels.
    public init?(
        containerWidthPoints: Double,
        containerHeightPoints: Double,
        backingScale: Double,
        grid: CmuxSurfaceSize,
        currentGrid: CmuxSurfaceSize,
        currentWidthPixels: UInt32,
        currentHeightPixels: UInt32,
        cellWidthPixels: UInt32,
        cellHeightPixels: UInt32
    ) {
        guard containerWidthPoints.isFinite,
              containerHeightPoints.isFinite,
              containerWidthPoints > 0,
              containerHeightPoints > 0,
              backingScale.isFinite,
              backingScale > 0,
              grid.cols > 0,
              grid.rows > 0,
              currentGrid.cols > 0,
              currentGrid.rows > 0,
              currentWidthPixels > 0,
              currentHeightPixels > 0,
              cellWidthPixels > 0,
              cellHeightPixels > 0
        else { return nil }

        let currentCellWidth = UInt64(currentGrid.cols) * UInt64(cellWidthPixels)
        let currentCellHeight = UInt64(currentGrid.rows) * UInt64(cellHeightPixels)
        guard currentCellWidth <= UInt64(currentWidthPixels),
              currentCellHeight <= UInt64(currentHeightPixels)
        else { return nil }

        // Ghostty's viewport includes non-cell pixels for padding and any fractional
        // remainder. Preserve those pixels so fitting this frame produces the target
        // grid, rather than the one-column/one-row-short grid produced by cells alone.
        let widthPixels = UInt64(grid.cols) * UInt64(cellWidthPixels)
            + UInt64(currentWidthPixels) - currentCellWidth
        let heightPixels = UInt64(grid.rows) * UInt64(cellHeightPixels)
            + UInt64(currentHeightPixels) - currentCellHeight
        guard widthPixels <= UInt64(UInt32.max),
              heightPixels <= UInt64(UInt32.max)
        else { return nil }

        self.grid = grid
        drawableWidthPixels = UInt32(widthPixels)
        drawableHeightPixels = UInt32(heightPixels)
        gridFrame = CmuxLayoutRect(
            x: 0,
            y: 0,
            width: Double(drawableWidthPixels) / backingScale,
            height: Double(drawableHeightPixels) / backingScale
        )
    }

    /// Reports whether this shared grid leaves unused room in a local grid capacity.
    /// - Parameter localCapacity: The grid this pane could fit at the same cell metrics.
    /// - Returns: `true` when another client has selected a smaller width or height.
    public func isForeignSmaller(than localCapacity: CmuxSurfaceSize) -> Bool {
        grid.cols < localCapacity.cols || grid.rows < localCapacity.rows
    }
}
