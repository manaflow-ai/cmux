import AppKit

@MainActor
final class CmuxTerminalGridContainerView: NSView {
    var onLayout: (() -> Void)?
    var onBackingPropertiesChanged: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onBackingPropertiesChanged?()
    }
}
