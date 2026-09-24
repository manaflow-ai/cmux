import CMUXAuthCore
import CmuxAuthRuntime
import Foundation
import Testing
import os

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudRefreshFixture {
    let client: VMClient
    let auth: AuthCoordinator
    let session: URLSession
    let readRequests: CloudReadRequestCoordinator

    static func make(
        readRequests: CloudReadRequestCoordinator = CloudReadRequestCoordinator(),
        authClient: (any AuthClient)? = nil,
        isDisabledByManagedPolicy: (@Sendable () -> Bool)? = nil,
        isCloudEnabled: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Self {
        let defaults = try #require(UserDefaults(suiteName: "CloudRefreshFixture.\(UUID())"))
        let auth = AuthCoordinator(
            client: authClient ?? CloudRefreshAuthClient(),
            sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "session"),
            userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "team"),
            anchor: AuthPresentationContextProvider(),
            config: AuthConfig(
                stack: CMUXAuthConfig(projectId: "fixture", publishableClientKey: "fixture"),
                magicLinkCallbackURL: "http://127.0.0.1:1/callback", apiBaseURL: "http://127.0.0.1:1"
            ),
            launch: AuthLaunchOptions(
                clearAuthRequested: false, mockDataEnabled: false,
                environment: ["CMUX_UITEST_AUTH_FIXTURE": "1", "CMUX_UITEST_AUTH_USER_ID": "fixture"],
                includesDevAuth: true
            )
        )
        auth.start()
        await auth.awaitBootstrapped()
        try #require(auth.isAuthenticated)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudRefreshURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return Self(client: VMClient(
            session: session, auth: auth, resourceStats: VMResourceStatsStore(), checkpointRenames: CloudRenameCoordinator(),
            machineCache: CloudMachineCache(defaults: defaults), isDisabledByManagedPolicy: isDisabledByManagedPolicy,
            readRequests: readRequests, isCloudEnabled: isCloudEnabled
        ), auth: auth, session: session, readRequests: readRequests)
    }
}
