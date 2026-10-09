import Testing
import Foundation
@testable import StackAuth

@Suite("Token Storage Tests")
struct TokenStorageTests {
    
    // MARK: - Memory Token Store Tests
    
    @Test("Should store and retrieve tokens")
    func tokenStorage() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let accessToken = await app.getAccessToken()
        let refreshToken = await app.getRefreshToken()
        
        #expect(accessToken != nil)
        #expect(refreshToken != nil)
        #expect(!accessToken!.isEmpty)
        #expect(!refreshToken!.isEmpty)
    }
    
    @Test("Should clear tokens on sign out")
    func tokensClearedOnSignOut() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let tokenBefore = await app.getAccessToken()
        #expect(tokenBefore != nil)
        
        try await app.signOut()
        
        let tokenAfter = await app.getAccessToken()
        #expect(tokenAfter == nil)
    }
    
    // MARK: - Explicit Token Store Tests
    
    @Test("Should use explicitly provided tokens")
    func explicitTokenStore() async throws {
        // First, get real tokens
        let app1 = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app1.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let accessToken = await app1.getAccessToken()
        let refreshToken = await app1.getRefreshToken()
        
        #expect(accessToken != nil)
        #expect(refreshToken != nil)
        
        // Now use explicit store with those tokens
        let app2 = StackClientApp(
            projectId: testProjectId,
            publishableClientKey: testPublishableClientKey,
            baseUrl: baseUrl,
            tokenStore: .explicit(accessToken: accessToken!, refreshToken: refreshToken!),
            noAutomaticPrefetch: true
        )
        
        let user = try await app2.getUser()
        #expect(user != nil)
        
        let userEmail = await user?.primaryEmail
        #expect(userEmail == email)
    }
    
    @Test("Should work with both tokens provided")
    func explicitBothTokens() async throws {
        // Get real tokens
        let app1 = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app1.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let accessToken = await app1.getAccessToken()
        let refreshToken = await app1.getRefreshToken()
        #expect(accessToken != nil)
        #expect(refreshToken != nil)
        
        // Use both tokens
        let app2 = StackClientApp(
            projectId: testProjectId,
            publishableClientKey: testPublishableClientKey,
            baseUrl: baseUrl,
            tokenStore: .explicit(accessToken: accessToken!, refreshToken: refreshToken!),
            noAutomaticPrefetch: true
        )
        
        // Should work for requests
        let user = try await app2.getUser()
        #expect(user != nil)
    }
    
    // MARK: - Token Format Tests
    
    @Test("Should return JWT format access token")
    func accessTokenIsJwt() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let accessToken = await app.getAccessToken()
        #expect(accessToken != nil)
        
        // JWT has three parts separated by dots
        let parts = accessToken!.split(separator: ".")
        #expect(parts.count == 3)
    }
    
    @Test("Should return refresh token in correct format")
    func refreshTokenFormat() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let refreshToken = await app.getRefreshToken()
        #expect(refreshToken != nil)
        #expect(!refreshToken!.isEmpty)
        // Refresh token should be a reasonable length
        #expect(refreshToken!.count > 10)
    }
    
    // MARK: - Auth Headers Tests
    
    @Test("Should generate auth headers with token")
    func authHeadersWithToken() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let headers = await app.getAuthHeaders()
        
        #expect(headers["x-stack-auth"] != nil)
        #expect(!headers["x-stack-auth"]!.isEmpty)
    }
    
    @Test("Should generate consistent auth headers format")
    func authHeadersFormat() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let headers = await app.getAuthHeaders()
        
        // When authenticated, x-stack-auth should be present and contain the token
        let authHeader = headers["x-stack-auth"]
        #expect(authHeader != nil)
        #expect(!authHeader!.isEmpty)
    }
    
    // MARK: - Partial User from Token Tests
    
    @Test("Should get partial user from token without API call")
    func partialUserFromToken() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let partialUser = await app.getPartialUser()
        
        #expect(partialUser != nil)
        #expect(partialUser?.id != nil)
        #expect(partialUser?.primaryEmail == email)
    }
    
    @Test("Should return nil partial user when not authenticated")
    func partialUserWhenNotAuthenticated() async throws {
        let app = TestConfig.createClientApp()
        
        let partialUser = await app.getPartialUser()
        
        #expect(partialUser == nil)
    }
    
    // MARK: - Token Persistence Between Apps
    
    @Test("Should share tokens between app instances with explicit store")
    func shareTokensBetweenApps() async throws {
        // Get tokens from first app
        let app1 = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app1.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let accessToken = await app1.getAccessToken()
        let refreshToken = await app1.getRefreshToken()
        
        // Create second app with explicit tokens
        let app2 = StackClientApp(
            projectId: testProjectId,
            publishableClientKey: testPublishableClientKey,
            baseUrl: baseUrl,
            tokenStore: .explicit(accessToken: accessToken!, refreshToken: refreshToken!),
            noAutomaticPrefetch: true
        )
        
        // Both should have same user
        let user1 = try await app1.getUser()
        let user2 = try await app2.getUser()
        
        let id1 = await user1?.id
        let id2 = await user2?.id
        
        #expect(id1 == id2)
    }
    
    @Test("Should share memory store between app instances via registry")
    func memoryStoreRegistrySingleton() async throws {
        // Reset registry to ensure clean state for this test
        TokenStoreRegistry.shared.reset()
        
        // Create first app and sign in
        let app1 = TestConfig.createClientApp(tokenStore: .memory)
        let email = TestConfig.uniqueEmail()
        try await app1.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        // Capture the token immediately after sign-up
        let token1 = await app1.getAccessToken()
        #expect(token1 != nil, "Should have token after sign-up")
        
        // Create second app with same projectId and .memory
        // Thanks to the registry, this should share the same underlying MemoryTokenStore
        let app2 = TestConfig.createClientApp(tokenStore: .memory)
        
        // app2 should see the same tokens as app1 (no sign-in needed)
        let token2 = await app2.getAccessToken()
        
        #expect(token1 == token2, "Memory stores with same projectId should share tokens via registry")
        
        // Both should return the same user
        let user1 = try await app1.getUser()
        let user2 = try await app2.getUser()
        
        let email1 = await user1?.primaryEmail
        let email2 = await user2?.primaryEmail
        
        #expect(email1 == email)
        #expect(email2 == email)
    }
    
    // MARK: - Null Token Store Tests
    
    @Test("Should work with null token store for anonymous requests")
    func nullTokenStore() async throws {
        let app = StackClientApp(
            projectId: testProjectId,
            publishableClientKey: testPublishableClientKey,
            baseUrl: baseUrl,
            tokenStore: .none,
            noAutomaticPrefetch: true
        )
        
        // Should be able to make unauthenticated requests (like getProject)
        let project = try await app.getProject()
        #expect(project.id == testProjectId)
    }
    
    // MARK: - Token Store Override Tests
    
    // Note: Calling getAccessToken/getRefreshToken/getAuthHeaders/getPartialUser without tokenStore
    // when constructor tokenStore is .none will cause a fatalError (panic).
    // This is a programmer error and cannot be tested via normal test assertions.
    
    @Test("Should use tokenStore override when provided")
    func tokenStoreOverride() async throws {
        // Create an app with tokens
        let app1 = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app1.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let accessToken = await app1.getAccessToken()
        let refreshToken = await app1.getRefreshToken()
        #expect(accessToken != nil)
        #expect(refreshToken != nil)
        
        // Create an app with tokenStore: .none
        let app2 = StackClientApp(
            projectId: testProjectId,
            publishableClientKey: testPublishableClientKey,
            baseUrl: baseUrl,
            tokenStore: .none,
            noAutomaticPrefetch: true
        )
        
        // Should work when providing tokenStore override
        let overrideStore = TokenStoreInit.explicit(accessToken: accessToken!, refreshToken: refreshToken!)
        
        let user = try await app2.getUser(tokenStore: overrideStore)
        #expect(user != nil)
        
        let userEmail = await user?.primaryEmail
        #expect(userEmail == email)
        
        // getAccessToken with override should also work
        let token = await app2.getAccessToken(tokenStore: overrideStore)
        #expect(token == accessToken)
        
        // getPartialUser with override should also work
        let partialUser = await app2.getPartialUser(tokenStore: overrideStore)
        #expect(partialUser != nil)
        #expect(partialUser?.primaryEmail == email)
    }
    
    @Test("Should allow tokenStore override even when constructor has token store")
    func tokenStoreOverrideWithDefaultStore() async throws {
        // Create two users with explicit token stores to keep them separate
        
        // Create user1 and capture their tokens
        let setupApp1 = TestConfig.createClientApp()
        let email1 = TestConfig.uniqueEmail()
        try await setupApp1.signUpWithCredential(email: email1, password: TestConfig.testPassword)
        let tokens1 = (
            access: await setupApp1.getAccessToken()!,
            refresh: await setupApp1.getRefreshToken()!
        )
        
        // Create user2 and capture their tokens (this overwrites the shared memory store, but we have tokens1 saved)
        let email2 = TestConfig.uniqueEmail()
        try await setupApp1.signOut()
        try await setupApp1.signUpWithCredential(email: email2, password: TestConfig.testPassword)
        let tokens2 = (
            access: await setupApp1.getAccessToken()!,
            refresh: await setupApp1.getRefreshToken()!
        )
        
        // Now create an app with user1's tokens as default
        let app = TestConfig.createClientApp(tokenStore: .explicit(accessToken: tokens1.access, refreshToken: tokens1.refresh))
        
        // Default store should return user1
        let user1Default = try await app.getUser()
        let email1Default = await user1Default?.primaryEmail
        #expect(email1Default == email1)
        
        // With an override, can access user2
        let overrideStore = TokenStoreInit.explicit(accessToken: tokens2.access, refreshToken: tokens2.refresh)
        let user2FromApp = try await app.getUser(tokenStore: overrideStore)
        let email2FromApp = await user2FromApp?.primaryEmail
        #expect(email2FromApp == email2)
        
        // Default should still be user1
        let user1Again = try await app.getUser()
        let email1Again = await user1Again?.primaryEmail
        #expect(email1Again == email1)
    }
}
