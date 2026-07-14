import Foundation

/// Final terminal-container bounds paired with Ghostty's actual cell metrics.
public struct CmuxTerminalMeasurement: Sendable, Equatable {
    /// The final laid-out container width in backing pixels.
    public let widthPixels: Double

    /// The final laid-out container height in backing pixels.
    public let heightPixels: Double

    /// Ghostty's measured cell width in backing pixels.
    public let cellWidthPixels: UInt32

    /// Ghostty's measured cell height in backing pixels.
    public let cellHeightPixels: UInt32

    /// Creates a terminal-container measurement.
    /// - Parameters:
    ///   - widthPixels: The final laid-out container width in backing pixels.
    ///   - heightPixels: The final laid-out container height in backing pixels.
    ///   - cellWidthPixels: Ghostty's measured cell width in backing pixels.
    ///   - cellHeightPixels: Ghostty's measured cell height in backing pixels.
    public init(
        widthPixels: Double,
        heightPixels: Double,
        cellWidthPixels: UInt32,
        cellHeightPixels: UInt32
    ) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.cellWidthPixels = cellWidthPixels
        self.cellHeightPixels = cellHeightPixels
    }
}
