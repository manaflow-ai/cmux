import Testing
import Foundation
@testable import StackAuth

@Suite("Error Handling Tests")
struct ErrorHandlingTests {
    
    // MARK: - Authentication Errors
    
    @Test("Should throw EmailPasswordMismatchError for wrong credentials")
    func emailPasswordMismatchError() async throws {
        let app = TestConfig.createClientApp()
        
        do {
            try await app.signInWithCredential(email: "nonexistent@example.com", password: "wrong")
            Issue.record("Expected EmailPasswordMismatchError")
        } catch is EmailPasswordMismatchError {
            // Expected
        } catch let error as StackAuthErrorProtocol where error.code == "EMAIL_PASSWORD_MISMATCH" {
            // Also acceptable
        }
    }
    
    @Test("Should throw UserWithEmailAlreadyExistsError for duplicate sign up")
    func userAlreadyExistsError() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        try await app.signOut()
        
        do {
            try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
            Issue.record("Expected UserWithEmailAlreadyExistsError")
        } catch is UserWithEmailAlreadyExistsError {
            // Expected
        } catch let error as StackAuthErrorProtocol where error.code == "USER_EMAIL_ALREADY_EXISTS" {
            // Also acceptable
        }
    }
    
    @Test("Should throw UserNotSignedInError for unauthenticated access")
    func userNotSignedInError() async throws {
        let app = TestConfig.createClientApp()
        
        await #expect(throws: UserNotSignedInError.self) {
            _ = try await app.getUser(or: .throw)
        }
    }
    
    // MARK: - Error Properties
    
    @Test("Should include error code in error")
    func errorIncludesCode() async throws {
        let app = TestConfig.createClientApp()
        
        do {
            try await app.signInWithCredential(email: "nonexistent@example.com", password: "wrong")
            Issue.record("Expected error")
        } catch let error as StackAuthErrorProtocol {
            #expect(!error.code.isEmpty)
            #expect(error.code == "EMAIL_PASSWORD_MISMATCH")
        }
    }
    
    @Test("Should include error message in error")
    func errorIncludesMessage() async throws {
        let app = TestConfig.createClientApp()
        
        do {
            try await app.signInWithCredential(email: "nonexistent@example.com", password: "wrong")
            Issue.record("Expected error")
        } catch let error as StackAuthErrorProtocol {
            #expect(!error.message.isEmpty)
        }
    }
    
    @Test("Should have meaningful error description")
    func errorHasMeaningfulDescription() async throws {
        let app = TestConfig.createClientApp()
        
        do {
            try await app.signInWithCredential(email: "nonexistent@example.com", password: "wrong")
            Issue.record("Expected error")
        } catch let error as StackAuthErrorProtocol {
            let description = error.description
            #expect(!description.isEmpty)
            #expect(description.contains("EMAIL_PASSWORD_MISMATCH") || description.contains("password"))
        }
    }
    
    // MARK: - Error Type Matching
    
    @Test("Should match StackAuthError for unknown error codes")
    func unknownErrorCodeMatchesStackAuthError() async throws {
        // Create a StackAuthError with unknown code
        let error = StackAuthError(code: "UNKNOWN_ERROR_CODE", message: "Test error")
        
        #expect(error.code == "UNKNOWN_ERROR_CODE")
        #expect(error.message == "Test error")
    }
    
    @Test("Should properly identify specific error types")
    func identifySpecificErrorTypes() async throws {
        let emailError = EmailPasswordMismatchError()
        let userExistsError = UserWithEmailAlreadyExistsError()
        let notSignedInError = UserNotSignedInError()
        
        #expect(emailError.code == "EMAIL_PASSWORD_MISMATCH")
        #expect(userExistsError.code == "USER_EMAIL_ALREADY_EXISTS")
        #expect(notSignedInError.code == "USER_NOT_SIGNED_IN")
    }
    
    // MARK: - Error Recovery
    
    @Test("Should be able to retry after authentication error")
    func retryAfterAuthError() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        // Sign up
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        try await app.signOut()
        
        // First try with wrong password
        do {
            try await app.signInWithCredential(email: email, password: "WrongPassword123!")
        } catch is EmailPasswordMismatchError {
            // Expected
        }
        
        // Should still be able to sign in with correct password
        try await app.signInWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        #expect(user != nil)
    }
    
    // MARK: - Server-Side Errors
    
    @Test("Should handle user not found for server operations")
    func serverUserNotFound() async throws {
        let app = TestConfig.createServerApp()
        
        let fakeUserId = UUID().uuidString
        let user = try await app.getUser(id: fakeUserId)
        
        // Should return nil, not throw
        #expect(user == nil)
    }
    
    @Test("Should handle team not found for server operations")
    func serverTeamNotFound() async throws {
        let app = TestConfig.createServerApp()
        
        let fakeTeamId = UUID().uuidString
        let team = try await app.getTeam(id: fakeTeamId)
        
        // Should return nil, not throw
        #expect(team == nil)
    }
    
    // MARK: - Password Errors
    
    @Test("Should throw for weak password")
    func weakPasswordError() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        do {
            try await app.signUpWithCredential(email: email, password: "123")
            Issue.record("Expected password error")
        } catch is PasswordRequirementsNotMetError {
            // Expected
        } catch let error as StackAuthErrorProtocol where error.code == "PASSWORD_REQUIREMENTS_NOT_MET" || error.code == "PASSWORD_TOO_SHORT" {
            // Also acceptable - different error codes for password issues
        }
    }
    
    @Test("Should throw PasswordConfirmationMismatchError for wrong old password")
    func wrongOldPasswordError() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        
        do {
            try await user?.updatePassword(oldPassword: "WrongOld123!", newPassword: "NewPass456!")
            Issue.record("Expected PasswordConfirmationMismatchError")
        } catch is PasswordConfirmationMismatchError {
            // Expected
        } catch let error as StackAuthErrorProtocol where error.code == "PASSWORD_CONFIRMATION_MISMATCH" {
            // Also acceptable
        }
    }
}

@Suite("Project Tests")
struct ProjectTests {
    
    // MARK: - Project Info Tests
    
    @Test("Should get project info via client")
    func getProjectViaClient() async throws {
        let app = TestConfig.createClientApp()
        
        let project = try await app.getProject()
        
        #expect(project.id == testProjectId)
    }
    
    @Test("Should get project info via server")
    func getProjectViaServer() async throws {
        let app = TestConfig.createServerApp()
        
        let project = try await app.getProject()
        
        #expect(project.id == testProjectId)
    }
    
    @Test("Should access project config")
    func accessProjectConfig() async throws {
        let app = TestConfig.createClientApp()
        
        let project = try await app.getProject()
        
        // Config should exist (even if empty)
        let _ = project.config
    }
    
    @Test("Should create client app with correct project ID")
    func createClientAppWithProjectId() async throws {
        let app = TestConfig.createClientApp()
        
        let projectId = await app.projectId
        #expect(projectId == testProjectId)
    }
    
    @Test("Should create server app with correct project ID")
    func createServerAppWithProjectId() async throws {
        let app = TestConfig.createServerApp()
        
        let projectId = await app.projectId
        #expect(projectId == testProjectId)
    }
}
