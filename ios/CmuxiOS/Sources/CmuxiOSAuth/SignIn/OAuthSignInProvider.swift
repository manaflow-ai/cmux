import CmuxAuthRuntime
import CmuxMobileSupport
import SwiftUI

enum OAuthSignInProvider: CaseIterable, Hashable {
    case apple
    case google
    case github

    var analyticsMethod: String {
        switch self {
        case .apple: return "apple"
        case .google: return "google"
        case .github: return "github"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .apple: return "signin.apple"
        case .google: return "signin.google"
        case .github: return "signin.github"
        }
    }

    @ViewBuilder
    @MainActor
    func label(isLoading: Bool) -> some View {
        switch self {
        case .apple:
            Label(L10n.string("mobile.signIn.apple", defaultValue: "Sign in with Apple"), systemImage: "apple.logo")
                .fontWeight(.semibold)
                .mobileButtonLoading(isLoading)
        case .google:
            HStack(spacing: 6) {
                Image("GoogleLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(L10n.string("mobile.signIn.google", defaultValue: "Sign in with Google"))
                    .fontWeight(.semibold)
            }
            .mobileButtonLoading(isLoading)
        case .github:
            HStack(spacing: 6) {
                Image("GitHubLogo")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(L10n.string("mobile.signIn.github", defaultValue: "Sign in with GitHub"))
                    .fontWeight(.semibold)
            }
            .mobileButtonLoading(isLoading)
        }
    }

    func signIn(using coordinator: AuthCoordinator) async throws {
        switch self {
        case .apple:
            try await coordinator.signInWithApple()
        case .google:
            try await coordinator.signInWithGoogle()
        case .github:
            try await coordinator.signInWithGitHub()
        }
    }
}
