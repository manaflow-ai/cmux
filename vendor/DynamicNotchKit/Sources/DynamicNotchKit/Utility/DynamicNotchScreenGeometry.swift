import AppKit

/// Pure screen geometry used to anchor DynamicNotchKit in the menu-bar band.
///
/// The value initializer keeps layout policy testable without requiring a
/// physical notch, a specific display arrangement, or a particular macOS
/// release.
public struct DynamicNotchScreenGeometry: Equatable, Sendable {
    public let screenFrame: CGRect
    public let visibleFrame: CGRect
    public let safeAreaTop: CGFloat
    public let auxiliaryTopLeftWidth: CGFloat?
    public let auxiliaryTopRightWidth: CGFloat?
    public let statusBarThickness: CGFloat
    public let syntheticNotchWidth: CGFloat
    public let syntheticNotchSafeAreaWidth: CGFloat?
    public let syntheticNotchHorizontalPosition: CGFloat

    public init(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftWidth: CGFloat?,
        auxiliaryTopRightWidth: CGFloat?,
        statusBarThickness: CGFloat,
        syntheticNotchWidth: CGFloat,
        syntheticNotchSafeAreaWidth: CGFloat? = nil,
        syntheticNotchHorizontalPosition: CGFloat = 0.5
    ) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeftWidth = auxiliaryTopLeftWidth
        self.auxiliaryTopRightWidth = auxiliaryTopRightWidth
        self.statusBarThickness = statusBarThickness
        self.syntheticNotchWidth = syntheticNotchWidth
        self.syntheticNotchSafeAreaWidth = syntheticNotchSafeAreaWidth
        self.syntheticNotchHorizontalPosition =
            syntheticNotchHorizontalPosition
    }

    @MainActor
    public init(
        screen: NSScreen,
        syntheticNotchWidth: CGFloat,
        syntheticNotchSafeAreaWidth: CGFloat? = nil,
        syntheticNotchHorizontalPosition: CGFloat = 0.5
    ) {
        self.init(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width,
            statusBarThickness: NSStatusBar.system.thickness,
            syntheticNotchWidth: syntheticNotchWidth,
            syntheticNotchSafeAreaWidth: syntheticNotchSafeAreaWidth,
            syntheticNotchHorizontalPosition:
                syntheticNotchHorizontalPosition
        )
    }

    public var hasHardwareNotch: Bool {
        guard let auxiliaryTopLeftWidth,
              let auxiliaryTopRightWidth else {
            return false
        }
        return screenFrame.width - auxiliaryTopLeftWidth - auxiliaryTopRightWidth > 0
            && safeAreaTop > 0
    }

    public var menuBarHeight: CGFloat {
        max(
            1,
            safeAreaTop,
            screenFrame.maxY - visibleFrame.maxY,
            statusBarThickness
        )
    }

    public var notchFrame: CGRect {
        let width: CGFloat
        if hasHardwareNotch,
           let auxiliaryTopLeftWidth,
           let auxiliaryTopRightWidth {
            width = screenFrame.width
                - auxiliaryTopLeftWidth
                - auxiliaryTopRightWidth
        } else {
            width = min(
                max(72, syntheticNotchWidth),
                max(72, screenFrame.width - 32)
            )
        }
        let height = hasHardwareNotch
            ? max(safeAreaTop, menuBarHeight)
            : menuBarHeight
        let centerX = hasHardwareNotch
            ? screenFrame.midX
            : syntheticNotchCenterX(width: width)
        return CGRect(
            x: centerX - (width / 2),
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    /// Converts a global screen x coordinate into the configurable synthetic
    /// notch position, where 0 and 1 are the safe left and right limits.
    public func syntheticHorizontalPosition(
        forScreenX screenX: CGFloat
    ) -> CGFloat {
        let range = syntheticNotchCenterRange(
            width: notchFrame.width
        )
        guard range.upperBound > range.lowerBound else { return 0.5 }
        return min(
            1,
            max(
                0,
                (screenX - range.lowerBound)
                    / (range.upperBound - range.lowerBound)
            )
        )
    }

    public func revealRegion(distance: CGFloat) -> CGRect {
        let distance = max(0, distance)
        return CGRect(
            x: notchFrame.minX - distance,
            y: notchFrame.minY - distance,
            width: notchFrame.width + (distance * 2),
            height: notchFrame.height + distance
        ).intersection(screenFrame)
    }

    public func isNearNotch(_ point: CGPoint, distance: CGFloat) -> Bool {
        revealRegion(distance: distance).contains(point)
    }

    private func syntheticNotchCenterX(width: CGFloat) -> CGFloat {
        let range = syntheticNotchCenterRange(width: width)
        let position = min(
            1,
            max(0, syntheticNotchHorizontalPosition)
        )
        return range.lowerBound
            + ((range.upperBound - range.lowerBound) * position)
    }

    private func syntheticNotchCenterRange(
        width: CGFloat
    ) -> ClosedRange<CGFloat> {
        let margin: CGFloat = 16
        let availableWidth = max(1, screenFrame.width - (margin * 2))
        let safeWidth = min(
            availableWidth,
            max(width, syntheticNotchSafeAreaWidth ?? width)
        )
        let lower = screenFrame.minX + (safeWidth / 2) + margin
        let upper = max(
            lower,
            screenFrame.maxX - (safeWidth / 2) - margin
        )
        return lower ... upper
    }
}
