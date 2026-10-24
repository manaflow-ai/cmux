import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A switched pane's shell must name the target's account keys and nothing
/// else. An empty value is sent only to mask a key the workspace or the app
/// would otherwise hand the child; every other unused key is removed, so the
/// default account really runs without `CLAUDE_CONFIG_DIR` (#4255).
struct ClaudeAccountSwitchSurfaceEnvironmentTests {
    private let home = "/Users/cmux-test"
    private let configKey = "CLAUDE_CONFIG_DIR"
    private let secureStorageKey = "CLAUDE_SECURESTORAGE_CONFIG_DIR"

    @Test
    func customTargetSetsConfigDirectoryAndRemovesUnsuppliedSecureStorage() throws {
        let plan = try makePlan(from: nil, to: "work")

        let environment = ClaudeAccountSwitchSurfaceEnvironment(
            plan: plan,
            workspaceEnvironment: [:],
            processEnvironment: [:]
        )

        #expect(environment.overrides == [configKey: "\(home)/.claude-work"])
        #expect(environment.removedKeys == [secureStorageKey])
    }

    @Test
    func defaultTargetRemovesBothKeysWhenNothingElseSuppliesThem() throws {
        let plan = try makePlan(from: "\(home)/.claude-work", to: ClaudeAccountRegistry.defaultAccountName)

        let environment = ClaudeAccountSwitchSurfaceEnvironment(
            plan: plan,
            workspaceEnvironment: ["UNRELATED": "1"],
            processEnvironment: ["HOME": home]
        )

        #expect(environment.overrides.isEmpty)
        #expect(environment.removedKeys == [configKey, secureStorageKey])
    }

    @Test
    func defaultTargetMasksConfigDirectoryTheWorkspaceSupplies() throws {
        let plan = try makePlan(from: "\(home)/.claude-work", to: ClaudeAccountRegistry.defaultAccountName)

        let environment = ClaudeAccountSwitchSurfaceEnvironment(
            plan: plan,
            workspaceEnvironment: [configKey: "\(home)/.claude-work"],
            processEnvironment: [:]
        )

        #expect(environment.overrides == [configKey: ""])
        #expect(environment.removedKeys == [secureStorageKey])
    }

    @Test
    func masksSecureStorageTheAppProcessSupplies() throws {
        let plan = try makePlan(from: nil, to: "work")

        let environment = ClaudeAccountSwitchSurfaceEnvironment(
            plan: plan,
            workspaceEnvironment: [:],
            processEnvironment: [secureStorageKey: "\(home)/.claude-old"]
        )

        #expect(environment.overrides == [configKey: "\(home)/.claude-work", secureStorageKey: ""])
        #expect(environment.removedKeys.isEmpty)
    }

    @Test
    func inheritedEmptyValuesAreRemovedNotMasked() throws {
        let plan = try makePlan(from: "\(home)/.claude-work", to: ClaudeAccountRegistry.defaultAccountName)

        let environment = ClaudeAccountSwitchSurfaceEnvironment(
            plan: plan,
            workspaceEnvironment: [configKey: ""],
            processEnvironment: [secureStorageKey: ""]
        )

        #expect(environment.overrides.isEmpty)
        #expect(environment.removedKeys == [configKey, secureStorageKey])
    }

    private func makePlan(from sourceConfigDirectory: String?, to target: String) throws -> ClaudeAccountSwitchPlan {
        let registry = ClaudeAccountRegistry(
            declarations: [ClaudeAccountDeclaration(name: "work", configDir: "~/.claude-work")],
            homeDirectory: home
        )
        return try ClaudeAccountSwitchPlanner.plan(
            sessionID: "a22293b7-bcef-4707-8439-2f538c8517a4",
            workingDirectory: "\(home)/project",
            launchEnvironment: sourceConfigDirectory.map { [configKey: $0] },
            targetName: target,
            registry: registry,
            homeDirectory: home
        ).get()
    }
}
