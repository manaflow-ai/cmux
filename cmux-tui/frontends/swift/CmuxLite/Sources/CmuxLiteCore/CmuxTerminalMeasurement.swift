import Foundation

/// Final terminal-container bounds paired with the native renderer's cell metrics.
public struct CmuxTerminalMeasurement: Sendable, Equatable {
    /// The final laid-out container width in backing pixels.
    public let widthPixels: Double

    /// The final laid-out container height in backing pixels.
    public let heightPixels: Double

    /// The measured cell width in backing pixels.
    public let cellWidthPixels: UInt32

    /// The measured cell height in backing pixels.
    public let cellHeightPixels: UInt32

    /// The exact grid when the measured viewport is fitted to the container.
    public let fittedGrid: CmuxSurfaceSize?

    /// Creates a terminal-container measurement.
    /// - Parameters:
    ///   - widthPixels: The final laid-out container width in backing pixels.
    ///   - heightPixels: The final laid-out container height in backing pixels.
    ///   - cellWidthPixels: The measured cell width in backing pixels.
    ///   - cellHeightPixels: The measured cell height in backing pixels.
    ///   - fittedGrid: The exact fitted grid, when available.
    public init(
        widthPixels: Double,
        heightPixels: Double,
        cellWidthPixels: UInt32,
        cellHeightPixels: UInt32,
        fittedGrid: CmuxSurfaceSize? = nil
    ) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.cellWidthPixels = cellWidthPixels
        self.cellHeightPixels = cellHeightPixels
        self.fittedGrid = fittedGrid
    }
}
