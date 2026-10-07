public import CmuxAuthRuntime
import CmuxMobileSupport
import SwiftUI
public import UIKit

/// The kept sign-in flow (email code, OAuth providers, restore status) as a
/// UIKit view controller for the new app's root flow.
@MainActor
public enum SignInScreen {
    /// `onContinueWithoutAccount` adds "Use SSH Without an Account" under the
    /// flow (deferred sign-in, e5-extras.md section 5); nil leaves it out.
    public static func make(coordinator: AuthCoordinator,
                            onContinueWithoutAccount: (@MainActor () -> Void)? = nil) -> UIViewController {
        let controller = UIHostingController(rootView: SignInWithGuest(
            usesStandaloneChrome: true, onContinueWithoutAccount: onContinueWithoutAccount).environment(coordinator))
        controller.view.backgroundColor = .systemBackground
        return controller
    }

    /// The same flow without its standalone chrome (no navigation stack or
    /// header art), for hosts that supply their own title, like onboarding.
    public static func makeEmbedded(coordinator: AuthCoordinator,
                                    onContinueWithoutAccount: (@MainActor () -> Void)? = nil) -> UIViewController {
        let controller = UIHostingController(rootView: SignInWithGuest(
            usesStandaloneChrome: false, onContinueWithoutAccount: onContinueWithoutAccount).environment(coordinator))
        controller.view.backgroundColor = .clear
        return controller
    }
}

/// The kept sign-in view plus the optional guest entry below it.
private struct SignInWithGuest: View {
    let usesStandaloneChrome: Bool
    let onContinueWithoutAccount: (@MainActor () -> Void)?

    var body: some View {
        SignInView(usesStandaloneChrome: usesStandaloneChrome)
            .safeAreaInset(edge: .bottom) {
                if let onContinueWithoutAccount {
                    Button {
                        onContinueWithoutAccount()
                    } label: {
                        Text(L10n.string("mobile.signIn.continueWithoutAccount", defaultValue: "Use SSH Without an Account"))
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .accessibilityHint(L10n.string("mobile.signIn.continueWithoutAccount.hint",
                                                   defaultValue: "Hosts and SSH terminals work without signing in."))
                    .accessibilityIdentifier("signin.continueWithoutAccount")
                }
            }
    }
}
