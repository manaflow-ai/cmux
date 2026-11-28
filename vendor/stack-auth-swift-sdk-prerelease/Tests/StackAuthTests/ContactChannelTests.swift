import Testing
import Foundation
@testable import StackAuth

@Suite("Contact Channel Tests")
struct ContactChannelTests {
    
    // MARK: - List Contact Channels Tests
    
    @Test("Should list contact channels after sign up")
    func listContactChannelsAfterSignUp() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        let channels = try await user?.listContactChannels() ?? []
        
        // Should have at least the primary email
        #expect(!channels.isEmpty)
        
        // Find the primary email channel
        var primaryChannel: ContactChannel? = nil
        for channel in channels {
            let channelValue = await channel.value
            let channelIsPrimary = await channel.isPrimary
            if channelValue == email && channelIsPrimary {
                primaryChannel = channel
                break
            }
        }
        #expect(primaryChannel != nil)
    }
    
    @Test("Should have correct contact channel properties")
    func contactChannelProperties() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        let channels = try await user?.listContactChannels() ?? []
        
        guard let channel = channels.first else {
            Issue.record("Expected at least one contact channel")
            return
        }
        
        let channelId = channel.id // nonisolated, no await needed
        let channelType = await channel.type
        let channelValue = await channel.value
        
        #expect(!channelId.isEmpty)
        #expect(channelType == "email")
        #expect(!channelValue.isEmpty)
    }
    
    @Test("Should identify primary contact channel")
    func identifyPrimaryContactChannel() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        let channels = try await user?.listContactChannels() ?? []
        
        // Count primary channels
        var primaryCount = 0
        var primaryValue: String? = nil
        for channel in channels {
            let isPrimary = await channel.isPrimary
            if isPrimary {
                primaryCount += 1
                primaryValue = await channel.value
            }
        }
        
        #expect(primaryCount == 1)
        #expect(primaryValue == email)
    }
    
    // MARK: - Contact Channel via Server
    
    @Test("Should list contact channels via server")
    func listContactChannelsViaServer() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        
        let user = try await app.createUser(email: email)
        
        let channels = try await user.listContactChannels()
        
        #expect(!channels.isEmpty)
        
        // Find the email channel
        var foundChannel: ContactChannel? = nil
        for channel in channels {
            let channelValue = await channel.value
            if channelValue == email {
                foundChannel = channel
                break
            }
        }
        #expect(foundChannel != nil)
        
        // Clean up
        try await user.delete()
    }
    
    @Test("Should handle user with no contact channels")
    func userWithNoContactChannels() async throws {
        let app = TestConfig.createServerApp()
        
        // Create user without email
        let user = try await app.createUser(displayName: "No Email User")
        
        let channels = try await user.listContactChannels()
        
        // Should be empty
        #expect(channels.isEmpty)
        
        // Clean up
        try await user.delete()
    }
    
    @Test("Should show verified status correctly")
    func verifiedStatusCorrect() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        
        // Create user with verified email
        let user = try await app.createUser(email: email, primaryEmailVerified: true)
        
        let channels = try await user.listContactChannels()
        
        // Find the email channel
        var emailChannel: ContactChannel? = nil
        for channel in channels {
            let channelValue = await channel.value
            if channelValue == email {
                emailChannel = channel
                break
            }
        }
        
        let isVerified = await emailChannel?.isVerified
        #expect(isVerified == true)
        
        // Clean up
        try await user.delete()
    }
    
    @Test("Should show unverified status correctly")
    func unverifiedStatusCorrect() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        
        // Create user with unverified email (default)
        let user = try await app.createUser(email: email, primaryEmailVerified: false)
        
        let channels = try await user.listContactChannels()
        
        // Find the email channel
        var emailChannel: ContactChannel? = nil
        for channel in channels {
            let channelValue = await channel.value
            if channelValue == email {
                emailChannel = channel
                break
            }
        }
        
        let isVerified = await emailChannel?.isVerified
        #expect(isVerified == false)
        
        // Clean up
        try await user.delete()
    }
}
