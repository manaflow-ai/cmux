import AppKit

/// Replaces only AppKit's modal tracking loop while the anchor still owns
/// presentation, dismissal, and follow-up actions.
@MainActor
final class CloudTeamPickerTestMenu: NSMenu {
    private let onPopUp: @MainActor (NSView?) -> Void

    init(onPopUp: @escaping @MainActor (NSView?) -> Void) {
        self.onPopUp = onPopUp
        super.init(title: "")
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        // AppKit exposes this override as nonisolated, but the anchor invokes
        // menu tracking synchronously from its main-actor presentation path.
        MainActor.assumeIsolated { onPopUp(view) }
        return true
    }
}
