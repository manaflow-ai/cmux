import Testing
import Foundation
@testable import StackAuth

@Suite("Team Tests - Client")
struct ClientTeamTests {
    
    // MARK: - Team Creation Tests
    
    @Test("Should create team with display name")
    func createTeamWithDisplayName() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        #expect(user != nil)
        
        let teamName = TestConfig.uniqueTeamName()
        let team = try await user?.createTeam(displayName: teamName)
        
        #expect(team != nil)
        
        let displayName = await team?.displayName
        #expect(displayName == teamName)
    }
    
    @Test("Should create team with metadata")
    func createTeamWithMetadata() async throws {
        // Use server app for full control over team creation
        let serverApp = TestConfig.createServerApp()
        let teamName = TestConfig.uniqueTeamName()
        
        let team = try await serverApp.createTeam(
            displayName: teamName,
            clientMetadata: ["type": "test"]
        )
        
        let clientMetadata: [String: Any] = await team.clientMetadata
        let typeValue = clientMetadata["type"] as? String
        #expect(typeValue == "test")
        
        // Clean up
        try await team.delete()
    }
    
    @Test("Should add creator to team on creation")
    func creatorAddedToTeam() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        let userId = await user?.id
        
        let team = try await user?.createTeam(displayName: TestConfig.uniqueTeamName())
        
        // List team users and verify creator is included
        let teamUsers = try await team?.listUsers() ?? []
        let creatorFound = teamUsers.contains { $0.id == userId }
        #expect(creatorFound)
    }
    
    // MARK: - Team Listing Tests
    
    @Test("Should list user's teams")
    func listUserTeams() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        
        // Create multiple teams
        let team1 = try await user?.createTeam(displayName: "Team 1 \(UUID().uuidString.prefix(4))")
        let team2 = try await user?.createTeam(displayName: "Team 2 \(UUID().uuidString.prefix(4))")
        
        let teams = try await user?.listTeams() ?? []
        
        #expect(teams.count >= 2)
        #expect(teams.contains { $0.id == team1?.id })
        #expect(teams.contains { $0.id == team2?.id })
    }
    
    @Test("Should get team by ID")
    func getTeamById() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        let teamName = TestConfig.uniqueTeamName()
        let createdTeam = try await user?.createTeam(displayName: teamName)
        let teamId = createdTeam?.id
        
        #expect(teamId != nil)
        
        let fetchedTeam = try await user?.getTeam(id: teamId!)
        
        #expect(fetchedTeam != nil)
        
        let fetchedName = await fetchedTeam?.displayName
        #expect(fetchedName == teamName)
    }
    
    @Test("Should return nil for non-member team")
    func getNonMemberTeam() async throws {
        let serverApp = TestConfig.createServerApp()
        
        // Create a team via server (user not a member)
        let team = try await serverApp.createTeam(displayName: TestConfig.uniqueTeamName())
        let teamId = team.id
        
        // Try to get it as a different user
        let clientApp = TestConfig.createClientApp()
        try await clientApp.signUpWithCredential(email: TestConfig.uniqueEmail(), password: TestConfig.testPassword)
        
        let user = try await clientApp.getUser()
        let fetchedTeam = try await user?.getTeam(id: teamId)
        
        // Should be nil since user is not a member
        #expect(fetchedTeam == nil)
        
        // Clean up
        try await team.delete()
    }
    
    // MARK: - Team Update Tests
    
    @Test("Should update team display name")
    func updateTeamDisplayName() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        let team = try await user?.createTeam(displayName: "Original Name")
        
        let newName = "Updated Name \(UUID().uuidString.prefix(8))"
        try await team?.update(displayName: newName)
        
        let displayName = await team?.displayName
        #expect(displayName == newName)
    }
    
    @Test("Should update team profile image")
    func updateTeamProfileImage() async throws {
        // Use server app for updating team properties to avoid permission issues
        let serverApp = TestConfig.createServerApp()
        
        let team = try await serverApp.createTeam(displayName: TestConfig.uniqueTeamName())
        
        let newImageUrl = "https://example.com/new-image.png"
        try await team.update(profileImageUrl: newImageUrl)
        
        let profileImageUrl = await team.profileImageUrl
        #expect(profileImageUrl == newImageUrl)
        
        // Clean up
        try await team.delete()
    }
    
    @Test("Should update team client metadata")
    func updateTeamClientMetadata() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        let team = try await user?.createTeam(displayName: TestConfig.uniqueTeamName())
        
        try await team?.update(clientMetadata: ["plan": "pro", "seats": 10])
        
        let clientMetadata: [String: Any]? = await team?.clientMetadata
        let planValue = clientMetadata?["plan"] as? String
        let seatsValue = clientMetadata?["seats"] as? Int
        #expect(planValue == "pro")
        #expect(seatsValue == 10)
    }
    
    // MARK: - Team Deletion Tests
    // Note: Client-side team deletion requires specific permissions
    // These tests are covered in the server-side team tests instead
    
    // MARK: - Team Members Tests
    
    @Test("Should list team members")
    func listTeamMembers() async throws {
        let app = TestConfig.createClientApp()
        let email = TestConfig.uniqueEmail()
        
        try await app.signUpWithCredential(email: email, password: TestConfig.testPassword)
        
        let user = try await app.getUser()
        let team = try await user?.createTeam(displayName: TestConfig.uniqueTeamName())
        
        let members = try await team?.listUsers() ?? []
        
        // Should have at least the creator
        #expect(!members.isEmpty)
    }
}

@Suite("Team Tests - Server")
struct ServerTeamTests {
    
    // MARK: - Team Creation Tests
    
    @Test("Should create team with server app")
    func createTeamWithServer() async throws {
        let app = TestConfig.createServerApp()
        let teamName = TestConfig.uniqueTeamName()
        
        let team = try await app.createTeam(displayName: teamName)
        
        let displayName = await team.displayName
        #expect(displayName == teamName)
        
        // Clean up
        try await team.delete()
    }
    
    @Test("Should create team with creator user")
    func createTeamWithCreator() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        
        let user = try await app.createUser(email: email)
        let userId = user.id
        
        let team = try await app.createTeam(
            displayName: TestConfig.uniqueTeamName(),
            creatorUserId: userId
        )
        
        // Verify user is in team
        let teamUsers = try await team.listUsers()
        let found = teamUsers.contains { $0.id == userId }
        #expect(found)
        
        // Clean up
        try await team.delete()
        try await user.delete()
    }
    
    @Test("Should create team with all options")
    func createTeamWithAllOptions() async throws {
        let app = TestConfig.createServerApp()
        
        let team = try await app.createTeam(
            displayName: TestConfig.uniqueTeamName(),
            profileImageUrl: "https://example.com/image.png",
            clientMetadata: ["tier": "enterprise"],
            serverMetadata: ["billing_id": "bill_123"]
        )
        
        let profileImageUrl = await team.profileImageUrl
        let clientMeta = await team.clientMetadata
        let serverMeta = await team.serverMetadata
        
        #expect(profileImageUrl == "https://example.com/image.png")
        #expect(clientMeta["tier"] as? String == "enterprise")
        #expect(serverMeta["billing_id"] as? String == "bill_123")
        
        // Clean up
        try await team.delete()
    }
    
    // MARK: - Team Listing Tests
    
    @Test("Should list all teams")
    func listAllTeams() async throws {
        let app = TestConfig.createServerApp()
        
        let team = try await app.createTeam(displayName: TestConfig.uniqueTeamName())
        
        let teams = try await app.listTeams()
        
        let found = teams.contains { $0.id == team.id }
        #expect(found)
        
        // Clean up
        try await team.delete()
    }
    
    @Test("Should list teams for specific user")
    func listTeamsForUser() async throws {
        let app = TestConfig.createServerApp()
        let email = TestConfig.uniqueEmail()
        
        let user = try await app.createUser(email: email)
        let userId = user.id
        
        // Create team with user as member
        let team = try await app.createTeam(
            displayName: TestConfig.uniqueTeamName(),
            creatorUserId: userId
        )
        
        // List teams for this user
        let teams = try await app.listTeams(userId: userId)
        
        let found = teams.contains { $0.id == team.id }
        #expect(found)
        
        // Clean up
        try await team.delete()
        try await user.delete()
    }
    
    @Test("Should get team by ID")
    func getTeamById() async throws {
        let app = TestConfig.createServerApp()
        let teamName = TestConfig.uniqueTeamName()
        
        let createdTeam = try await app.createTeam(displayName: teamName)
        let teamId = createdTeam.id
        
        let fetchedTeam = try await app.getTeam(id: teamId)
        
        #expect(fetchedTeam != nil)
        
        let fetchedName = await fetchedTeam?.displayName
        #expect(fetchedName == teamName)
        
        // Clean up
        try await createdTeam.delete()
    }
    
    @Test("Should return nil for non-existent team")
    func getNonExistentTeam() async throws {
        let app = TestConfig.createServerApp()
        
        let fakeTeamId = UUID().uuidString
        let team = try await app.getTeam(id: fakeTeamId)
        
        #expect(team == nil)
    }
    
    // MARK: - Team Update Tests
    
    @Test("Should update team via server")
    func updateTeamViaServer() async throws {
        let app = TestConfig.createServerApp()
        
        let team = try await app.createTeam(displayName: "Original")
        
        try await team.update(
            displayName: "Updated",
            serverMetadata: ["status": "active"]
        )
        
        let displayName = await team.displayName
        let serverMeta = await team.serverMetadata
        
        #expect(displayName == "Updated")
        #expect(serverMeta["status"] as? String == "active")
        
        // Clean up
        try await team.delete()
    }
    
    // MARK: - Team Membership Tests
    
    @Test("Should add user to team")
    func addUserToTeam() async throws {
        let app = TestConfig.createServerApp()
        
        let user = try await app.createUser(email: TestConfig.uniqueEmail())
        let userId = user.id
        
        let team = try await app.createTeam(displayName: TestConfig.uniqueTeamName())
        
        try await team.addUser(id: userId)
        
        let teamUsers = try await team.listUsers()
        let found = teamUsers.contains { $0.id == userId }
        #expect(found)
        
        // Clean up
        try await team.delete()
        try await user.delete()
    }
    
    @Test("Should remove user from team")
    func removeUserFromTeam() async throws {
        let app = TestConfig.createServerApp()
        
        let user = try await app.createUser(email: TestConfig.uniqueEmail())
        let userId = user.id
        
        let team = try await app.createTeam(displayName: TestConfig.uniqueTeamName())
        
        // Add user
        try await team.addUser(id: userId)
        
        var teamUsers = try await team.listUsers()
        var found = teamUsers.contains { $0.id == userId }
        #expect(found)
        
        // Remove user
        try await team.removeUser(id: userId)
        
        teamUsers = try await team.listUsers()
        found = teamUsers.contains { $0.id == userId }
        #expect(!found)
        
        // Clean up
        try await team.delete()
        try await user.delete()
    }
    
    @Test("Should list team users")
    func listTeamUsers() async throws {
        let app = TestConfig.createServerApp()
        
        let user1 = try await app.createUser(email: TestConfig.uniqueEmail())
        let user2 = try await app.createUser(email: TestConfig.uniqueEmail())
        
        let team = try await app.createTeam(displayName: TestConfig.uniqueTeamName())
        
        try await team.addUser(id: user1.id)
        try await team.addUser(id: user2.id)
        
        let teamUsers = try await team.listUsers()
        
        #expect(teamUsers.count >= 2)
        #expect(teamUsers.contains { $0.id == user1.id })
        #expect(teamUsers.contains { $0.id == user2.id })
        
        // Clean up
        try await team.delete()
        try await user1.delete()
        try await user2.delete()
    }
    
    // MARK: - Team Deletion Tests
    
    @Test("Should delete team via server")
    func deleteTeamViaServer() async throws {
        let app = TestConfig.createServerApp()
        
        let team = try await app.createTeam(displayName: TestConfig.uniqueTeamName())
        let teamId = team.id
        
        try await team.delete()
        
        let deletedTeam = try await app.getTeam(id: teamId)
        #expect(deletedTeam == nil)
    }
}
