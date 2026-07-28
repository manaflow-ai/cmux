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

    public init(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftWidth: CGFloat?,
        auxiliaryTopRightWidth: CGFloat?,
        statusBarThickness: CGFloat,
        syntheticNotchWidth: CGFloat
    ) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeftWidth = auxiliaryTopLeftWidth
        self.auxiliaryTopRightWidth = auxiliaryTopRightWidth
        self.statusBarThickness = statusBarThickness
        self.syntheticNotchWidth = syntheticNotchWidth
    }

    @MainActor
    public init(
        screen: NSScreen,
        syntheticNotchWidth: CGFloat
    ) {
        self.init(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width,
            statusBarThickness: NSStatusBar.system.thickness,
            syntheticNotchWidth: syntheticNotchWidth
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
        return CGRect(
            x: screenFrame.midX - (width / 2),
            y: screenFrame.maxY - height,
            width: width,
            height: height
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
}
