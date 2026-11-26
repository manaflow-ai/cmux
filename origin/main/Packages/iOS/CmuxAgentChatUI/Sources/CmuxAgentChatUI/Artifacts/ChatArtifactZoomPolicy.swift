import Foundation

/// Scale rules shared by artifact image zoom gestures and tests.
struct ChatArtifactZoomPolicy: Equatable, Sendable {
    enum HorizontalSwipeOwner: Equatable, Sendable {
        case pager
        case image
    }

    let minimumScale: Double
    let doubleTapScale: Double
    let maximumScale: Double

    init(
        minimumScale: Double = 1,
        doubleTapScale: Double = 3,
        maximumScale: Double = 8
    ) {
        self.minimumScale = minimumScale
        self.doubleTapScale = doubleTapScale
        self.maximumScale = maximumScale
    }

    func isAtMinimum(_ scale: Double) -> Bool {
        abs(scale - minimumScale) <= 0.01
    }

    func horizontalSwipeOwner(at scale: Double) -> HorizontalSwipeOwner {
        isAtMinimum(scale) ? .pager : .image
    }

    func scaleAfterDoubleTap(currentScale: Double) -> Double {
        isAtMinimum(currentScale) ? doubleTapScale : minimumScale
    }
}
