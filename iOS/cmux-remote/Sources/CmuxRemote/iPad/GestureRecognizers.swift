import SwiftUI
import UIKit
import CmuxKit

/// Wires finger-only multi-touch gestures over the terminal surface:
/// two-finger horizontal swipes switch surfaces, three-finger swipe-down
/// opens the command palette, pinch adjusts the SwiftTerm font size.
///
/// Pencil is explicitly excluded so PencilKit handwriting on the overlay
/// keeps working.
struct CmuxGestureModifier: ViewModifier {
    let nextSurface: () -> Void
    let previousSurface: () -> Void
    let openPalette: () -> Void
    let nextWorkspace: () -> Void
    let previousWorkspace: () -> Void

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                MagnificationGesture()
                    .onEnded { _ in /* TerminalView handles font sizing via its internal pinch */ }
            )
            .overlay(MultiFingerGestureBridge(
                onThreeFingerSwipeDown: openPalette,
                onTwoFingerSwipeLeft: nextSurface,
                onTwoFingerSwipeRight: previousSurface
            ))
    }
}

extension View {
    func cmuxGestures(
        nextSurface: @escaping () -> Void,
        previousSurface: @escaping () -> Void,
        openPalette: @escaping () -> Void,
        nextWorkspace: @escaping () -> Void,
        previousWorkspace: @escaping () -> Void
    ) -> some View {
        modifier(CmuxGestureModifier(
            nextSurface: nextSurface,
            previousSurface: previousSurface,
            openPalette: openPalette,
            nextWorkspace: nextWorkspace,
            previousWorkspace: previousWorkspace
        ))
    }
}

/// SwiftUI's gesture system doesn't expose multi-finger swipes with the
/// fidelity we want. We drop down to UIKit gesture recognizers, anchored on
/// a transparent passthrough view that doesn't intercept touches the
/// terminal needs.
struct MultiFingerGestureBridge: UIViewRepresentable {
    let onThreeFingerSwipeDown: () -> Void
    let onTwoFingerSwipeLeft: () -> Void
    let onTwoFingerSwipeRight: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onThreeFingerSwipeDown: onThreeFingerSwipeDown,
            onTwoFingerSwipeLeft: onTwoFingerSwipeLeft,
            onTwoFingerSwipeRight: onTwoFingerSwipeRight
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = PassThroughView()
        let coordinator = context.coordinator

        let threeDown = UISwipeGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handleThreeFingerSwipeDown(_:))
        )
        threeDown.direction = .down
        threeDown.numberOfTouchesRequired = 3
        threeDown.delegate = coordinator
        threeDown.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addGestureRecognizer(threeDown)

        let twoLeft = UISwipeGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handleTwoFingerSwipeLeft(_:))
        )
        twoLeft.direction = .left
        twoLeft.numberOfTouchesRequired = 2
        twoLeft.delegate = coordinator
        twoLeft.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addGestureRecognizer(twoLeft)

        let twoRight = UISwipeGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handleTwoFingerSwipeRight(_:))
        )
        twoRight.direction = .right
        twoRight.numberOfTouchesRequired = 2
        twoRight.delegate = coordinator
        twoRight.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addGestureRecognizer(twoRight)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let onThreeFingerSwipeDown: () -> Void
        let onTwoFingerSwipeLeft: () -> Void
        let onTwoFingerSwipeRight: () -> Void

        init(
            onThreeFingerSwipeDown: @escaping () -> Void,
            onTwoFingerSwipeLeft: @escaping () -> Void,
            onTwoFingerSwipeRight: @escaping () -> Void
        ) {
            self.onThreeFingerSwipeDown = onThreeFingerSwipeDown
            self.onTwoFingerSwipeLeft = onTwoFingerSwipeLeft
            self.onTwoFingerSwipeRight = onTwoFingerSwipeRight
        }

        @objc func handleThreeFingerSwipeDown(_ sender: UISwipeGestureRecognizer) {
            guard sender.state == .ended else { return }
            onThreeFingerSwipeDown()
        }
        @objc func handleTwoFingerSwipeLeft(_ sender: UISwipeGestureRecognizer) {
            guard sender.state == .ended else { return }
            onTwoFingerSwipeLeft()
        }
        @objc func handleTwoFingerSwipeRight(_ sender: UISwipeGestureRecognizer) {
            guard sender.state == .ended else { return }
            onTwoFingerSwipeRight()
        }

        // Pencil touches must never trigger app-level navigation gestures.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touch.type != .pencil
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private final class PassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Only intercept multi-touch — single-touch events fall through to
        // the SwiftTerm view beneath us.
        if let touches = event?.allTouches, touches.count >= 2 { return self }
        return nil
    }
}
