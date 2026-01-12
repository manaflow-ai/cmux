import Foundation
import Combine
import ConvexMobile

// Convex client singleton for the app
// Docs: https://docs.convex.dev/client/swift
// API: subscribe(to:with:), mutation(_:with:), action(_:with:)

@MainActor
class ConvexClientManager: ObservableObject {
    static let shared = ConvexClientManager()

    let client: ConvexClientWithAuth<StackAuthResult>
    private var cancellables = Set<AnyCancellable>()

    @Published var isAuthenticated = false

    private init() {
        let env = Environment.current
        let provider = StackAuthProvider()
        client = ConvexClientWithAuth(deploymentUrl: env.convexURL, authProvider: provider)
        print("📦 Convex initialized (\(env.name)): \(env.convexURL)")

        // Observe auth state changes
        print("📦 Convex: Setting up authState subscription...")
        client.authState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                print("📦 Convex: authState changed to: \(state)")
                switch state {
                case .authenticated(let authResult):
                    self?.isAuthenticated = true
                    print("📦 Convex: ✅ Authenticated (user: \(authResult.user.primary_email ?? "?"))")
                case .unauthenticated:
                    self?.isAuthenticated = false
                    print("📦 Convex: ❌ Unauthenticated")
                case .loading:
                    print("📦 Convex: ⏳ Auth loading...")
                }
            }
            .store(in: &cancellables)
        print("📦 Convex: authState subscription active, cancellables count: \(cancellables.count)")
    }

    /// Sync auth state with Stack Auth after user logs in via AuthManager
    /// Returns a description of what happened for debugging
    @discardableResult
    func syncAuth() async -> String {
        print("📦 Convex: Starting auth sync...")
        let result = await client.loginFromCache()
        switch result {
        case .success(let authResult):
            print("📦 Convex: Auth sync SUCCESS for \(authResult.user.primary_email ?? "unknown")")
            print("📦 Convex: Token was passed to ffiClient.setAuth()")
            // Give Convex a moment to process the token
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            print("📦 Convex: isAuthenticated = \(isAuthenticated)")
            return "SUCCESS: \(authResult.user.primary_email ?? "unknown"), isAuth=\(isAuthenticated)"
        case .failure(let error):
            print("📦 Convex: Auth sync FAILED - \(error)")
            return "FAILED: \(error)"
        }
    }

    /// Clear Convex auth state when user logs out
    func clearAuth() async {
        await client.logout()
    }
}
