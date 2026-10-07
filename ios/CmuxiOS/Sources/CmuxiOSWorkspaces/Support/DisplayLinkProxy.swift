import Foundation

/// The display link's target: breaks the retain from the link to its owner.
@MainActor
final class DisplayLinkProxy: NSObject {
    private let onTick: @MainActor () -> Void

    init(onTick: @escaping @MainActor () -> Void) {
        self.onTick = onTick
    }

    @objc func tick() { onTick() }
}
