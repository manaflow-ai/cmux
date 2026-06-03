import SwiftUI
import UIKit
import XCTest
@testable import cmux_DEV

@MainActor
final class SignInViewTests: XCTestCase {
    func testSignInViewShowsAppleGoogleAndEmailEntry() {
        let controller = UIHostingController(rootView: SignInView())
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        controller.loadViewIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let renderedText = renderedStrings(in: controller.view)
        let glassControlCount = countViews(
            in: controller.view,
            where: { String(describing: type(of: $0)).contains("UIPlatformGlassInteractionView") }
        )

        XCTAssertTrue(renderedText.contains("Email address"), renderedText.joined(separator: "\n"))
        XCTAssertEqual(glassControlCount, 4, "Expected Apple, Google, email field, and email submit controls on the sign-in screen.")
    }

    private func renderedStrings(in view: UIView) -> Set<String> {
        var results: Set<String> = []

        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            results.insert(text)
        }

        if let textField = view as? UITextField {
            if let text = textField.text, !text.isEmpty {
                results.insert(text)
            }
            if let placeholder = textField.placeholder, !placeholder.isEmpty {
                results.insert(placeholder)
            }
        }

        if let button = view as? UIButton {
            if let title = button.currentTitle, !title.isEmpty {
                results.insert(title)
            }
        }

        if let accessibilityLabel = view.accessibilityLabel, !accessibilityLabel.isEmpty {
            results.insert(accessibilityLabel)
        }

        if let elements = view.accessibilityElements {
            for element in elements {
                results.formUnion(renderedStrings(in: element))
            }
        }

        for subview in view.subviews {
            results.formUnion(renderedStrings(in: subview))
        }

        return results
    }

    private func renderedStrings(in object: Any) -> Set<String> {
        var results: Set<String> = []

        if let element = object as? UIAccessibilityElement {
            if let label = element.accessibilityLabel, !label.isEmpty {
                results.insert(label)
            }
            if let value = element.accessibilityValue as? String, !value.isEmpty {
                results.insert(value)
            }
        }

        if let view = object as? UIView {
            results.formUnion(renderedStrings(in: view))
        }

        return results
    }

    private func countViews(in view: UIView, where predicate: (UIView) -> Bool) -> Int {
        let ownCount = predicate(view) ? 1 : 0
        return ownCount + view.subviews.reduce(0) { $0 + countViews(in: $1, where: predicate) }
    }
}
