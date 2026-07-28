import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentHibernationProcessTerminationTests {
    @Test
    func validatesExactProcessGenerationAndCmuxScope() throws {
        let workspaceID = UUID()
        let panelID = UUID()
        let firstIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let secondIdentity = AgentPIDProcessIdentity(
            pid: 202,
            startSeconds: 20,
            startMicroseconds: 2
        )
        let identities = [101: firstIdentity, 202: secondIdentity]
        let scope = AgentHibernationController.ProcessTerminationScope(
            key: AgentHibernationPanelKey(workspaceId: workspaceID, panelId: panelID),
            processIDs: Set(identities.keys),
            processIdentities: identities
        )

        let terminations = try #require(
            AgentHibernationController.validatedScopedProcessTerminations(
                for: scope,
                processIdentityProvider: { identities[$0] },
                processArgumentsProvider: { _ in
                    Self.processArguments(workspaceID: workspaceID, panelID: panelID)
                },
                processGroupProvider: { pid_t($0 + 1_000) }
            )
        )

        #expect(
            terminations == [
                .init(
                    processID: 202,
                    processIdentity: secondIdentity,
                    processGroupID: 1_202
                ),
                .init(
                    processID: 101,
                    processIdentity: firstIdentity,
                    processGroupID: 1_101
                ),
            ]
        )
    }

    @Test
    func rejectsReusedProcessIdentity() {
        let workspaceID = UUID()
        let panelID = UUID()
        let capturedIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let scope = AgentHibernationController.ProcessTerminationScope(
            key: AgentHibernationPanelKey(workspaceId: workspaceID, panelId: panelID),
            processIDs: [101],
            processIdentities: [101: capturedIdentity]
        )

        let terminations = AgentHibernationController.validatedScopedProcessTerminations(
            for: scope,
            processIdentityProvider: { _ in
                AgentPIDProcessIdentity(
                    pid: 101,
                    startSeconds: 11,
                    startMicroseconds: 0
                )
            },
            processArgumentsProvider: { _ in
                Self.processArguments(workspaceID: workspaceID, panelID: panelID)
            },
            processGroupProvider: { _ in 1_101 }
        )

        #expect(terminations == nil)
    }

    @Test
    func rejectsProcessOutsidePaneScope() {
        let workspaceID = UUID()
        let panelID = UUID()
        let identity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let scope = AgentHibernationController.ProcessTerminationScope(
            key: AgentHibernationPanelKey(workspaceId: workspaceID, panelId: panelID),
            processIDs: [101],
            processIdentities: [101: identity]
        )

        let terminations = AgentHibernationController.validatedScopedProcessTerminations(
            for: scope,
            processIdentityProvider: { _ in identity },
            processArgumentsProvider: { _ in
                Self.processArguments(workspaceID: workspaceID, panelID: UUID())
            },
            processGroupProvider: { _ in 1_101 }
        )

        #expect(terminations == nil)
    }

    private static func processArguments(
        workspaceID: UUID,
        panelID: UUID
    ) -> CmuxTopProcessArguments {
        CmuxTopProcessArguments(
            arguments: ["/usr/bin/agent"],
            environment: [
                "CMUX_WORKSPACE_ID": workspaceID.uuidString,
                "CMUX_SURFACE_ID": panelID.uuidString,
            ]
        )
    }
}
