import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StackAuth

/// Shared test configuration
/// Set environment variables to customize test behavior:
/// - NEXT_PUBLIC_STACK_PORT_PREFIX: Port prefix for backend (default: "81")
/// - STACK_SKIP_E2E_TESTS: Set to "true" to skip E2E tests
struct TestConfig {
    static let portPrefix = ProcessInfo.processInfo.environment["NEXT_PUBLIC_STACK_PORT_PREFIX"] ?? "81"
    static let baseUrl = "http://localhost:\(portPrefix)02"
    static let skipE2E = ProcessInfo.processInfo.environment["STACK_SKIP_E2E_TESTS"] == "true"
    
    // Test credentials - these should match the test project in the backend
    // See apps/e2e/.env.development for the source of truth
    static let projectId = "internal"
    static let publishableClientKey = "this-publishable-client-key-is-for-local-development-only"
    static let secretServerKey = "this-secret-server-key-is-for-local-development-only"
    
    /// Check if backend is accessible
    static func isBackendAvailable() async -> Bool {
        guard !skipE2E else { return false }
        
        guard let url = URL(string: "\(baseUrl)/api/v1/health") else { return false }
        
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                return (200..<300).contains(httpResponse.statusCode)
            }
            return false
        } catch {
            return false
        }
    }
    
    /// Generate a unique test email
    static func uniqueEmail() -> String {
        "test-\(UUID().uuidString.lowercased())@example.com"
    }
    
    /// Generate a unique team name
    static func uniqueTeamName() -> String {
        "Test Team \(UUID().uuidString.prefix(8))"
    }
    
    /// Create a new client app instance for testing.
    /// By default uses a fresh isolated MemoryTokenStore (not from the registry)
    /// to avoid interference between parallel tests.
    static func createClientApp(tokenStore: TokenStoreInit? = nil) -> StackClientApp {
        // Default to a fresh isolated memory store, not the shared registry singleton
        let store = tokenStore ?? .custom(MemoryTokenStore())
        return StackClientApp(
            projectId: projectId,
            publishableClientKey: publishableClientKey,
            baseUrl: baseUrl,
            tokenStore: store,
            noAutomaticPrefetch: true
        )
    }
    
    /// Create a new server app instance for testing
    static func createServerApp() -> StackServerApp {
        StackServerApp(
            projectId: projectId,
            publishableClientKey: publishableClientKey,
            secretServerKey: secretServerKey,
            baseUrl: baseUrl
        )
    }
    
    /// Standard test password that meets requirements
    static let testPassword = "TestPassword123!"
    
    /// Weak password that should be rejected
    static let weakPassword = "123"
}

// MARK: - Convenience Aliases

let baseUrl = TestConfig.baseUrl
let testProjectId = TestConfig.projectId
let testPublishableClientKey = TestConfig.publishableClientKey
let testSecretServerKey = TestConfig.secretServerKey
