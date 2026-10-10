#if os(iOS)
import Observation
import SwiftUI

/// Local chrome state for the browser screen (no transport).
@MainActor
@Observable
final class BrowserChromeState {
    enum Bar: Equatable { case expanded, collapsed }

    var bar: Bar = .expanded
    /// Back and tabs circles (and capsule glyphs); animated on their own ramp.
    var sidesVisible = true
    var editing = false
    var editText = ""
    var menuOpen = false
    /// Tab overview presented (grid visible).
    var overview = false
    /// Remote text entry through the hidden proxy field.
    var pageKeyboard = false
    /// Horizontal finger offset of a toolbar tab swipe.
    var swipeOffset: CGFloat = 0
    var swiping = false

    /// Accumulated finger travel for the current drag direction.
    @ObservationIgnored private var dragTravel: CGFloat = 0

    private let style = BrowserStyle.shared

    func collapse() {
        guard bar == .expanded, !editing, !menuOpen else { return }
        withAnimation(style.motion.resolve(style.motion.collapse)) { bar = .collapsed }
        withAnimation(style.motion.sideOut) { sidesVisible = false }
    }

    func expand(tap: Bool) {
        guard bar == .collapsed else { return }
        withAnimation(style.motion.resolve(tap ? style.motion.expandTap : style.motion.expandScroll)) { bar = .expanded }
        withAnimation(style.motion.sideIn) { sidesVisible = true }
    }

    /// Finger travel from the page (positive = finger moving down, which
    /// scrolls the page up). Not scroll-linked: crossing the threshold starts
    /// a time-based spring, as in Safari.
    func pageDragged(_ dy: CGFloat) {
        if (dy > 0) != (dragTravel > 0) { dragTravel = 0 }
        dragTravel += dy
        if dragTravel < -style.metrics.collapseThreshold { collapse() }
        if dragTravel > style.metrics.expandThreshold { expand(tap: false) }
    }
}
#endif
