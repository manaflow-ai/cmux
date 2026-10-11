import CmuxHomeCore
import CmuxHomeRender
import UIKit

/// Hosts the render core's root layer and exposes its rows to VoiceOver:
/// the rows are layers, so each visible message is a `UIAccessibilityElement`
/// built from `HomeController.accessibilityItems()`. A long press on a bubble
/// opens its menu (React, Copy, and Try Again / Delete for a message the
/// owner refused), found with the core's hit test. A double tap on a bubble
/// is the shortcut to React (the tapback picker); VoiceOver gets React as a
/// custom action.
@MainActor
final class HomeRowHostView: UIView, UIContextMenuInteractionDelegate {
    weak var controller: HomeController? {
        didSet { invalidateAccessibility() }
    }
    /// Actions for a refused send (Try Again, Delete); empty when delivered.
    var failureActions: (IdempotencyKey) -> [HomeMessageAction] = { _ in [] }
    /// Whether the owner is reachable; no reaction target while offline
    /// (nothing queues), so React leaves the menu and VoiceOver's actions.
    var isOnline: () -> Bool = { false }
    /// Opens the tapback picker for a target.
    var showTapbacks: (HomeReactionTarget) -> Void = { _ in }
    private var elements: [UIAccessibilityElement]?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addInteraction(UIContextMenuInteraction(delegate: self))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
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
            let canReact = controller?.reactionTarget(for: item, isOnline: isOnline()) != nil
            e.accessibilityCustomActions = customActions(item: key, text: item.label, react: canReact ? item : nil)
        }
        return e
    }

    /// React (the element's part, when it can take a tapback), Copy (the
    /// part's text, the element's label) and the refused-send actions. React
    /// resolves its target again when it runs, so the chosen tapbacks and the
    /// connection are current.
    private func customActions(item: IdempotencyKey, text: String,
                               react element: HomeAXItem?) -> [UIAccessibilityCustomAction] {
        var actions: [UIAccessibilityCustomAction] = []
        if let element {
            actions.append(UIAccessibilityCustomAction(name: HomeText.tapbackReact, image: UIImage(systemName: "face.smiling")) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let target = self.controller?.reactionTarget(for: element, isOnline: self.isOnline())
                    else { return false }
                    self.showTapbacks(target)
                    return true
                }
            })
        }
        actions.append(UIAccessibilityCustomAction(name: HomeText.copy, image: UIImage(systemName: "doc.on.doc")) { _ in
            MainActor.assumeIsolated { UIPasteboard.general.string = text }
            return true
        })
        for action in failureActions(item) {
            let run = action.run
            actions.append(UIAccessibilityCustomAction(name: action.title, image: action.image) { _ in
                MainActor.assumeIsolated { run() }
                return true
            })
        }
        return actions
    }

    // MARK: Tapbacks

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        openTapbacks(at: recognizer.location(in: self))
    }

    /// Opens the picker for the bubble at `point`; false when there is no
    /// bubble or its message cannot take a reaction.
    @discardableResult
    private func openTapbacks(at point: CGPoint) -> Bool {
        guard let controller, let hit = controller.hit(at: point),
              let target = controller.reactionTarget(for: hit, isOnline: isOnline()) else { return false }
        showTapbacks(target)
        return true
    }

    // MARK: Context menu

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let hit = controller?.hit(at: location) else { return nil }
        let text = hit.text
        let react = controller?.reactionTarget(for: hit, isOnline: isOnline()).map { target in
            UIAction(title: HomeText.tapbackReact, image: UIImage(systemName: "face.smiling")) { [weak self] _ in
                self?.showTapbacks(target)
            }
        }
        let failure = failureActions(hit.item).map { action in
            let run = action.run
            return UIAction(title: action.title, image: action.image,
                            attributes: action.isDestructive ? .destructive : []) { _ in run() }
        }
        return UIContextMenuConfiguration(identifier: NSCoder.string(for: hit.bubble) as NSString, previewProvider: nil) { _ in
            var children: [UIMenuElement] = react.map { [$0] } ?? []
            children.append(UIAction(title: HomeText.copy, image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            })
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
