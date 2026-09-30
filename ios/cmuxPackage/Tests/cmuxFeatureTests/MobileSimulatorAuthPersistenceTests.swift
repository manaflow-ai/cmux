#if DEBUG && targetEnvironment(simulator)
import CMUXMobileCore
import Foundation
import StackAuth
import Testing
@testable import cmuxFeature

@MainActor
@Suite struct MobileSimulatorAuthPersistenceTests {
    @Test func renewedSessionSurvivesStoreRecreation() async throws {
        let namespace = try makeNamespace()
        defer { removeStorage(for: namespace) }
        let initial = try store(namespace: namespace, project: "project-a")
        await initial.setTokens(accessToken: "access-1", refreshToken: "refresh-1")
        await initial.compareAndSet(
            compareRefreshToken: "refresh-1",
            newRefreshToken: "refresh-2",
            newAccessToken: "access-2"
        )

        // Construct a new owner without the previous store's in-memory cache.
        let restored = try store(namespace: namespace, project: "project-a")
        #expect(await restored.getStoredAccessToken() == "access-2")
        #expect(await restored.getStoredRefreshToken() == "refresh-2")
    }

    @Test func signOutSurvivesStoreRecreation() async throws {
        let namespace = try makeNamespace()
        defer { removeStorage(for: namespace) }
        let initial = try store(namespace: namespace, project: "project-a")
        await initial.setTokens(accessToken: "access-1", refreshToken: "refresh-1")
        await initial.clearTokens()

        let restored = try store(namespace: namespace, project: "project-a")
        #expect(await restored.getStoredAccessToken() == nil)
        #expect(await restored.getStoredRefreshToken() == nil)
    }

    @Test func separateAppsAndProjectsCannotRestoreEachOthersSession() async throws {
        let firstNamespace = try makeNamespace()
        let secondNamespace = try makeNamespace()
        defer {
            removeStorage(for: firstNamespace)
            removeStorage(for: secondNamespace)
        }
        let initial = try store(namespace: firstNamespace, project: "project/a")
        await initial.setTokens(accessToken: "first-access", refreshToken: "first-refresh")

        let otherApp = try store(namespace: secondNamespace, project: "project/a")
        let otherProject = try store(namespace: firstNamespace, project: "project_a")
        #expect(await otherApp.getStoredRefreshToken() == nil)
        #expect(await otherProject.getStoredRefreshToken() == nil)
        let restored = try store(namespace: firstNamespace, project: "project/a")
        #expect(await restored.getStoredRefreshToken() == "first-refresh")
    }

    @Test func missingAppIdentityCannotPersistTokens() {
        let choice = MobileAuthComposition.tokenStore(
            appNamespace: nil,
            accessGroup: nil,
            legacyProjectID: "project-a"
        )
        // Memory storage keeps authenticated operations from trapping in the
        // SDK without attributing persisted credentials to an unknown bundle.
        guard case .memory = choice else {
            Issue.record("A missing app identity must not select a persistent token store")
            return
        }
    }

    private func store(
        namespace: MobileIOSAppNamespace,
        project: String
    ) throws -> any TokenStoreProtocol {
        let choice = MobileAuthComposition.tokenStore(
            appNamespace: namespace,
            accessGroup: nil,
            legacyProjectID: project
        )
        let persistentStore: (any TokenStoreProtocol)?
        if case let .custom(store) = choice {
            persistentStore = store
        } else {
            persistentStore = nil
        }
        return try #require(persistentStore, "Simulator login needs a persistent store for relaunch")
    }

    private func makeNamespace() throws -> MobileIOSAppNamespace {
        try #require(MobileIOSAppNamespace(
            bundleIdentifier: "dev.cmux.ios.auth-test-\(UUID().uuidString.lowercased())"
        ))
    }

    private func removeStorage(for namespace: MobileIOSAppNamespace) {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        try? FileManager.default.removeItem(at: support
            .appendingPathComponent("cmux-simulator-auth", isDirectory: true)
            .appendingPathComponent(namespace.bundleIdentifier, isDirectory: true))
    }
}
#endif
