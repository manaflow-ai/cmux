import CmuxCloud
import CmuxAuthRuntime
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension VMClientReadCoalescingTests {
    @Test("Reads without a transition identity fail before HTTP and recover for the next account", arguments: ["list", "stats", "usage"])
    func nilIdentityAdmission(operation: String) async throws {
        let authClient = CloudReadIdentityAuthClient()
        let fixture = try await CloudRefreshFixture.make(authClient: authClient)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await authClient.holdValidationProbe()
        let validation = Task { await fixture.auth.revalidateSession() }
        await authClient.waitUntilValidationProbe()
        #expect(fixture.auth.isAuthenticated)
        #expect(fixture.auth.authenticatedSessionIdentity == nil)
        do {
            try await identityRead(operation, fixture: fixture)
            Issue.record("A read with no authenticated identity reached the server")
        } catch VMClientError.sessionRefreshFailed {
        } catch MachineUsageClientError.sessionRefreshFailed {
        } catch { Issue.record("Unexpected transition error: \(error)") }
        #expect(await fixture.readRequests.entries.isEmpty)
        #expect(await CloudRefreshURLProtocol.requestCounts().isEmpty)
        await authClient.releaseValidationProbe()
        await validation.value
        try await fixture.auth.signInWithPassword(email: "replacement@example.test", password: "fixture")
        #expect(fixture.auth.authenticatedSessionIdentity?.accountID == "replacement")
        try await identityRead(operation, fixture: fixture)
        #expect(await CloudRefreshURLProtocol.requestCounts().values.reduce(0, +) == 1)
    }

    @Test("An account change rejects a response bound to the prior session", arguments: ["list", "stats", "usage"])
    func accountChangeRejectsRead(operation: String) async throws {
        let fixture = try await CloudRefreshFixture.make(authClient: CloudReadIdentityAuthClient())
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.holdResponses()
        let original = try #require(fixture.auth.authenticatedSessionIdentity)
        let reader = Task { try await identityRead(operation, fixture: fixture) }
        await CloudRefreshURLProtocol.waitUntilStarted()
        try await fixture.auth.signInWithPassword(email: "replacement@example.test", password: "fixture")
        #expect(fixture.auth.authenticatedSessionIdentity != original)
        await CloudRefreshURLProtocol.releaseResponses()
        do { try await reader.value; Issue.record("The previous account's response was published") }
        catch is CancellationError {} catch VMClientError.notSignedIn {} catch { Issue.record("\(error)") }
        try await identityRead(operation, fixture: fixture)
        #expect(await CloudRefreshURLProtocol.requestCounts().values.reduce(0, +) == 2)
    }

    @Test("A known identity read survives same-account revalidation", arguments: ["list", "stats", "usage"])
    func knownIdentityDuringRevalidation(operation: String) async throws {
        let authClient = CloudReadIdentityAuthClient()
        let fixture = try await CloudRefreshFixture.make(authClient: authClient)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.holdResponses()
        let original = try #require(fixture.auth.authenticatedSessionIdentity)
        let reader = Task { try await identityRead(operation, fixture: fixture) }
        await CloudRefreshURLProtocol.waitUntilStarted()
        await authClient.holdValidationProbe()
        let validation = Task { await fixture.auth.revalidateSession() }
        await authClient.waitUntilValidationProbe()
        #expect(fixture.auth.authenticatedSessionIdentity == nil)
        #expect(fixture.auth.isAuthenticatedSessionIdentityCurrent(original))
        await CloudRefreshURLProtocol.releaseResponses()
        let result = await reader.result
        await authClient.releaseValidationProbe()
        await validation.value
        try result.get()
        #expect(await CloudRefreshURLProtocol.requestCounts().values.reduce(0, +) == 1)
    }

    @Test("Signed-out shared reads fail before the network", arguments: ["list", "stats", "usage"])
    func signedOutReadAdmission(operation: String) async throws {
        let fixture = try await CloudRefreshFixture.make(authClient: CloudReadIdentityAuthClient())
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await fixture.auth.signOut()
        do { try await identityRead(operation, fixture: fixture); Issue.record("Signed-out read succeeded") }
        catch VMClientError.notSignedIn {} catch MachineUsageClientError.notSignedIn {} catch { Issue.record("\(error)") }
        #expect(await CloudRefreshURLProtocol.requestCounts().isEmpty)
        #expect(await fixture.readRequests.entries.isEmpty)
    }

    @Test("Explicit team usage does not require the selected team")
    @MainActor
    func explicitTeamUsageAllowsCrossTeamQuery() async throws {
        let fixture = try await CloudRefreshFixture.make(authClient: CloudReadIdentityAuthClient())
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        let usage = MachineUsageClient(session: fixture.session, auth: fixture.auth, readRequests: fixture.readRequests)

        let result = try await usage.teamUsage(teamID: "explicit-team")

        #expect(result.kind == .ready)
        #expect(await CloudRefreshURLProtocol.requestCounts().values.reduce(0, +) == 1)
    }

    private func identityRead(_ operation: String, fixture: CloudRefreshFixture) async throws {
        switch operation {
        case "list": _ = try await fixture.client.listPage()
        case "stats": _ = try await fixture.client.stats(id: "fixture-0")
        default:
            let usage = MachineUsageClient(session: fixture.session, auth: fixture.auth, readRequests: fixture.readRequests)
            _ = try await usage.teamUsage()
        }
    }
}
