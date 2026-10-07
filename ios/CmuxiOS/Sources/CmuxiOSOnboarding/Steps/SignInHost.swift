import SwiftUI
import UIKit

/// Hosts the kept sign-in screen inside the onboarding step.
struct SignInHost: UIViewControllerRepresentable {
    let make: @MainActor () -> UIViewController

    func makeUIViewController(context: Context) -> UIViewController { make() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
