import CmuxHomeCore
import CmuxHomeRender
import UIKit

/// Hosts the render core's root layer and exposes its rows to VoiceOver:
/// the rows are layers, so each visible message is a `UIAccessibilityElement`
/// built from `HomeController.accessibilityItems()`. A long press on a bubble
/// opens its menu (Copy, and Try Again / Delete for a message the owner
/// refused), found with the core's hit test.
@MainActor
final class HomeRowHostView: UIView, UIContextMenuInteractionDelegate {
    weak var controller: HomeController? {
        didSet { invalidateAccessibility() }
    }
    /// Actions for a refused send (Try Again, Delete); empty when delivered.
    var failureActions: (IdempotencyKey) -> [HomeMessageAction] = { _ in [] }
    private var elements: [UIAccessibilityElement]?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addInteraction(UIContextMenuInteraction(delegate: self))
        accessibilityLabel = HomeText.transcriptA11y
        accessibilityContainerType = .list
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Puts the root layer in this view's layer (the core lays out top-left, as UIKit does).
    func host(_ root: CALayer) {
        layer.addSublayer(root)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let root = controller?.rootLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        CATransaction.commit()
    }

    // MARK: Accessibility

    /// The viewport or the draft changed; elements are rebuilt on the next read.
    func invalidateAccessibility() {
        elements = nil
    }

    /// The rows changed (a new message, an older page): VoiceOver re-reads
    /// the list. Not posted for scroll steps, which only move the viewport.
    func rowsChanged() {
        elements = nil
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    override var accessibilityElements: [Any]? {
        get {
            if let elements { return elements }
            let built = (controller?.accessibilityItems() ?? []).filter { $0.role == .staticText }.map(element)
            elements = built
            return built
        }
        set { _ = newValue }
    }

    private func element(_ item: HomeAXItem) -> UIAccessibilityElement {
        let e = UIAccessibilityElement(accessibilityContainer: self)
        e.accessibilityLabel = item.label
        e.accessibilityValue = item.value.isEmpty ? nil : item.value
        e.accessibilityIdentifier = item.id
        e.accessibilityTraits = .staticText
        e.accessibilityFrameInContainerSpace = item.frame
        if let key = item.item {
            e.accessibilityCustomActions = customActions(item: key, text: item.label)
        }
        return e
    }

    /// Copy (the part's text, the element's label) and the refused-send actions.
    private func customActions(item: IdempotencyKey, text: String) -> [UIAccessibilityCustomAction] {
        var actions = [UIAccessibilityCustomAction(name: HomeText.copy, image: UIImage(systemName: "doc.on.doc")) { _ in
            MainActor.assumeIsolated { UIPasteboard.general.string = text }
            return true
        }]
        for action in failureActions(item) {
            let run = action.run
            actions.append(UIAccessibilityCustomAction(name: action.title, image: action.image) { _ in
                MainActor.assumeIsolated { run() }
                return true
            })
        }
        return actions
    }

    // MARK: Context menu

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let hit = controller?.hit(at: location) else { return nil }
        let text = hit.text
        let failure = failureActions(hit.item).map { action in
            let run = action.run
            return UIAction(title: action.title, image: action.image,
                            attributes: action.isDestructive ? .destructive : []) { _ in run() }
        }
        return UIContextMenuConfiguration(identifier: NSCoder.string(for: hit.bubble) as NSString, previewProvider: nil) { _ in
            var children: [UIMenuElement] = [
                UIAction(title: HomeText.copy, image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = text
                },
            ]
            if !failure.isEmpty { children.append(UIMenu(options: .displayInline, children: failure)) }
            return UIMenu(children: children)
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview(for: configuration)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview(for: configuration)
    }

    /// Lifts only the pressed bubble: a snapshot of its rect, clipped to a
    /// rounded rect, placed where the bubble is.
    private func preview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let id = configuration.identifier as? String else { return nil }
        let bubble = NSCoder.cgRect(for: id)
        guard !bubble.isEmpty, let snapshot = resizableSnapshotView(from: bubble, afterScreenUpdates: false,
                                                                    withCapInsets: .zero) else { return nil }
        let parameters = UIPreviewParameters()
        // The core's bubble radius scales with Dynamic Type (`textScale`).
        let radius = 15 * (controller?.textScale ?? 1)
        parameters.visiblePath = UIBezierPath(roundedRect: snapshot.bounds, cornerRadius: min(radius, bubble.height / 2))
        parameters.backgroundColor = .clear
        let target = UIPreviewTarget(container: self, center: CGPoint(x: bubble.midX, y: bubble.midY))
        return UITargetedPreview(view: snapshot, parameters: parameters, target: target)
    }
}

/// One message action offered in the menu and to VoiceOver.
struct HomeMessageAction {
    var title: String
    var image: UIImage?
    var isDestructive = false
    var run: @MainActor () -> Void
}
