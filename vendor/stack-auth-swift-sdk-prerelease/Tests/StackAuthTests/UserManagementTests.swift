import Testing
import Foundation
@testable import StackAuth

@Suite("User Management Tests - Client")
struct ClientUserTests {
    
    // MARK: - User Profile Tests
    
    @Test("Should get user properties after sign up")
    func getUserProperties() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        #expect(user != nil)
        
        let id = await user?.id
        let primaryEmail = await user?.primaryEmail
        let displayName = await user?.displayName
        
        #expect(id != nil)
        #expect(!id!.isEmpty)
        #expect(primaryEmail == email)
        #expect(displayName == nil) // Not set yet
    }
    
    @Test("Should update display name")
    func updateDisplayName() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        #expect(user != nil)
        
        let newName = "Test User \(UUID().uuidString.prefix(8))"
        try await user?.setDisplayName(newName)
        
        let displayName = await user?.displayName
        #expect(displayName == newName)
    }
    
    @Test("Should update display name multiple times")
    func updateDisplayNameMultipleTimes() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        
        // First set a name
        try await user?.setDisplayName("First Name")
        var displayName = await user?.displayName
        #expect(displayName == "First Name")
        
        // Then change it
        try await user?.setDisplayName("Second Name")
        displayName = await user?.displayName
        #expect(displayName == "Second Name")
    }
    
    @Test("Should update client metadata")
    func updateClientMetadata() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        #expect(user != nil)
        
        let metadata: [String: Any] = [
            "theme": "dark",
            "language": "en",
            "notifications": true,
            "count": 42
        ]
        try await user?.update(clientMetadata: metadata)
        
        let clientMetadata = await user?.clientMetadata
        #expect(clientMetadata?["theme"] as? String == "dark")
        #expect(clientMetadata?["language"] as? String == "en")
        #expect(clientMetadata?["notifications"] as? Bool == true)
        #expect(clientMetadata?["count"] as? Int == 42)
    }
    
    @Test("Should get partial user from token")
    func getPartialUser() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let partialUser = await app.getPartialUser()
        #expect(partialUser != nil)
        #expect(partialUser?.primaryEmail == email)
        #expect(partialUser?.id != nil)
    }
    
    @Test("Should get access token after authentication")
    func getAccessToken() async throws {
        let app = TestConfig.createClientApp()
        
        // No token before sign in
        let tokenBefore = await app.getAccessToken()
        #expect(tokenBefore == nil)
        
        let email = TestConfig.uniqueEmail()
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        // Token after sign in
        let tokenAfter = await app.getAccessToken()
        #expect(tokenAfter != nil)
        #expect(!tokenAfter!.isEmpty)
    }
    
    @Test("Should get auth headers for API calls")
    func getAuthHeaders() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let headers = await app.getAuthHeaders()
        #expect(headers["x-stack-auth"] != nil)
        #expect(!headers["x-stack-auth"]!.isEmpty)
    }
}

@Suite("User Management Tests - Server")
struct ServerUserTests {
    
    // MARK: - User Creation Tests
    
    @Test("Should create user with email only")
    func createUserWithEmailOnly() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        
        let user = try await app.createUser(email: email)
        
        let primaryEmail = await user.primaryEmail
        #expect(primaryEmail == email)
        
        // Clean up
        try await user.delete()
    }
    
    @Test("Should create user with all options")
    func createUserWithAllOptions() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        let displayName = "Full User \(UUID().uuidString.prefix(8))"
        
        let user = try await app.createUser(
            email: email,
            password: TestConfig.testPassword,
            displayName: displayName,
            primaryEmailVerified: true,
            clientMetadata: ["role": "admin"],
            serverMetadata: ["internal_id": "12345"]
        )
        
        let userEmail = await user.primaryEmail
        let userName = await user.displayName
        let clientMeta = await user.clientMetadata
        let serverMeta = await user.serverMetadata
        
        #expect(userEmail == email)
        #expect(userName == displayName)
        #expect(clientMeta["role"] as? String == "admin")
        #expect(serverMeta["internal_id"] as? String == "12345")
        
        // Clean up
        try await user.delete()
    }
    
    @Test("Should create user without email")
    func createUserWithoutEmail() async throws {
        let app = TestConfig.createServerApp()
        
        let user = try await app.createUser(displayName: "No Email User")
        
        let primaryEmail = await user.primaryEmail
        let displayName = await user.displayName
        
        #expect(primaryEmail == nil)
        #expect(displayName == "No Email User")
        
        // Clean up
        try await user.delete()
    }
    
    // MARK: - User Retrieval Tests
    
    @Test("Should list users with pagination")
    func listUsersWithPagination() async throws {
        let app = TestConfig.createServerApp()
        
        // Create a few users
        var createdUsers: [ServerUser] = []
        for _ in 0..<3 {
            let user = try await app.createUser(email: TestConfig.uniqueEmail())
            createdUsers.append(user)
        }
        
        // List with limit
        let result = try await app.listUsers(limit: 2)
        #expect(!result.items.isEmpty)
        #expect(result.items.count <= 2)
        
        // Clean up
        for user in createdUsers {
            try await user.delete()
        }
    }
    
    @Test("Should get user by ID")
    func getUserById() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        
        let createdUser = try await app.createUser(email: email)
        let userId = createdUser.id
        
        let fetchedUser = try await app.getUser(id: userId)
        
        #expect(fetchedUser != nil)
        
        let fetchedEmail = await fetchedUser?.primaryEmail
        #expect(fetchedEmail == email)
        
        // Clean up
        try await createdUser.delete()
    }
    
    @Test("Should return nil for non-existent user")
    func getNonExistentUser() async throws {
        let app = TestConfig.createServerApp()
        
        let fakeUserId = UUID().uuidString
        let user = try await app.getUser(id: fakeUserId)
        
        #expect(user == nil)
    }
    
    // MARK: - User Update Tests
    
    @Test("Should update user display name")
    func updateUserDisplayName() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        
        let user = try await app.createUser(email: email)
        
        let newName = "Updated Name \(UUID().uuidString.prefix(8))"
        try await user.update(displayName: newName)
        
        let displayName = await user.displayName
        #expect(displayName == newName)
        
        // Clean up
        try await user.delete()
    }
    
    @Test("Should update server metadata")
    func updateServerMetadata() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        
        let user = try await app.createUser(email: email)
        
        let metadata: [String: Any] = [
            "internalKey": "internalValue",
            "score": 100,
            "verified": true
        ]
        try await user.update(serverMetadata: metadata)
        
        let serverMeta = await user.serverMetadata
        #expect(serverMeta["internalKey"] as? String == "internalValue")
        #expect(serverMeta["score"] as? Int == 100)
        #expect(serverMeta["verified"] as? Bool == true)
        
        // Clean up
        try await user.delete()
    }
    
    @Test("Should update client metadata via server")
    func updateClientMetadataViaServer() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        
        let user = try await app.createUser(email: email)
        
        try await user.update(clientMetadata: ["preference": "light"])
        
        let clientMeta = await user.clientMetadata
        #expect(clientMeta["preference"] as? String == "light")
        
        // Clean up
        try await user.delete()
    }
    
    @Test("Should update multiple fields at once")
    func updateMultipleFields() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        
        let user = try await app.createUser(email: email)
        
        try await user.update(
            displayName: "Multi Update User",
            clientMetadata: ["key": "value"],
            serverMetadata: ["serverKey": "serverValue"]
        )
        
        let displayName = await user.displayName
        let clientMeta = await user.clientMetadata
        let serverMeta = await user.serverMetadata
        
        #expect(displayName == "Multi Update User")
        #expect(clientMeta["key"] as? String == "value")
        #expect(serverMeta["serverKey"] as? String == "serverValue")
        
        // Clean up
        try await user.delete()
    }
    
    // MARK: - Password Management
    
    @Test("Should create user with password and sign in")
    func createUserWithPasswordAndSignIn() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        
        // Create user with password
        let user = try await app.createUser(
            email: email,
            password: TestConfig.testPassword,
            primaryEmailAuthEnabled: true
        )
        
        // Verify can sign in with password
        let clientApp = TestConfig.createClientApp()
        try await clientApp.signInWithCredential(email: email, password: TestConfig.testPassword)
        
        let signedInUser = try await clientApp.getUser()
        #expect(signedInUser != nil)
        
        // Clean up
        try await user.delete()
    }
    
    // MARK: - User Deletion Tests
    
    @Test("Should delete user")
    func deleteUser() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        
        let user = try await app.createUser(email: email)
        let userId = user.id
        
        // Verify user exists
        let fetchedUser = try await app.getUser(id: userId)
        #expect(fetchedUser != nil)
        
        // Delete user
        try await user.delete()
        
        // Verify user is deleted
        let deletedUser = try await app.getUser(id: userId)
        #expect(deletedUser == nil)
    }
    
    // MARK: - Session/Impersonation Tests
    
    @Test("Should create session for impersonation")
    func createSession() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        
        let user = try await app.createUser(email: email)
        let userId = user.id
        
        let tokens = try await app.createSession(userId: userId)
        
        #expect(!tokens.accessToken.isEmpty)
        #expect(!tokens.refreshToken.isEmpty)
        
        // Verify the tokens work
        let clientApp = StackClientApp(
            projectId: testProjectId,
            publishableClientKey: testPublishableClientKey,
            baseUrl: baseUrl,
            tokenStore: .explicit(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken),
            noAutomaticPrefetch: true
        )
        
        let currentUser = try await clientApp.getUser()
        #expect(currentUser != nil)
        
        let currentUserId = await currentUser?.id
        #expect(currentUserId == userId)
        
        // Clean up
        try await user.delete()
    }
}
