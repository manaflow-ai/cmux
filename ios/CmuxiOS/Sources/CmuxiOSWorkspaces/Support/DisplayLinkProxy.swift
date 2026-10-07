import QuartzCore

/// The display link's target: breaks the retain from the link to its owner.
/// When the owner is gone (`onTick` returns false) the link invalidates
/// itself, so a released screen never leaves a link firing.
@MainActor
final class DisplayLinkProxy: NSObject {
    private let onTick: @MainActor () -> Bool

    init(onTick: @escaping @MainActor () -> Bool) {
        self.onTick = onTick
    }

    @objc func tick(_ link: CADisplayLink) {
        if !onTick() { link.invalidate() }
    }
}
