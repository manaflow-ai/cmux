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
    /// The collapsed bar has settled: its hidden controls (back, tabs, page
    /// menu, reload) leave the hierarchy. They are drawn through glass,
    /// whose content kept them in the accessibility tree despite
    /// accessibilityHidden. They come back as an expand begins (touch-down
    /// on the pill, the first finger travel toward expanding), so they
    /// slide and fade back exactly as before.
    private(set) var controlsGone = false
    var editing = false {
        // Ending an edit (inside its animation) brings the controls back;
        // they fade in with it.
        didSet { if !editing, editControlsGone { editControlsGone = false } }
    }
    /// Address editing has settled: back, page menu and reload (invisible
    /// under the field, drawn through glass) leave the hierarchy, as for
    /// the collapsed bar (`controlsGone`).
    private(set) var editControlsGone = false
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
        withAnimation(style.motion.resolve(style.motion.collapse)) { bar = .collapsed } completion: { [weak self] in
            guard let self, self.bar == .collapsed else { return }
            self.controlsGone = true
        }
        withAnimation(style.motion.sideOut) { sidesVisible = false }
    }

    /// The editing animation finished.
    func editingSettled() {
        if editing { editControlsGone = true }
    }

    /// A page drag ended: a drag that did not expand the bar leaves the
    /// controls out of the tree again.
    func pageDragEnded() {
        if bar == .collapsed, !controlsGone { controlsGone = true }
    }

    /// An expand may follow (touch-down on the pill, finger travel toward
    /// expanding): put the hidden controls back while they are still
    /// invisible, so the expand animates them from where they are.
    func prepareExpand() {
        if controlsGone { controlsGone = false }
    }

    func expand(tap: Bool) {
        guard bar == .collapsed else { return }
        // Without a prepare (VoiceOver's action), they fade in in place.
        prepareExpand()
        withAnimation(style.motion.resolve(tap ? style.motion.expandTap : style.motion.expandScroll)) { bar = .expanded }
        withAnimation(style.motion.sideIn) { sidesVisible = true }
    }

    /// Finger travel from the page (positive = finger moving down, which
    /// scrolls the page up). Not scroll-linked: crossing the threshold starts
    /// a time-based spring, as in Safari.
    func pageDragged(_ dy: CGFloat) {
        if (dy > 0) != (dragTravel > 0) { dragTravel = 0 }
        dragTravel += dy
        if dragTravel > 0 {
            prepareExpand()
        } else if bar == .collapsed, !controlsGone {
            // A drag that turned back without expanding: out again.
            controlsGone = true
        }
        // (A drag that ends without expanding: pageDragEnded.)
        if dragTravel < -style.metrics.collapseThreshold { collapse() }
        if dragTravel > style.metrics.expandThreshold { expand(tap: false) }
    }
}
#endif
