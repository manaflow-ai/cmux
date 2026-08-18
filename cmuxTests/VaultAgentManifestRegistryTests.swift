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
            process(name: "npm", arguments: ["npm", "install", "@oh-my-pi/pi-coding-agent"]),
            process(name: "bun", arguments: ["bun", "other-package"]),
            process(name: "campfire", arguments: ["campfire"]),
            process(name: "node", arguments: ["node", "packages/session/bin/campfire.ts"]),
            process(name: "python3", arguments: ["python3", "packages/session/bin/campfire.ts"]),
            process(name: "agy", arguments: ["agy"]),
            process(name: "antigravity", arguments: ["antigravity"]),
            process(name: "agent", arguments: ["agent"]),
            process(name: "grok-macos-aarch64", arguments: ["grok-macos-aarch64"]),
            process(name: "kimi-code", arguments: ["kimi-code"]),
            process(name: "Kimi Code", arguments: ["Kimi Code", ""]),
            process(name: "hermes-agent", arguments: ["hermes-agent"]),
            process(name: "python3", arguments: ["python3", "-m", "hermes-agent"]),
            process(name: "python3", arguments: ["python3", "-X", "dev", "-m", "hermes-agent"]),
            VaultObservedAgentProcess(
                processName: "python3.11",
                processPath: "/Users/example/.local/share/uv/python/bin/python3.11",
                arguments: [
                    "/Users/example/.hermes/hermes-agent/venv/bin/python",
                    "/Users/example/.hermes/hermes-agent/run_agent.py",
                ],
                environment: [:]
            ),
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

    @Test("Installed Hermes Python launchers are detected without restoring one-shot queries")
    func installedHermesPythonLaunchers() throws {
        let snapshot = try CmuxAgentManifestLoader.bundled().load()
        let registry = CmuxVaultAgentRegistry.load(manifestSnapshot: snapshot)
        let interpreter = "/Users/example/.hermes/hermes-agent/venv/bin/python"
        let processPath = "/Users/example/.local/share/uv/python/bin/python3.11"
        let interactiveEntrypoints = ["hermes", "run_agent.py"]

        for entrypoint in interactiveEntrypoints {
            let observed = VaultObservedAgentProcess(
                processName: "python3.11",
                processPath: processPath,
                arguments: [
                    interpreter,
                    "/Users/example/.hermes/hermes-agent/\(entrypoint)",
                ],
                environment: [:]
            )
            let diagnostic = registry.matchingRegistrationDiagnostic(for: observed)

            #expect(diagnostic.registration?.id == "hermes-agent")
            #expect(diagnostic.manifestResult?.processMatcherID == "versioned-python-entrypoint")
            #expect(diagnostic.manifestResult?.source == .bundled)
            #expect(observed.isInteractiveHermesAgentInvocation)
            #expect(diagnostic.registration?.processDetectedSnapshotIsRestorable(for: observed) == true)
        }

        let query = VaultObservedAgentProcess(
            processName: "python3.11",
            processPath: processPath,
            arguments: [
                interpreter,
                "/Users/example/.hermes/hermes-agent/run_agent.py",
                "--query",
                "one shot",
            ],
            environment: [:]
        )

        #expect(registry.matchingRegistration(for: query)?.id == "hermes-agent")
        #expect(!query.isInteractiveHermesAgentInvocation)
        #expect(registry.registration(id: "hermes-agent")?.processDetectedSnapshotIsRestorable(for: query) == false)
    }

    @Test("Cached process validation preserves manifest path predicates")
    func cachedValidationUsesManifestIdentity() {
        let manifest = CmuxAgentDetectionManifest(
            id: "hermes-agent",
            process: .init(matchers: [
                .init(
                    id: "scoped-python",
                    processNames: ["python"],
                    processPathContains: ["/trusted/"]
                ),
            ])
        )
        let registration = CmuxVaultAgentRegistration(
            manifest: manifest,
            fallback: .builtInHermes
        )
        let registry = CmuxVaultAgentRegistry(
            registrations: [registration],
            manifestEntries: [.init(manifest: manifest, source: .user)]
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .hermesAgent,
            sessionId: "session",
            workingDirectory: nil,
            launchCommand: nil,
            registration: registration
        )
        let validator = CachedAgentProcessIdentityValidator(registry: registry)
        let arguments = ["/opt/hermes/run_agent.py"]

        #expect(validator.currentProcess(
            .init(arguments: ["/trusted/python"] + arguments, environment: [:]),
            matches: snapshot,
            hermesSessionValidation: .currentHookRecord
        ))
        #expect(!validator.currentProcess(
            .init(arguments: ["/untrusted/python"] + arguments, environment: [:]),
            matches: snapshot,
            hermesSessionValidation: .currentHookRecord
        ))
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

    @Test("A project override keeps unrelated manifest agents indexed")
    func projectOverridePreservesOtherManifestDetectors() throws {
        let overridden = makeManifest(id: "overridden-agent", matcherID: "overridden", processName: "shared")
        let survivor = makeManifest(id: "survivor-agent", matcherID: "survivor", processName: "survivor")
        let base = CmuxVaultAgentRegistry(
            registrations: [
                CmuxVaultAgentRegistration(manifest: overridden, fallback: nil),
                CmuxVaultAgentRegistration(manifest: survivor, fallback: nil),
            ],
            manifestEntries: [
                .init(manifest: overridden, source: .bundled),
                .init(manifest: survivor, source: .bundled),
            ]
        )
        let projectRegistration = makeRegistration(id: "project-agent", processName: "shared")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-project-override-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = CmuxConfigFile(vault: CmuxVaultConfigDefinition(agents: [projectRegistration]))
        try JSONEncoder().encode(config).write(to: root.appendingPathComponent("cmux.json"))

        let merged = base.mergingProjectConfig(workingDirectory: root.path)
        let projectResult = merged.matchingRegistration(for: process(name: "shared"))
        let survivorResult = merged.matchingRegistrationDiagnostic(for: process(name: "survivor"))

        #expect(projectResult?.id == "project-agent")
        #expect(survivorResult.registration?.id == "survivor-agent")
        #expect(survivorResult.manifestResult?.agentID == "survivor-agent")
        #expect(survivorResult.manifestResult?.processMatcherID == "survivor")
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
        let scanResult = registry.matchingRegistration(for: process(name: "shared"))

        #expect(result.registration?.id == "user-agent")
        #expect(scanResult?.id == result.registration?.id)
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
