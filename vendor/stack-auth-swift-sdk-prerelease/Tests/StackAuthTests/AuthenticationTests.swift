import Testing
import Foundation
@testable import StackAuth

@Suite("Authentication Tests")
struct AuthenticationTests {
    
    // MARK: - Sign Up Tests
    
    @Test("Should sign up with valid credentials")
    func signUpWithValidCredentials() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        #expect(user != nil)
        
        let primaryEmail = await user?.primaryEmail
        #expect(primaryEmail == email)
    }
    
    @Test("Should fail sign up with duplicate email")
    func signUpWithDuplicateEmail() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        // First sign up
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        try await app.signOut()
        
        // Second sign up with same email should fail
        do {
            try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
            Issue.record("Expected UserWithEmailAlreadyExistsError")
        } catch is UserWithEmailAlreadyExistsError {
            // Expected
        } catch let error as StackAuthErrorProtocol where error.code == "USER_EMAIL_ALREADY_EXISTS" {
            // Also acceptable
        }
    }
    
    @Test("Should fail sign up with weak password")
    func signUpWithWeakPassword() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        do {
            try await app.signUpWithCredential(email: email, password: TestConfig.weakPassword)
            Issue.record("Expected password error")
        } catch is PasswordRequirementsNotMetError {
            // Expected
        } catch let error as StackAuthErrorProtocol where error.code == "PASSWORD_REQUIREMENTS_NOT_MET" || error.code == "PASSWORD_TOO_SHORT" {
            // Also acceptable - different error codes for password issues
        }
    }
    
    @Test("Should fail sign up with invalid email format")
    func signUpWithInvalidEmail() async throws {
        let app = TestConfig.createClientApp()
        
        do {
            try await app.signUpWithCredential(email: "not-an-email", password: TestConfig.testPassword)
            Issue.record("Expected error for invalid email")
        } catch {
            // Expected - any error is acceptable for invalid email
        }
    }
    
    // MARK: - Sign In Tests
    
    @Test("Should sign in with valid credentials")
    func signInWithValidCredentials() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        // First sign up
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        try await app.signOut()
        
        // Then sign in
        try await app.signInWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        #expect(user != nil)
        
        let userEmail = await user?.primaryEmail
        #expect(userEmail == email)
    }
    
    @Test("Should fail sign in with wrong password")
    func signInWithWrongPassword() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        // First sign up
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        try await app.signOut()
        
        // Try sign in with wrong password
        do {
            try await app.signInWithCredential(email: email, password: "WrongPassword123!")
            Issue.record("Expected EmailPasswordMismatchError")
        } catch is EmailPasswordMismatchError {
            // Expected
        }
    }
    
    @Test("Should fail sign in with non-existent user")
    func signInWithNonExistentUser() async throws {
        let app = TestConfig.createClientApp()
        
        do {
            try await app.signInWithCredential(email: "nonexistent-\(UUID().uuidString)@example.com", password: TestConfig.testPassword)
            Issue.record("Expected EmailPasswordMismatchError")
        } catch is EmailPasswordMismatchError {
            // Expected - returns same error as wrong password for security
        }
    }
    
    @Test("Should fail sign in with empty password")
    func signInWithEmptyPassword() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        try await app.signOut()
        
        do {
            try await app.signInWithCredential(email: email, password: "")
            Issue.record("Expected error for empty password")
        } catch {
            // Expected - any error is acceptable for empty password
        }
    }
    
    // MARK: - Sign Out Tests
    
    @Test("Should sign out successfully")
    func signOutSuccessfully() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let userBefore = try await app.getUser()
        #expect(userBefore != nil)
        
        try await app.signOut()
        
        let userAfter = try await app.getUser()
        #expect(userAfter == nil)
    }
    
    @Test("Should be able to sign out when not signed in")
    func signOutWhenNotSignedIn() async throws {
        let app = TestConfig.createClientApp()
        
        // Should not throw even when not signed in
        try await app.signOut()
        
        let user = try await app.getUser()
        #expect(user == nil)
    }
    
    @Test("Should clear tokens after sign out")
    func clearTokensAfterSignOut() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let tokenBefore = await app.getAccessToken()
        #expect(tokenBefore != nil)
        
        try await app.signOut()
        
        let tokenAfter = await app.getAccessToken()
        #expect(tokenAfter == nil)
    }
    
    // MARK: - Multiple Auth Cycles
    
    @Test("Should handle multiple sign in/out cycles")
    func multipleAuthCycles() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        // Sign up
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        var user = try await app.getUser()
        #expect(user != nil)
        
        // Sign out and in again (3 cycles)
        for _ in 1...3 {
            try await app.signOut()
            user = try await app.getUser()
            #expect(user == nil)
            
            try await app.signInWithCredential(email: email, password: TestConfig.testPassword)
            user = try await app.getUser()
            #expect(user != nil)
        }
    }
    
    // MARK: - Password Management
    
    @Test("Should update password for authenticated user")
    func updatePassword() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        let newPassword = "NewPassword456!"
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        #expect(user != nil)
        
        try await user?.updatePassword(
            oldPassword: TestConfig.testPassword,
            newPassword: newPassword
        )
        
        // Sign out and sign in with new password
        try await app.signOut()
        try await app.signInWithCredential(email: email, password: newPassword)
        
        let userAfter = try await app.getUser()
        #expect(userAfter != nil)
    }
    
    @Test("Should fail password update with wrong old password")
    func updatePasswordWithWrongOldPassword() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        #expect(user != nil)
        
        do {
            try await user?.updatePassword(
                oldPassword: "WrongOldPassword!",
                newPassword: "NewPassword456!"
            )
            Issue.record("Expected PasswordConfirmationMismatchError")
        } catch is PasswordConfirmationMismatchError {
            // Expected
        } catch let error as StackAuthErrorProtocol where error.code == "PASSWORD_CONFIRMATION_MISMATCH" {
            // Also acceptable
        }
    }
    
    // MARK: - Unauthenticated User Tests
    
    @Test("Should return nil for unauthenticated user")
    func unauthenticatedUserReturnsNil() async throws {
        let app = TestConfig.createClientApp()
        
        let user = try await app.getUser()
        
        #expect(user == nil)
    }
    
    @Test("Should throw for unauthenticated user with or: throw")
    func unauthenticatedUserThrows() async throws {
        let app = TestConfig.createClientApp()
        
        await #expect(throws: UserNotSignedInError.self) {
            _ = try await app.getUser(or: .throw)
        }
    }
    
    @Test("Should return nil for partial user when unauthenticated")
    func unauthenticatedPartialUserReturnsNil() async throws {
        let app = TestConfig.createClientApp()
        
        let partialUser = await app.getPartialUser()
        
        #expect(partialUser == nil)
    }
}
