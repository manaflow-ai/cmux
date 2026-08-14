import CmuxAgentManifests
import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Vault agent manifest registry")
struct VaultAgentManifestRegistryTests {
    @Test("Bundled process manifests are behavior-identical to compiled detectors")
    func bundledProcessIdentityParity() throws {
        let snapshot = try CmuxAgentManifestLoader.bundled().load()
        let registrations: [String: CmuxVaultAgentRegistration] = [
            "pi": .builtInPi,
            "omp": .builtInOmp,
            "campfire": .builtInCampfire,
            "antigravity": .builtInAntigravity,
            "grok": .builtInGrok,
            "kimi": .builtInKimi,
            "hermes-agent": .builtInHermes,
        ]
        let fixtures: [VaultObservedAgentProcess] = [
            process(name: "pi", arguments: ["pi"]),
            process(name: "bash", arguments: ["bash", "pi"]),
            process(name: "OMP", arguments: ["OMP"]),
            process(name: "bun", arguments: ["bun", "/opt/@oh-my-pi/pi-coding-agent/index.js"]),
            process(name: "bun", arguments: ["bun", "other-package"]),
            process(name: "campfire", arguments: ["campfire"]),
            process(name: "node", arguments: ["node", "packages/session/bin/campfire.ts"]),
            process(name: "python3", arguments: ["python3", "packages/session/bin/campfire.ts"]),
            process(name: "agy", arguments: ["agy"]),
            process(name: "antigravity", arguments: ["antigravity"]),
            process(name: "grok-macos-aarch64", arguments: ["grok-macos-aarch64"]),
            process(name: "kimi-code", arguments: ["kimi-code"]),
            process(name: "hermes-agent", arguments: ["hermes-agent"]),
            process(name: "python3", arguments: ["python3", "-m", "hermes-agent"]),
            process(name: "python3", arguments: ["python3", "-X", "dev", "-m", "hermes-agent"]),
            process(name: "python3", arguments: ["python3", "-c", "print('hermes-agent')"]),
            process(name: "unrelated", arguments: ["unrelated"]),
        ]

        for (id, registration) in registrations {
            for fixture in fixtures {
                let compiled = registration.detect.matches(fixture)
                let declarative = snapshot.engine.matcher(
                    for: CmuxAgentProcessSnapshot(fixture),
                    manifestID: id
                ) != nil
                #expect(declarative == compiled, "\(id): \(fixture.arguments)")
            }
        }
    }

    @Test("Bundled manifests preserve specialized registration capabilities")
    func bundledRegistrationsRetainCompiledValues() throws {
        let snapshot = try CmuxAgentManifestLoader.bundled().load()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-manifest-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = CmuxVaultAgentRegistry.load(
            homeDirectory: root.path,
            environment: [:],
            fileManager: .default,
            manifestSnapshot: snapshot
        )
        let expected: [CmuxVaultAgentRegistration] = [
            .builtInPi,
            .builtInOmp,
            .builtInCampfire,
            .builtInAntigravity,
            .builtInGrok,
            .builtInKimi,
            .builtInHermes,
        ]

        for registration in expected {
            #expect(registry.registration(id: registration.id) == registration)
        }
    }

    @Test("Project-configured detectors outrank the manifest catalog")
    func projectConfigurationPrecedesManifests() {
        let manifest = makeManifest(id: "manifest-agent", matcherID: "manifest", processName: "shared")
        let manifestRegistration = CmuxVaultAgentRegistration(manifest: manifest, fallback: nil)
        let configuredRegistration = makeRegistration(id: "configured-agent", processName: "shared")
        let registry = CmuxVaultAgentRegistry(
            registrations: [configuredRegistration, manifestRegistration],
            manifestEntries: [.init(manifest: manifest, source: .user)],
            projectConfiguredIDs: [configuredRegistration.id]
        )

        let result = registry.matchingRegistrationDiagnostic(for: process(name: "shared"))

        #expect(result.registration?.id == "configured-agent")
        #expect(result.manifestEntry == nil)
        #expect(result.manifestResult == nil)
    }

    @Test("Manifest source precedence is independent of registration order")
    func manifestEngineOwnsCatalogPrecedence() {
        let user = makeManifest(id: "user-agent", matcherID: "user", processName: "shared")
        let bundled = makeManifest(id: "bundled-agent", matcherID: "bundled", processName: "shared")
        let registry = CmuxVaultAgentRegistry(
            registrations: [
                CmuxVaultAgentRegistration(manifest: user, fallback: nil),
                CmuxVaultAgentRegistration(manifest: bundled, fallback: nil),
            ],
            manifestEntries: [
                .init(manifest: user, source: .user, sourcePath: "/tmp/user-agent.json"),
                .init(manifest: bundled, source: .bundled),
            ]
        )

        let result = registry.matchingRegistrationDiagnostic(
            for: process(name: "shared"),
            screen: "task completed"
        )

        #expect(result.registration?.id == "user-agent")
        #expect(result.manifestEntry?.manifest.id == "user-agent")
        #expect(result.manifestResult?.agentID == "user-agent")
        #expect(result.manifestResult?.processMatcherID == "user")
        #expect(result.manifestResult?.classification == .done)
        #expect(result.manifestResult?.stateRuleID == "done")
    }

    @Test("Compiled registrations remain a last-resort compatibility layer")
    func compiledRegistrationIsFallback() {
        let manifest = makeManifest(id: "manifest-agent", matcherID: "manifest", processName: "other")
        let fallback = makeRegistration(id: "compatibility-agent", processName: "shared")
        let registry = CmuxVaultAgentRegistry(
            registrations: [
                fallback,
                CmuxVaultAgentRegistration(manifest: manifest, fallback: nil),
            ],
            manifestEntries: [.init(manifest: manifest, source: .bundled)]
        )

        let result = registry.matchingRegistrationDiagnostic(for: process(name: "shared"))

        #expect(result.registration?.id == "compatibility-agent")
        #expect(result.manifestResult == nil)
    }

    private func makeManifest(
        id: String,
        matcherID: String,
        processName: String
    ) -> CmuxAgentDetectionManifest {
        CmuxAgentDetectionManifest(
            id: id,
            process: .init(matchers: [
                .init(id: matcherID, processNames: [processName]),
            ]),
            states: [
                .init(id: "done", state: .done, screenContains: ["task completed"]),
            ]
        )
    }

    private func makeRegistration(
        id: String,
        processName: String
    ) -> CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: id,
            name: id,
            detect: CmuxVaultAgentDetectRule(processNames: [processName]),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}}"
        )
    }

    private func process(
        name: String,
        arguments: [String]? = nil
    ) -> VaultObservedAgentProcess {
        VaultObservedAgentProcess(
            processName: name,
            processPath: "/usr/local/bin/\(name)",
            arguments: arguments ?? [name],
            environment: [:]
        )
    }
}
