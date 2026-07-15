import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @Test func inheritedForkMetadataCannotPromoteAManagedChild() {
        let lineage = AgentHookSessionLineageResolver().resolve(
            agentName: "codex",
            sessionId: "child-session",
            pid: nil,
            environment: [
                "CMUX_AGENT_MANAGED_SUBAGENT": "1",
                "CMUX_AGENT_RELATIONSHIP": "forked",
                "CMUX_AGENT_PARENT_SESSION_ID": "root-session",
            ]
        )

        #expect(lineage.relationship == .spawned)
        #expect(lineage.restoreAuthority == false)
    }

    @Test func unresolvedProcessAncestryCannotGrantRestoreAuthority() {
        let authority = AgentHookSessionAuthorityPolicy().classify(
            managedChild: false,
            explicitRelationship: nil,
            processIdentityAvailable: true,
            hasAgentAncestor: false,
            ancestryProvenAbsent: false
        )

        #expect(authority.relationship == .spawned)
        #expect(authority.restoreAuthority == false)
    }

    @Test func explicitForkCanRecoverWhenItsExitedAncestorCannotBeRead() {
        let authority = AgentHookSessionAuthorityPolicy().classify(
            managedChild: false,
            explicitRelationship: .forked,
            processIdentityAvailable: true,
            hasAgentAncestor: false,
            ancestryProvenAbsent: false
        )

        #expect(authority.relationship == .forked)
        #expect(authority.restoreAuthority)
        #expect(authority.evidence == .verifiedForkRoot)
    }
}
