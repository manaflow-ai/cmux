import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the local placeholder used while a Cloud workspace's
/// remote identity is still being discovered.
@MainActor
@Suite(.serialized)
struct CloudInitialWorkspaceNamingTests {
    @Test("A creation-time rename survives delayed binding and the old remote snapshot")
    func creationRenameIsPreservedAcrossBinding() async throws {
        let fixture = try CloudNameAuthorityFixture()
        do {
            fixture.workspace.cloudVMBinding = nil
            #expect(fixture.workspace.setCustomTitle("Chosen during creation", source: .user))

            fixture.catalog.bindCloudWorkspace(
                localWorkspaceID: fixture.workspace.id,
                machine: fixture.provider.machine,
                remoteWorkspaceID: "a",
                generatedTitle: "Cloud VM"
            )
            #expect(fixture.workspace.title == "Chosen during creation")
            #expect(fixture.workspace.effectiveCustomTitleSource == .user)

            // The remote graph still has its older default name. Binding must
            // submit the local intent before that snapshot can overwrite it.
            try await fixture.settle()
            #expect(fixture.provider.writes == [("a", "Chosen during creation")])
            #expect(fixture.workspace.title == "Chosen during creation")
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }
}
