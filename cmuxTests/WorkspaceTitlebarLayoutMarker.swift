import AppKit
import SwiftUI

/// Test-only frame marker underneath the real Bonsplit content and title layers.
struct WorkspaceTitlebarLayoutMarker: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
