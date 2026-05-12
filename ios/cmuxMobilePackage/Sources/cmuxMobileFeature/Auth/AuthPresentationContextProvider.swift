import AuthenticationServices
import UIKit

final class AuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding, ASAuthorizationControllerPresentationContextProviding {
    static let shared = AuthPresentationContextProvider()

    private override init() {
        super.init()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        resolveAnchor()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        resolveAnchor()
    }

    private func resolveAnchor() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first { $0.activationState == .foregroundActive }
        guard let anchorScene = activeScene ?? scenes.first else {
            fatalError("AuthPresentationContextProvider: no window scene available")
        }
        if let window = anchorScene.windows.first(where: { $0.isKeyWindow }) ?? anchorScene.windows.first {
            return window
        }
        return UIWindow(windowScene: anchorScene)
    }
}
