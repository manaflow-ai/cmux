import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension Array where Element == CloudTreeNode {
    /// Removes the account-management section when a test is asserting the
    /// machine/device tree shape. The production tree intentionally appends
    /// CodeRouter after those sections.
    var withoutCoderouterSection: [CloudTreeNode] {
        filter { $0.id != "coderouter-section" && !$0.id.hasPrefix("coderouter-section/") }
    }
}

@MainActor
@Suite("CodeRouter setup workspace persistence")
struct CoderouterSetupWorkspacePersistenceTests {
    @Test("keeps a local selection before consulting setup workspace state")
    func localSelectionWins() {
        #expect(CoderouterSetupWorkspaceRoute.resolve(
            selectedWorkspaceIsLocal: true,
            persistedSetupWorkspaceIsValid: true
        ) == .selectedWorkspace)
    }

    @Test("reuses a valid setup workspace for a remote selection")
    func remoteSelectionReusesSetupWorkspace() {
        #expect(CoderouterSetupWorkspaceRoute.resolve(
            selectedWorkspaceIsLocal: false,
            persistedSetupWorkspaceIsValid: true
        ) == .persistedSetupWorkspace)
    }

    @Test("creates setup workspace when the selection and stored ID are unusable")
    func unusableStateCreatesSetupWorkspace() {
        #expect(CoderouterSetupWorkspaceRoute.resolve(
            selectedWorkspaceIsLocal: false,
            persistedSetupWorkspaceIsValid: false
        ) == .createSetupWorkspace)
    }

    @Test("stores and reads a workspace ID")
    func storesAndReadsWorkspaceID() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = CoderouterSetupWorkspacePersistence(defaults: defaults)
        let workspaceID = UUID()

        persistence.save(workspaceID: workspaceID)

        #expect(persistence.validatedWorkspaceID { $0 == workspaceID } == workspaceID)
    }

    @Test("clears a stale workspace ID")
    func clearsStaleWorkspaceID() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = CoderouterSetupWorkspacePersistence(defaults: defaults)
        let workspaceID = UUID()
        persistence.save(workspaceID: workspaceID)

        let resolved = persistence.validatedWorkspaceID { candidate in
            candidate != workspaceID
        }

        #expect(resolved == nil)
        #expect(persistence.validatedWorkspaceID { _ in true } == nil)
    }

    @Test("clears malformed persisted state")
    func clearsMalformedPersistedState() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = CoderouterSetupWorkspacePersistence(defaults: defaults)
        defaults.set("not-a-uuid", forKey: CoderouterSetupWorkspacePersistence.userDefaultsKey)

        #expect(persistence.validatedWorkspaceID { _ in true } == nil)
        #expect(persistence.validatedWorkspaceID { _ in true } == nil)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "cmux.coderouter-tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}
