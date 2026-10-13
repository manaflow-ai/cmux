#if os(iOS)
import CoreGraphics

/// Interactive open/close state for the push-aside sidebar.
struct SidebarState {
    private(set) var isOpen = false
    private var dragOffset: CGFloat?
    private var isTracking = false

    mutating func open() { isOpen = true; dragOffset = nil; isTracking = false }
    mutating func close() { isOpen = false; dragOffset = nil; isTracking = false }

    func progress(sidebarWidth: CGFloat) -> CGFloat {
        guard sidebarWidth > 0 else { return 0 }
        let base: CGFloat = isOpen ? sidebarWidth : 0
        let x = base + (dragOffset ?? 0)
        return min(max(x / sidebarWidth, 0), 1)
    }

    /// Tracks only mostly-horizontal drags so vertical scrolling is untouched.
    mutating func track(translation: CGSize, sidebarWidth: CGFloat) {
        if !isTracking {
            guard abs(translation.width) > abs(translation.height) * 1.6 else { return }
            guard isOpen ? translation.width < 0 : translation.width > 0 else { return }
            isTracking = true
        }
        dragOffset = translation.width
    }

    mutating func settle(translation: CGSize, predicted: CGSize, sidebarWidth: CGFloat) {
        guard isTracking else { return }
        let finalX = (isOpen ? sidebarWidth : 0) + predicted.width
        isOpen = finalX > sidebarWidth / 2
        dragOffset = nil
        isTracking = false
    }
}
#endif
