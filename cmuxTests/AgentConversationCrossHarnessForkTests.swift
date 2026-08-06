import CmuxConversationTransfer
import CMUXAgentLaunch
import Dispatch
import Foundation
import os
import SQLite3
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AgentConversationCrossHarnessForkTests {
    @Test
    func everyAdvertisedHarnessBuildsAnInteractiveTransferCommand() throws {
        let message = "User: don't drop this\nAI: preserved"
        let commands = Dictionary(uniqueKeysWithValues: try AgentConversationForkTargetHarness.allCases
            .filter { $0 != .current }
            .map { harness in
                (harness, try #require(harness.startupCommand(handoffMessage: message)))
            })
        let interactiveCommands = Dictionary(uniqueKeysWithValues: try commands.map { harness, command in
            (harness, try transferredInteractiveCommand(from: command))
        })

        #expect(interactiveCommands[.claude] == "exec \(AgentResumeArgv.claudeWrapperShellExecutableToken)")
        #expect(interactiveCommands[.codex] == "exec \(AgentResumeArgv.codexWrapperShellExecutableToken)")
        #expect(interactiveCommands[.grok] == "exec grok")
        #expect(interactiveCommands[.opencode] == "exec opencode")
        #expect(interactiveCommands[.omp] == "exec omp")
        #expect(interactiveCommands[.campfire] == "exec campfire")
        #expect(interactiveCommands[.pi] == "exec pi")
        #expect(interactiveCommands[.amp] == "exec amp")
        #expect(interactiveCommands[.cursor] == "exec cursor-agent")
        #expect(interactiveCommands[.gemini] == "exec gemini")
        #expect(interactiveCommands[.kiro]?.contains("exec kiro-cli chat --agent cmux") == true)
        #expect(interactiveCommands[.kiro]?.contains("else exec kiro-cli chat") == true)
        #expect(interactiveCommands[.antigravity] == "exec agy")
        #expect(interactiveCommands[.hermesAgent] == "exec hermes chat --tui")
        #expect(interactiveCommands[.copilot] == "exec copilot --interactive")
        #expect(interactiveCommands[.codebuddy] == "exec codebuddy")
        #expect(interactiveCommands[.factory] == "exec droid")
        #expect(interactiveCommands[.kimi] == "exec kimi")
        #expect(try commands.values.allSatisfy { try transferredFirstMessage(from: $0) == message })
        #expect(commands.values.allSatisfy { $0.contains("/usr/bin/expect -f /dev/fd/3 3<<") })
        #expect(commands.values.allSatisfy { !$0.contains("don't drop this") })
    }

    @Test
    func transferredTranscriptReachesHarnessInputWithoutAppearingInHarnessArguments() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake grok", isDirectory: false)
        let argumentsLog = directory.appendingPathComponent("arguments.log", isDirectory: false)
        let inputLog = directory.appendingPathComponent("input.log", isDirectory: false)
        let script = """
        #!/bin/zsh
        /usr/bin/printf '%s\n' "$@" > "$CMUX_ARGUMENTS_LOG"
        /usr/bin/printf 'Grok Build\n'
        IFS= read -r first_message
        /usr/bin/printf '%s' "$first_message" > "$CMUX_INPUT_LOG"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let message = "User: preserve this private transfer"
        let command = try #require(AgentConversationForkTargetHarness.grok.startupCommand(
            handoffMessage: message,
            executablePath: executable.path
        ))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_ARGUMENTS_LOG": argumentsLog.path,
            "CMUX_INPUT_LOG": inputLog.path,
        ]) { _, override in override }
        process.standardError = FileHandle.nullDevice

        let confirmationProcess = try runWithTransferConfirmation(process)
        process.waitUntilExit()
        confirmationProcess.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(String(decoding: try Data(contentsOf: argumentsLog), as: UTF8.self) == "\n")
        #expect(String(decoding: try Data(contentsOf: inputLog), as: UTF8.self).contains(message))
    }

    @Test
    func transferredTranscriptWaitsForHarnessPrompt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake grok", isDirectory: false)
        let earlyInputLog = directory.appendingPathComponent("early-input.log", isDirectory: false)
        let inputLog = directory.appendingPathComponent("input.log", isDirectory: false)
        let script = """
        #!/bin/zsh
        /usr/bin/printf 'Authentication required\\n'
        /bin/sleep 0.35
        if IFS= read -t 0.05 -r early_message; then
          /usr/bin/printf '%s' "$early_message" > "$CMUX_EARLY_INPUT_LOG"
          exit 41
        fi
        /usr/bin/printf 'Grok Build\n'
        IFS= read -r first_message
        /usr/bin/printf '%s' "$first_message" > "$CMUX_INPUT_LOG"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let message = "User: wait for the real editor"
        let command = try #require(AgentConversationForkTargetHarness.grok.startupCommand(
            handoffMessage: message,
            executablePath: executable.path
        ))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_EARLY_INPUT_LOG": earlyInputLog.path,
            "CMUX_INPUT_LOG": inputLog.path,
        ]) { _, override in override }
        process.standardError = FileHandle.nullDevice

        let confirmationProcess = try runWithTransferConfirmation(process)
        process.waitUntilExit()
        confirmationProcess.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: earlyInputLog.path))
        #expect(String(decoding: try Data(contentsOf: inputLog), as: UTF8.self).contains(message))
    }

    @Test
    func readinessBannerAloneDoesNotAuthorizeTranscriptSubmission() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake grok", isDirectory: false)
        let inputLog = directory.appendingPathComponent("input.log", isDirectory: false)
        let script = """
        #!/bin/zsh
        /usr/bin/printf 'Grok Build\n'
        if IFS= read -t 2 -r first_message; then
          /usr/bin/printf '%s' "$first_message" > "$CMUX_INPUT_LOG"
        fi
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let command = try #require(AgentConversationForkTargetHarness.grok.startupCommand(
            handoffMessage: "User: require explicit confirmation",
            executablePath: executable.path
        ))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_INPUT_LOG": inputLog.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        #expect(!FileManager.default.fileExists(atPath: inputLog.path))
    }

    @Test
    func readinessFallbackOffersExplicitConfirmation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake grok", isDirectory: false)
        let inputLog = directory.appendingPathComponent("input.log", isDirectory: false)
        let script = """
        #!/bin/zsh
        /usr/bin/printf 'Custom harness prompt\\n'
        if IFS= read -t 5 -r first_message; then
          /usr/bin/printf '%s' "$first_message" > "$CMUX_INPUT_LOG"
        fi
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let message = "User: confirm after the readiness fallback"
        let command = try #require(AgentConversationForkTargetHarness.grok.startupCommand(
            handoffMessage: message,
            executablePath: executable.path
        ))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_INPUT_LOG": inputLog.path,
        ]) { _, override in override }
        process.standardError = FileHandle.nullDevice

        let confirmationProcess = try runWithTransferConfirmation(process)
        process.waitUntilExit()
        confirmationProcess.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(String(decoding: try Data(contentsOf: inputLog), as: UTF8.self).contains(message))
    }

    @Test
    func transferredTranscriptFailsClosedWhenHarnessExitsBeforePrompt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake grok", isDirectory: false)
        let script = """
        #!/bin/zsh
        /usr/bin/printf 'Authentication required\\n'
        /bin/sleep 0.25
        exit 0
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let command = try #require(AgentConversationForkTargetHarness.grok.startupCommand(
            handoffMessage: "User: never send this",
            executablePath: executable.path
        ))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
    }

    @Test
    func discoveredTargetReplacementDuringExportFailsClosed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("grok", isDirectory: false)
        try "#!/bin/zsh\n/usr/bin/printf 'grok 1.2.3\\n'\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let identity = try #require(AgentConversationForkExecutableIdentity.capture(
            executablePath: executable.path,
            runtimeSearchPath: directory.path
        ))
        let target = AgentConversationForkTarget(
            harness: .grok,
            executablePath: executable.path,
            runtimeSearchPath: directory.path,
            executableIdentity: identity
        )
        let service = AgentConversationExportService(
            readerRegistry: AgentConversationReaderRegistry(adapters: [
                ExecutableReplacingSourceAdapter(executableURL: executable),
            ])
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "replace-target-during-export",
            transcriptPath: "/unused/replace-target-during-export.jsonl"
        )

        await #expect {
            try await AgentConversationForkRequest(
                target: target,
                destination: .right
            ).startupCommandOverride(
                sourceSnapshot: snapshot,
                exportService: service
            )
        } throws: { error in
            error as? AgentConversationForkRequestError == .targetExecutableChanged
        }
    }

    @Test
    func boundExecutableRejectsReplacementAfterCommandCreation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("grok", isDirectory: false)
        try "#!/bin/zsh\nexit 0\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let identity = try #require(AgentConversationForkExecutableIdentity.capture(
            executablePath: executable.path,
            runtimeSearchPath: directory.path
        ))
        let target = AgentConversationForkTarget(
            harness: .grok,
            executablePath: executable.path,
            runtimeSearchPath: directory.path,
            executableIdentity: identity
        )
        let command = try #require(target.startupCommand(
            handoffMessage: "User: never disclose this to a replacement"
        ))
        let inputLog = directory.appendingPathComponent("replacement-input.log")
        try FileManager.default.removeItem(at: executable)
        try """
        #!/bin/zsh
        /usr/bin/printf 'Grok Build\\n'
        if IFS= read -t 3 -r first_message; then
          /usr/bin/printf '%s' "$first_message" > "$CMUX_REPLACEMENT_INPUT_LOG"
        fi
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_REPLACEMENT_INPUT_LOG": inputLog.path,
        ]) { _, override in override }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let confirmationProcess = try runWithDelayedTransferConfirmation(process)
        process.waitUntilExit()
        confirmationProcess.waitUntilExit()

        #expect(process.terminationStatus != 0)
        #expect(!FileManager.default.fileExists(atPath: inputLog.path))
    }

    @Test
    func executableBindingPrunesOwnedExpiredCrashRemnants() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("grok", isDirectory: false)
        try "#!/bin/zsh\nexit 0\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let identity = try #require(AgentConversationForkExecutableIdentity.capture(
            executablePath: executable.path,
            runtimeSearchPath: directory.path
        ))
        let binding = try #require(AgentConversationForkExecutableBinding(identity: identity))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc",
            binding.shellCommand(running: "/bin/kill -KILL $$"),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(FileManager.default.fileExists(atPath: binding.boundPath))

        let token = try #require(
            URL(fileURLWithPath: binding.boundPath)
                .lastPathComponent
                .split(separator: "-")
                .dropFirst(2)
                .first
        )
        let recordDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-transfer-bindings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let record = recordDirectory
            .appendingPathComponent("\(token).json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: record)
            try? FileManager.default.removeItem(atPath: binding.boundPath)
        }
        let manifest: [String: Any] = [
            "version": 1,
            "boundPath": binding.boundPath,
            "expectedStatSignature": identity.shellStatSignature,
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: record)
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o600,
                .modificationDate: Date(timeIntervalSinceNow: -(25 * 60 * 60)),
            ],
            ofItemAtPath: record.path
        )

        _ = try #require(AgentConversationForkExecutableBinding(identity: identity))

        #expect(!FileManager.default.fileExists(atPath: binding.boundPath))
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }

    @Test
    func hermesTransferStartsInteractiveSessionAndSubmitsFirstMessage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake hermes", isDirectory: false)
        let invocationLog = directory.appendingPathComponent("invocations.log", isDirectory: false)
        let inputLog = directory.appendingPathComponent("input.log", isDirectory: false)
        let script = """
        #!/bin/zsh
        if [[ "${1:-}" != "chat" || "${2:-}" != "--tui" || -n "${3:-}" ]]; then
          exit 2
        fi
        /usr/bin/printf '%s\n' "$@" > "$CMUX_HERMES_TEST_LOG"
        /usr/bin/printf 'Available Tools\n'
        IFS= read -r first_message
        /usr/bin/printf '%s' "$first_message" > "$CMUX_HERMES_INPUT_LOG"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let message = "User: preserve this private Hermes transfer"
        let command = try #require(AgentConversationForkTargetHarness.hermesAgent.startupCommand(
            handoffMessage: message,
            executablePath: executable.path
        ))
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_HERMES_TEST_LOG": invocationLog.path,
            "CMUX_HERMES_INPUT_LOG": inputLog.path,
        ]) { _, override in override }
        process.standardError = standardError

        let confirmationProcess = try runWithTransferConfirmation(process)
        process.waitUntilExit()
        confirmationProcess.waitUntilExit()
        let errorOutput = String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        #expect(process.terminationStatus == 0, Comment(rawValue: errorOutput))
        #expect(
            String(decoding: try Data(contentsOf: invocationLog), as: UTF8.self)
                == "chat\n--tui\n"
        )
        #expect(String(decoding: try Data(contentsOf: inputLog), as: UTF8.self).contains(message))
    }

    @Test
    func registeredHarnessIDUsesNativeForkForMatchingSource() {
        #expect(AgentConversationForkTargetHarness.omp.usesNativeFork(for: .custom("omp")))
        #expect(!AgentConversationForkTargetHarness.pi.usesNativeFork(for: .custom("omp")))
    }

    @Test
    func explicitSameHarnessRetainsNativeForkWithoutReadingTranscript() async throws {
        let snapshot = SessionRestorableAgentSnapshot(kind: .codex, sessionId: "codex-session")
        let service = AgentConversationExportService(
            readerRegistry: AgentConversationReaderRegistry(adapters: [FailingSourceAdapter()])
        )

        let override = try await AgentConversationForkRequest(
            targetHarness: .codex,
            destination: .right
        ).startupCommandOverride(sourceSnapshot: snapshot, exportService: service)

        #expect(override == nil)
        #expect(snapshot.forkStartupInput() != nil)
    }

    @Test
    func authoritativeTranscriptFailureDoesNotReadFallback() async {
        let fallback = ReadRecordingSourceAdapter()
        let registry = AgentConversationReaderRegistry(adapters: [
            FailingSourceAdapter(),
            fallback,
        ])
        let source = AgentConversationSource(snapshot: SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "authoritative-session",
            transcriptPath: "/captured/authoritative-rollout.jsonl"
        ))

        await #expect(throws: OpenCodeFixtureError.self) {
            try await registry.read(source)
        }
        #expect(await fallback.readCount == 0)
    }

    @Test(arguments: [RestorableAgentKind.opencode, .hermesAgent])
    func providerTransferWithoutCapturedStorageIdentityFailsClosed(
        kind: RestorableAgentKind
    ) async {
        let fallback = ReadRecordingSourceAdapter()
        let providerAdapter: any AgentConversationSourceAdapter = switch kind {
        case .opencode:
            OpenCodeAgentConversationSourceAdapter()
        case .hermesAgent:
            HermesAgentConversationSourceAdapter()
        default:
            FailingSourceAdapter()
        }
        let registry = AgentConversationReaderRegistry(adapters: [
            providerAdapter,
            fallback,
        ])
        let source = AgentConversationSource(snapshot: SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: "uncaptured-storage-session"
        ))

        #expect(!source.hasDeterministicTranscriptSource)
        #expect(!IndexedAgentConversationSourceAdapter().supports(source))
        await #expect {
            try await registry.read(source)
        } throws: { error in
            error as? AgentConversationExportError == .sourceUnavailable(kind.rawValue)
        }
        #expect(await fallback.readCount == 0)
    }

    @Test
    func cancelledTransferStopsProviderDatabaseRead() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let database = fixture.appendingPathComponent("opencode.db")
        try createOpenCodeDatabase(at: database)

        let loadTask = Task {
            try await SessionTranscriptLoader.load(source: .init(
                agent: .opencode,
                sessionId: "open-session",
                fileURL: nil,
                openCodeDatabasePath: database.path,
                retention: .transferOpeningUserAndLatest(
                    turnLimit: 1_000,
                    textByteLimit: 32 * 1_024
                )
            ))
        }
        loadTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await loadTask.value
        }
    }

    @Test
    func openCodeSnapshotRejectsAggregateAboveLimit() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let database = fixture.appendingPathComponent("opencode.db")
        try Data(repeating: 0x41, count: 32).write(to: database)

        #expect(throws: CocoaError.self) {
            _ = try OpenCodeDatabaseSnapshot.make(
                prefix: "cmux-opencode-bounded-test",
                sourcePath: database.path,
                maximumTotalBytes: 8
            )
        }
    }

    @Test
    func openCodeSnapshotUsesOwnerOnlyPermissions() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let database = fixture.appendingPathComponent("opencode.db")
        try createOpenCodeDatabase(at: database)

        let snapshot = try #require(try OpenCodeDatabaseSnapshot.make(
            prefix: "cmux-opencode-private-test",
            sourcePath: database.path
        ))
        defer { snapshot.remove() }

        #expect(
            try permissions(at: snapshot.databaseURL.deletingLastPathComponent()) == 0o700
        )
        #expect(try permissions(at: snapshot.databaseURL) == 0o600)
    }

    @Test
    func forkCacheIdentityChangesWhenTranscriptPathChanges() {
        let first = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-session",
            transcriptPath: "/tmp/first-rollout.jsonl"
        )
        let second = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-session",
            transcriptPath: "/tmp/second-rollout.jsonl"
        )

        #expect(
            ContentView.commandPaletteForkSnapshotFingerprint(first)
                != ContentView.commandPaletteForkSnapshotFingerprint(second)
        )
    }

    @Test
    func codexTranscriptSeedsClaudeCode() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("rollout.jsonl")
        try [
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Find the parser bug"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The parser drops the final field"}]}}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-session",
            transcriptPath: transcript.path
        )

        let command = try #require(try await AgentConversationForkRequest(
            targetHarness: .claude,
            destination: .newTab
        ).startupCommandOverride(sourceSnapshot: snapshot))
        let message = try transferredFirstMessage(from: command)

        #expect(try transferredInteractiveCommand(from: command) == "exec \(AgentResumeArgv.claudeWrapperShellExecutableToken)")
        #expect(message.contains("Find the parser bug"))
        #expect(message.contains("The parser drops the final field"))
    }

    @Test
    func claudeTranscriptSeedsCodex() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("claude.jsonl")
        try [
            #"{"type":"user","message":{"role":"user","content":"Repair the renderer"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":"The wakeup path is stale"}}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session",
            transcriptPath: transcript.path
        )

        let command = try #require(try await AgentConversationForkRequest(
            targetHarness: .codex,
            destination: .newWorkspace
        ).startupCommandOverride(sourceSnapshot: snapshot))
        let message = try transferredFirstMessage(from: command)

        #expect(try transferredInteractiveCommand(from: command) == "exec \(AgentResumeArgv.codexWrapperShellExecutableToken)")
        #expect(message.contains("Repair the renderer"))
        #expect(message.contains("The wakeup path is stale"))
    }

    @Test
    func claudeToolBlocksDoNotReachCodex() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("claude-tools.jsonl")
        try [
            #"{"type":"user","message":{"role":"user","content":"Inspect the renderer"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will inspect the wakeup path."},{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"/private/credentials.txt"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"TOP-SECRET-TOOL-OUTPUT"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":"The wakeup path is stale."}}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-tool-session",
            transcriptPath: transcript.path
        )

        let command = try #require(try await AgentConversationForkRequest(
            targetHarness: .codex,
            destination: .newWorkspace
        ).startupCommandOverride(sourceSnapshot: snapshot))
        let message = try transferredFirstMessage(from: command)

        #expect(message.contains("I will inspect the wakeup path."))
        #expect(message.contains("The wakeup path is stale."))
        #expect(!message.contains("/private/credentials.txt"))
        #expect(!message.contains("TOP-SECRET-TOOL-OUTPUT"))
    }

    @Test
    func genericNestedToolBlocksDoNotReachTransferDialogue() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("generic-tools.jsonl")
        try [
            #"{"role":"user","content":[{"type":"text","text":"Inspect the parser"},{"type":"tool_result","content":"GENERIC-SECRET-TOOL-OUTPUT"}]}"#,
            #"{"role":"assistant","content":[{"type":"output_text","text":"The parser is fixed"},{"type":"function_call_output","output":"GENERIC-SECRET-FUNCTION-OUTPUT"}]}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let sources: [(agent: SessionAgent, usesGrokTranscriptLayout: Bool)] = [
            (.registered(RegisteredSessionAgent(id: "generic")), false),
            (.grok, true),
        ]
        for source in sources {
            let turns = try await SessionTranscriptLoader.load(source: .init(
                agent: source.agent,
                sessionId: "generic-tool-session",
                fileURL: transcript,
                usesGrokTranscriptLayout: source.usesGrokTranscriptLayout,
                retention: .transferOpeningUserAndLatest(
                    turnLimit: 1_000,
                    textByteLimit: 32 * 1_024
                )
            ))
            let transferredText = turns.map(\.text).joined(separator: "\n")

            #expect(transferredText.contains("Inspect the parser"))
            #expect(transferredText.contains("The parser is fixed"))
            #expect(!transferredText.contains("GENERIC-SECRET-TOOL-OUTPUT"))
            #expect(!transferredText.contains("GENERIC-SECRET-FUNCTION-OUTPUT"))
        }
    }

    @Test
    func transferFailsClosedWhenTailSkipsOversizedRecord() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("oversized-transfer-record.jsonl")
        let oversizedToolOutput = String(repeating: "x", count: 2 * 1_024 * 1_024 + 1)
        try [
            #"{"role":"user","content":"Opening request"}"#,
            #"{"role":"assistant","content":"Latest verified dialogue"}"#,
            #"{"role":"tool","content":"\#(oversizedToolOutput)"}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        await #expect(throws: (any Error).self) {
            try await SessionTranscriptLoader.load(source: .init(
                agent: .registered(RegisteredSessionAgent(id: "generic")),
                sessionId: "oversized-transfer-session",
                fileURL: transcript,
                retention: .transferOpeningUserAndLatest(
                    turnLimit: 1_000,
                    textByteLimit: 32 * 1_024
                )
            ))
        }
    }

    @Test
    func transferRetentionSkipsToolOutputBeforeBudgetingLatestDialogue() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("codex-tool-tail.jsonl")
        try [
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Opening request"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"LATEST-DIALOGUE-MARKER"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"\#(String(repeating: "x", count: 40_000))"}}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .codex,
            sessionId: "codex-tool-tail",
            fileURL: transcript,
            retention: .transferOpeningUserAndLatest(
                turnLimit: 1_000,
                textByteLimit: 8 * 1_024
            )
        ))

        #expect(turns.contains { $0.text.contains("Opening request") })
        #expect(turns.contains { $0.text.contains("LATEST-DIALOGUE-MARKER") })
        #expect(!turns.contains { $0.role == .tool })
    }

    @Test
    func transferRetentionPreservesTheTailOfLongLatestDialogue() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("long-latest-dialogue.jsonl")
        let latestMarker = "LATEST-LONG-TURN-MARKER"
        let records: [[String: Any]] = [
            ["role": "user", "content": "Opening request"],
            [
                "role": "assistant",
                "content": String(repeating: "x", count: 45_000) + latestMarker,
            ],
        ]
        let transcriptData = try records.map {
            try JSONSerialization.data(withJSONObject: $0)
        }.reduce(into: Data()) { data, record in
            if !data.isEmpty { data.append(0x0a) }
            data.append(record)
        }
        try transcriptData.write(to: transcript)

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .registered(RegisteredSessionAgent(id: "generic")),
            sessionId: "long-latest-dialogue",
            fileURL: transcript,
            retention: .transferOpeningUserAndLatest(
                turnLimit: 1_000,
                textByteLimit: 64 * 1_024
            )
        ))

        #expect(turns.contains { $0.text.contains(latestMarker) })
    }

    @Test
    func rovoTransferBudgetsLatestDialogueAfterTrailingToolRows() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("rovo-tool-heavy.json")
        let toolMessages = (0..<1_001)
            .map { index in
                #"{"role":"tool","content":"excluded-\#(index)"}"#
            }
            .joined(separator: ",\n")
        try """
        {
          "messages": [
            {"role":"user","content":"Rovo opening request"},
            {"role":"assistant","content":"LATEST-ROVO-DIALOGUE"},
            \(toolMessages)
          ]
        }
        """.write(to: transcript, atomically: true, encoding: .utf8)

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .rovodev,
            sessionId: "rovo-tool-heavy",
            fileURL: transcript,
            retention: .transferOpeningUserAndLatest(
                turnLimit: 2,
                textByteLimit: 32 * 1_024
            )
        ))

        #expect(turns.map(\.text) == [
            "Rovo opening request",
            "LATEST-ROVO-DIALOGUE",
        ])
        #expect(!turns.contains { $0.role == .tool })
    }

    @Test
    func jsonlTransferFailsClosedWhenOpeningExceedsByteBound() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("generic-history.jsonl")
        let paddingText = String(repeating: "x", count: 1_024)
        let padding = (0..<5_000).map { _ in
            #"{"role":"system","content":"\#(paddingText)"}"#
        }
        try (
            padding
                + [
                    #"{"role":"user","content":"OUT-OF-BOUND-OPENING"}"#,
                    #"{"role":"assistant","content":"LATEST-GENERIC-DIALOGUE"}"#,
                ]
        ).joined(separator: "\n").write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )

        await #expect {
            try await SessionTranscriptLoader.load(source: .init(
                agent: .registered(RegisteredSessionAgent(id: "generic")),
                sessionId: "generic-bounded-opening",
                fileURL: transcript,
                retention: .transferOpeningUserAndLatest(
                    turnLimit: 1,
                    textByteLimit: 32 * 1_024
                )
            ))
        } throws: { error in
            guard case SessionTranscriptLoadError.incompleteSource = error else {
                return false
            }
            return true
        }
    }

    @Test
    func jsonlTransferFailsClosedWhenNewestRecordIsMalformed() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("malformed-latest.jsonl")
        try [
            #"{"role":"user","content":"opening request"}"#,
            #"{"role":"assistant","content":"stale response"}"#,
            #"{"role":"assistant","content":"new response""#,
        ].joined(separator: "\n").write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )

        await #expect {
            try await SessionTranscriptLoader.load(source: .init(
                agent: .registered(RegisteredSessionAgent(id: "generic")),
                sessionId: "malformed-latest",
                fileURL: transcript,
                retention: .transferOpeningUserAndLatest(
                    turnLimit: 1,
                    textByteLimit: 32 * 1_024
                )
            ))
        } throws: { error in
            guard case SessionTranscriptLoadError.incompleteSource = error else {
                return false
            }
            return true
        }
    }

    @Test
    func antigravityTransferFailsClosedWhenOpeningExceedsByteBound() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("antigravity-history.jsonl")
        let paddingText = String(repeating: "x", count: 1_024)
        let padding = (0..<5_000).map { index in
            #"{"conversationId":"padding-\#(index)","display":"\#(paddingText)"}"#
        }
        try (
            padding
                + [
                    #"{"conversationId":"bounded-session","display":"OUT-OF-BOUND-OPENING"}"#,
                    #"{"conversationId":"bounded-session","display":"LATEST-ANTIGRAVITY-MARKER"}"#,
                ]
        ).joined(separator: "\n").write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )

        await #expect {
            try await SessionTranscriptLoader.load(source: .init(
                agent: .registered(RegisteredSessionAgent(id: "antigravity")),
                sessionId: "bounded-session",
                fileURL: transcript,
                retention: .transferOpeningUserAndLatest(
                    turnLimit: 1,
                    textByteLimit: 32 * 1_024
                )
            ))
        } throws: { error in
            guard case SessionTranscriptLoadError.incompleteSource = error else {
                return false
            }
            return true
        }
    }

    @Test
    func openCodeDatabaseTranscriptSeedsClaudeCode() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let database = fixture.appendingPathComponent("opencode.db")
        try createOpenCodeDatabase(at: database)
        let service = AgentConversationExportService(
            readerRegistry: AgentConversationReaderRegistry(adapters: [
                OpenCodeAgentConversationSourceAdapter(databasePath: database.path),
            ])
        )

        let command = try #require(try await AgentConversationForkRequest(
            targetHarness: .claude,
            destination: .bottom
        ).startupCommandOverride(
            sourceSnapshot: SessionRestorableAgentSnapshot(
                kind: .opencode,
                sessionId: "open-session"
            ),
            exportService: service
        ))
        let message = try transferredFirstMessage(from: command)

        #expect(try transferredInteractiveCommand(from: command) == "exec \(AgentResumeArgv.claudeWrapperShellExecutableToken)")
        #expect(message.contains("Inspect OpenCode storage"))
        #expect(message.contains("Storage is SQLite-backed"))
    }

    @Test
    func openCodeTransferRetentionKeepsOpeningRequestAndNewestSuffix() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let database = fixture.appendingPathComponent("opencode.db")
        try createOpenCodeRetentionDatabase(at: database)

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .opencode,
            sessionId: "retention-session",
            fileURL: nil,
            openCodeDatabasePath: database.path,
            retention: .openingUserAndLatest(3)
        ))

        #expect(turns.map(\.text) == [
            "OpenCode turn 0",
            "OpenCode turn 11",
            "OpenCode turn 12",
        ])
    }

    @Test
    func openCodeTransferRetentionPagesPastExcludedToolRows() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let database = fixture.appendingPathComponent("opencode-tool-heavy.db")
        try createOpenCodeToolHeavyDatabase(at: database)

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .opencode,
            sessionId: "tool-heavy-session",
            fileURL: nil,
            openCodeDatabasePath: database.path,
            retention: .transferOpeningUserAndLatest(
                turnLimit: 2,
                textByteLimit: 32 * 1_024
            )
        ))

        #expect(turns.map(\.text) == [
            "OpenCode opening request",
            "LATEST-OPENCODE-DIALOGUE",
        ])
        #expect(!turns.contains { $0.role == .tool })
    }

    @Test
    func openCodeTargetSeedsTheInteractiveTUI() throws {
        let command = try #require(
            AgentConversationForkRequest.TargetHarness.opencode.startupCommand(
                handoffMessage: "User:\nContinue this work"
            )
        )

        #expect(try transferredInteractiveCommand(from: command) == "exec opencode")
        #expect(try transferredFirstMessage(from: command) == "User:\nContinue this work")
        #expect(!command.contains("Continue this work"))
    }

    @Test
    func nativeForkCommandKeepsDefaultPriorityAboveCrossHarnessPicker() {
        let genericBoost = ContentView.commandPaletteForkPriorityBoost(
            commandId: "palette.forkAgentConversation",
            query: "fork"
        )
        let nativeBoost = ContentView.commandPaletteForkPriorityBoost(
            commandId: "palette.forkAgentConversationRight",
            query: "fork"
        )

        #expect(nativeBoost > genericBoost)
        #expect(genericBoost > 0)
        #expect(ContentView.commandPaletteShouldDismissBeforeRun(
            forCommandId: "palette.forkAgentConversation"
        ))
        #expect(ContentView.commandPaletteShouldDismissBeforeRun(
            forCommandId: "palette.forkAgentConversationRight"
        ))
    }

    @Test
    func crossHarnessForkCreatesSplitWithTransferredPrompt() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let snapshot = try makeCodexSnapshot(in: fixture)
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelId)
        let liveAgentIndex = makeLiveAgentIndex(
            snapshot: snapshot,
            workspaceId: workspace.id,
            panelId: sourcePanelId,
            root: fixture
        )

        let didFork = await workspace.forkAgentConversation(
            fromPanelId: sourcePanelId,
            snapshot: snapshot,
            request: .init(targetHarness: .claude, destination: .right),
            liveAgentIndex: liveAgentIndex
        )

        #expect(didFork)
        #expect(workspace.bonsplitController.allPaneIds.count == 2)
        let forkPanelId = try #require(workspace.focusedPanelId)
        let forkPanel = try #require(workspace.terminalPanel(for: forkPanelId))
        let launcher = try launcherScript(from: forkPanel.surface.initialInput)
        defer { try? FileManager.default.removeItem(at: launcher.url) }
        #expect(forkPanelId != sourcePanelId)
        #expect(try transferredInteractiveCommand(from: launcher.contents).contains(AgentResumeArgv.claudeWrapperShellExecutableToken))
        #expect(try transferredFirstMessage(from: launcher.contents).contains("Preserve destination behavior"))
    }

    @Test
    func crossHarnessForkCreatesSiblingTabWithTransferredPrompt() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let snapshot = try makeCodexSnapshot(in: fixture)
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let sourcePaneId = try #require(workspace.paneId(forPanelId: sourcePanelId))
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelId)
        let liveAgentIndex = makeLiveAgentIndex(
            snapshot: snapshot,
            workspaceId: workspace.id,
            panelId: sourcePanelId,
            root: fixture
        )

        let didFork = await workspace.forkAgentConversation(
            fromPanelId: sourcePanelId,
            snapshot: snapshot,
            request: .init(targetHarness: .claude, destination: .newTab),
            liveAgentIndex: liveAgentIndex
        )

        #expect(didFork)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
        #expect(workspace.bonsplitController.tabs(inPane: sourcePaneId).count == 2)
        let forkPanelId = try #require(workspace.focusedPanelId)
        let forkPanel = try #require(workspace.terminalPanel(for: forkPanelId))
        let launcher = try launcherScript(from: forkPanel.surface.initialInput)
        defer { try? FileManager.default.removeItem(at: launcher.url) }
        #expect(forkPanelId != sourcePanelId)
        #expect(try transferredFirstMessage(from: launcher.contents).contains("Preserve destination behavior"))
    }

    @Test
    func crossHarnessForkCreatesWorkspaceWithTransferredPrompt() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let snapshot = try makeCodexSnapshot(in: fixture)
        let tabManager = TabManager()
        let sourceWorkspace = try #require(tabManager.tabs.first)
        let sourcePanelId = try #require(sourceWorkspace.focusedPanelId)
        sourceWorkspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelId)
        let liveAgentIndex = makeLiveAgentIndex(
            snapshot: snapshot,
            workspaceId: sourceWorkspace.id,
            panelId: sourcePanelId,
            root: fixture
        )

        let didFork = await sourceWorkspace.forkAgentConversation(
            fromPanelId: sourcePanelId,
            snapshot: snapshot,
            request: .init(targetHarness: .claude, destination: .newWorkspace),
            liveAgentIndex: liveAgentIndex
        )

        #expect(didFork)
        #expect(tabManager.tabs.count == 2)
        let forkWorkspace = try #require(tabManager.tabs.first { $0.id != sourceWorkspace.id })
        let forkPanelId = try #require(forkWorkspace.focusedPanelId)
        let forkPanel = try #require(forkWorkspace.terminalPanel(for: forkPanelId))
        let launcher = try launcherScript(from: forkPanel.surface.initialInput)
        defer { try? FileManager.default.removeItem(at: launcher.url) }
        #expect(try transferredFirstMessage(from: launcher.contents).contains("Preserve destination behavior"))
    }

    @Test
    func crossHarnessForkCancelsWhenConversationChangesDuringExport() async throws {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "original-session",
            transcriptPath: "/unused/original-transcript.jsonl"
        )
        let replacement = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "replacement-session",
            transcriptPath: "/unused/replacement-transcript.jsonl"
        )
        let transcriptGate = SuspendingTranscriptGate()
        let exportService = AgentConversationExportService(
            readerRegistry: AgentConversationReaderRegistry(adapters: [
                SuspendingSourceAdapter(gate: transcriptGate),
            ])
        )
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelId)
        let liveAgentIndex = makeLiveAgentIndex(
            snapshot: snapshot,
            workspaceId: workspace.id,
            panelId: sourcePanelId,
            root: FileManager.default.temporaryDirectory
        )
        _ = await liveAgentIndex.indexRefreshingNow()

        let forkTask = Task { @MainActor in
            await workspace.forkAgentConversation(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                request: .init(targetHarness: .claude, destination: .right),
                exportService: exportService,
                liveAgentIndex: liveAgentIndex
            )
        }
        await transcriptGate.waitUntilReadStarts()
        workspace.setRestoredAgentSnapshotForTesting(replacement, panelId: sourcePanelId)
        await transcriptGate.finishRead()

        #expect(await forkTask.value == false)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
        #expect(workspace.focusedPanelId == sourcePanelId)
    }

    @Test
    func crossHarnessForkRejectsFreshLiveSessionDifferentFromCachedSelection() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let cachedSnapshot = try makeCodexSnapshot(
            in: fixture,
            sessionID: "cached-session"
        )
        let currentDirectory = fixture.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(
            at: currentDirectory,
            withIntermediateDirectories: true
        )
        let currentSnapshot = try makeCodexSnapshot(
            in: currentDirectory,
            sessionID: "current-session"
        )
        let sourceAdapter = ReadRecordingSourceAdapter()
        let exportService = AgentConversationExportService(
            readerRegistry: AgentConversationReaderRegistry(adapters: [sourceAdapter])
        )
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(cachedSnapshot, panelId: sourcePanelId)
        let panelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: workspace.id,
            panelId: sourcePanelId
        )
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let liveAgentIndex = SharedLiveAgentIndex(
            indexLoader: {
                let snapshot = loadCount.withLock { count in
                    defer { count += 1 }
                    return count == 0 ? cachedSnapshot : currentSnapshot
                }
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: fixture.path,
                    fileManager: .default,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: snapshot,
                            updatedAt: 42,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: index.liveAgentProcessFingerprint(),
                    processScopeFingerprint: [],
                    forkValidatedPanels: [panelKey]
                )
            },
            hookStoreDirectoryProvider: { fixture.path },
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )
        _ = await liveAgentIndex.indexRefreshingNow()

        let didFork = await workspace.forkAgentConversation(
            fromPanelId: sourcePanelId,
            snapshot: cachedSnapshot,
            request: .init(targetHarness: .claude, destination: .right),
            exportService: exportService,
            liveAgentIndex: liveAgentIndex
        )

        #expect(!didFork)
        #expect(await sourceAdapter.readCount == 0)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
    }

    @Test
    func freshTransferSnapshotRejectsCrossWorkspacePanelAlias() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let snapshot = try makeCodexSnapshot(in: fixture)
        let requestedWorkspaceId = UUID()
        let indexedWorkspaceId = UUID()
        let panelId = UUID()
        let liveAgentIndex = makeLiveAgentIndex(
            snapshot: snapshot,
            workspaceId: indexedWorkspaceId,
            panelId: panelId,
            root: fixture
        )

        let freshSnapshot = await liveAgentIndex.freshConversationTransferSnapshot(
            workspaceId: requestedWorkspaceId,
            panelId: panelId
        )

        #expect(freshSnapshot == nil)
    }

    @Test
    func crossHarnessForkPerformsOneFreshIndexScan() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let snapshot = try makeCodexSnapshot(in: fixture)
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelId)
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let liveAgentIndex = makeLiveAgentIndex(
            snapshot: snapshot,
            workspaceId: workspace.id,
            panelId: sourcePanelId,
            root: fixture,
            onLoad: {
                loadCount.withLock { $0 += 1 }
            }
        )

        let didFork = await workspace.forkAgentConversation(
            fromPanelId: sourcePanelId,
            snapshot: snapshot,
            request: .init(targetHarness: .claude, destination: .right),
            liveAgentIndex: liveAgentIndex
        )

        #expect(didFork)
        #expect(loadCount.withLock { $0 } == 1)
    }

    @Test
    func concurrentFreshTransferSnapshotsCoalesceIndexScan() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let snapshot = try makeCodexSnapshot(in: fixture)
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: fixture.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                panelKey: (
                    snapshot: snapshot,
                    updatedAt: 42,
                    processIDs: [],
                    agentProcessIDs: [],
                    sessionIDSource: .explicit
                ),
            ]
        )
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let loadStarted = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)
        let liveAgentIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadCount.withLock { $0 += 1 }
                loadStarted.signal()
                _ = releaseLoad.wait(timeout: .now() + 2)
                return (
                    index: index,
                    liveAgentProcessFingerprint: index.liveAgentProcessFingerprint(),
                    processScopeFingerprint: [],
                    forkValidatedPanels: [panelKey]
                )
            },
            hookStoreDirectoryProvider: { fixture.path },
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )

        let first = Task { @MainActor in
            await liveAgentIndex.freshConversationTransferSnapshot(
                workspaceId: workspaceId,
                panelId: panelId
            )
        }
        let firstLoadStarted = await Task.detached {
            loadStarted.wait(timeout: .now() + 2) == .success
        }.value
        #expect(firstLoadStarted)
        let second = Task { @MainActor in
            await liveAgentIndex.freshConversationTransferSnapshot(
                workspaceId: workspaceId,
                panelId: panelId
            )
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        releaseLoad.signal()
        releaseLoad.signal()

        #expect(await first.value?.sessionId == snapshot.sessionId)
        #expect(await second.value?.sessionId == snapshot.sessionId)
        #expect(loadCount.withLock { $0 } == 1)
    }

    @Test
    func cancelledCrossHarnessForkRemovesPrivateLauncher() async throws {
        let launcherRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: launcherRoot) }
        let sessionID = "cancel-\(UUID().uuidString)"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            transcriptPath: "/unused/cancelled-transcript.jsonl"
        )
        let transcriptGate = SuspendingTranscriptGate()
        let exportService = AgentConversationExportService(
            readerRegistry: AgentConversationReaderRegistry(adapters: [
                SuspendingSourceAdapter(gate: transcriptGate),
            ])
        )
        let workspace = Workspace()
        let sourcePanelID = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelID)
        let liveAgentIndex = makeLiveAgentIndex(
            snapshot: snapshot,
            workspaceId: workspace.id,
            panelId: sourcePanelID,
            root: FileManager.default.temporaryDirectory
        )

        let launcherDirectory = launcherRoot
            .appendingPathComponent("cmux-r", isDirectory: true)
        let launcherURLsBefore = launcherScripts(in: launcherDirectory)

        let forkTask = Task { @MainActor in
            await workspace.forkAgentConversation(
                fromPanelId: sourcePanelID,
                snapshot: snapshot,
                request: .init(targetHarness: .claude, destination: .right),
                exportService: exportService,
                liveAgentIndex: liveAgentIndex,
                launcherTemporaryDirectory: launcherRoot
            )
        }
        await transcriptGate.waitUntilReadStarts()
        forkTask.cancel()
        await transcriptGate.finishRead()

        #expect(await forkTask.value == false)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
        #expect(launcherScripts(in: launcherDirectory) == launcherURLsBefore)
    }

    @Test
    func crossHarnessForkRejectsRemoteSourceBeforeReadingLocalTranscript() async throws {
        let snapshot = SessionRestorableAgentSnapshot(kind: .codex, sessionId: "remote-session")
        let sourceAdapter = ReadRecordingSourceAdapter()
        let exportService = AgentConversationExportService(
            readerRegistry: AgentConversationReaderRegistry(adapters: [sourceAdapter])
        )
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelId)
        workspace.trackRemoteTerminalSurface(sourcePanelId)

        let didFork = await workspace.forkAgentConversation(
            fromPanelId: sourcePanelId,
            snapshot: snapshot,
            request: .init(targetHarness: .claude, destination: .right),
            exportService: exportService
        )

        #expect(!didFork)
        #expect(await sourceAdapter.readCount == 0)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
    }

    @Test
    func transferRetentionKeepsOpeningRequestAndLatestTurns() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("claude.jsonl")
        try (0..<8).map { index in
            let type = index.isMultiple(of: 2) ? "user" : "assistant"
            return #"{"type":"\#(type)","message":{"role":"\#(type)","content":"turn-\#(index)"}}"#
        }.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .claude,
            sessionId: "session",
            fileURL: transcript,
            retention: .openingUserAndLatest(3)
        ))

        #expect(turns.first?.text.contains("turn-0") == true)
        #expect(turns.last?.text.contains("turn-7") == true)
        #expect(!turns.contains(where: { $0.text.contains("turn-2") }))
    }

    @Test
    func rovoDevTransferRetentionKeepsOpeningRequestAndNewestSuffix() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("rovodev.json")
        let messages = (0..<8).map { index in
            let role = index.isMultiple(of: 2) ? "user" : "assistant"
            return ["role": role, "content": "rovo-turn-\(index)"]
        }
        let data = try JSONSerialization.data(withJSONObject: ["message_history": messages])
        try data.write(to: transcript)

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .rovodev,
            sessionId: "rovo-session",
            fileURL: transcript,
            retention: .openingUserAndLatest(3)
        ))

        #expect(turns.map(\.text) == ["rovo-turn-0\n\nrovo-turn-6", "rovo-turn-7"])
    }

    @Test
    func antigravityTransferRetentionScansPastTailForOpeningRequest() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let transcript = fixture.appendingPathComponent("antigravity.jsonl")
        let sessionID = "antigravity-session"
        let history = (0..<12).map { index in
            #"{"conversationId":"\#(sessionID)","display":"antigravity-turn-\#(index)"}"#
        }.joined(separator: "\n")
        try history.write(to: transcript, atomically: true, encoding: .utf8)

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .registered(RegisteredSessionAgent(id: "antigravity")),
            sessionId: sessionID,
            fileURL: transcript,
            retention: .openingUserAndLatest(3)
        ))

        let transferredText = turns.map(\.text).joined(separator: "\n")
        #expect(transferredText.contains("antigravity-turn-0"))
        #expect(transferredText.contains("antigravity-turn-10"))
        #expect(transferredText.contains("antigravity-turn-11"))
        #expect(!transferredText.contains("antigravity-turn-9"))
    }

    @Test
    func failedDestinationRemovesPrivateCrossHarnessLauncher() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sessionID = "cleanup-\(UUID().uuidString)"
        let snapshot = try makeCodexSnapshot(in: fixture, sessionID: sessionID)
        let workspace = Workspace()
        let sourcePanelID = try #require(workspace.focusedPanelId)
        let sourceSurfaceID = try #require(workspace.surfaceIdFromPanelId(sourcePanelID))
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelID)
        let liveAgentIndex = makeLiveAgentIndex(
            snapshot: snapshot,
            workspaceId: workspace.id,
            panelId: sourcePanelID,
            root: fixture
        )

        let launcherDirectory = fixture
            .appendingPathComponent("cmux-r", isDirectory: true)
        let launcherURLsBefore = launcherScripts(in: launcherDirectory)

        workspace.removeSurfaceMapping(forSurfaceId: sourceSurfaceID)
        let didFork = await workspace.forkAgentConversation(
            fromPanelId: sourcePanelID,
            snapshot: snapshot,
            request: .init(targetHarness: .claude, destination: .newTab),
            liveAgentIndex: liveAgentIndex,
            launcherTemporaryDirectory: fixture
        )

        let launcherURLsAfter = launcherScripts(in: launcherDirectory)
        #expect(!didFork)
        #expect(FileManager.default.fileExists(atPath: launcherDirectory.path))
        #expect(launcherURLsAfter == launcherURLsBefore)
    }

    @Test
    func largeCrossHarnessCommandUsesPrivateSelfDeletingLauncher() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let snapshot = SessionRestorableAgentSnapshot(kind: .codex, sessionId: "large-session")
        let command = (["claude"] + Array(repeating: "context", count: 500))
            .joined(separator: " ")

        let input = try #require(snapshot.customStartupInput(
            command: command,
            temporaryDirectory: fixture
        ))
        let prefix = " /bin/zsh '"
        #expect(input.hasPrefix(prefix))
        let path = String(input.dropFirst(prefix.count).dropLast(2))
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777

        #expect(permissions == 0o600)
        #expect(contents.contains("rm -f -- \"$0\""))
        #expect(contents.contains(command))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cross-harness-fork-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func transferredInteractiveCommand(from startupCommand: String) throws -> String {
        try decodedTransferAdapterValue(named: "cmux_command", from: startupCommand)
    }

    private func transferredFirstMessage(from startupCommand: String) throws -> String {
        try decodedTransferAdapterValue(named: "cmux_message", from: startupCommand)
    }

    private func decodedTransferAdapterValue(
        named name: String,
        from startupCommand: String
    ) throws -> String {
        let prefix = "set \(name) [encoding convertfrom utf-8 [binary format H* {"
        let suffix = "}]]"
        guard let line = startupCommand.split(separator: "\n").first(where: {
            $0.hasPrefix(prefix) && $0.hasSuffix(suffix)
        }) else {
            throw OpenCodeFixtureError.invalidLauncherInput
        }
        let encoded = String(line.dropFirst(prefix.count).dropLast(suffix.count))
        guard encoded.utf8.count.isMultiple(of: 2) else {
            throw OpenCodeFixtureError.invalidLauncherInput
        }
        var bytes: [UInt8] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let nextIndex = encoded.index(index, offsetBy: 2)
            guard let byte = UInt8(encoded[index..<nextIndex], radix: 16) else {
                throw OpenCodeFixtureError.invalidLauncherInput
            }
            bytes.append(byte)
            index = nextIndex
        }
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw OpenCodeFixtureError.invalidLauncherInput
        }
        return value
    }

    private func permissions(at url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return try #require(value as? NSNumber).intValue & 0o777
    }

    /// Connects the process to a user-input pipe and emits the explicit
    /// confirmation only after the cmux-owned prompt is visible.
    private func runWithTransferConfirmation(_ process: Process) throws -> Process {
        let userInput = Pipe()
        let harnessOutput = Pipe()
        process.standardInput = userInput
        process.standardOutput = harnessOutput

        let confirmationProcess = Process()
        confirmationProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        confirmationProcess.arguments = [
            "-c",
            """
            if /usr/bin/grep -F -m 1 'Control-]' >/dev/null; then
              /usr/bin/printf '\\035'
              /bin/cat >/dev/null
            fi
            """,
        ]
        confirmationProcess.standardInput = harnessOutput
        confirmationProcess.standardOutput = userInput
        confirmationProcess.standardError = FileHandle.nullDevice

        try confirmationProcess.run()
        do {
            try process.run()
        } catch {
            confirmationProcess.terminate()
            throw error
        }
        for handle in [
            userInput.fileHandleForReading,
            userInput.fileHandleForWriting,
            harnessOutput.fileHandleForReading,
            harnessOutput.fileHandleForWriting,
        ] {
            try? handle.close()
        }
        return confirmationProcess
    }

    private func runWithDelayedTransferConfirmation(_ process: Process) throws -> Process {
        let userInput = Pipe()
        process.standardInput = userInput

        let confirmationProcess = Process()
        confirmationProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        confirmationProcess.arguments = [
            "-c",
            "/bin/sleep 1.5; /usr/bin/printf '\\035'",
        ]
        confirmationProcess.standardOutput = userInput
        confirmationProcess.standardError = FileHandle.nullDevice

        try confirmationProcess.run()
        do {
            try process.run()
        } catch {
            confirmationProcess.terminate()
            throw error
        }
        try? userInput.fileHandleForReading.close()
        try? userInput.fileHandleForWriting.close()
        return confirmationProcess
    }

    private func makeLiveAgentIndex(
        snapshot: SessionRestorableAgentSnapshot,
        workspaceId: UUID,
        panelId: UUID,
        root: URL,
        onLoad: @escaping @Sendable () -> Void = {}
    ) -> SharedLiveAgentIndex {
        let panelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        return SharedLiveAgentIndex(
            indexLoader: {
                onLoad()
                let index = RestorableAgentSessionIndex.load(
                    homeDirectory: root.path,
                    fileManager: .default,
                    registry: CmuxVaultAgentRegistry(registrations: []),
                    detectedSnapshots: [
                        panelKey: (
                            snapshot: snapshot,
                            updatedAt: 42,
                            processIDs: [],
                            agentProcessIDs: [],
                            sessionIDSource: .explicit
                        ),
                    ]
                )
                return (
                    index: index,
                    liveAgentProcessFingerprint: index.liveAgentProcessFingerprint(),
                    processScopeFingerprint: [],
                    forkValidatedPanels: [panelKey]
                )
            },
            hookStoreDirectoryProvider: { root.path },
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )
    }

    private func makeCodexSnapshot(
        in directory: URL,
        sessionID: String = "codex-destination-session"
    ) throws -> SessionRestorableAgentSnapshot {
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        try [
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Preserve destination behavior"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Use the shared executor"}]}}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        return SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: directory.path,
            transcriptPath: transcript.path
        )
    }

    private func createOpenCodeDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw OpenCodeFixtureError.sqlite
        }
        defer { sqlite3_close(database) }
        let sql = #"""
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
        CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT);
        INSERT INTO message VALUES ('m1', 'open-session', 1, '{"role":"user"}');
        INSERT INTO message VALUES ('m2', 'open-session', 2, '{"role":"assistant"}');
        INSERT INTO part VALUES ('p1', 'm1', 1, '{"type":"text","text":"Inspect OpenCode storage"}');
        INSERT INTO part VALUES ('p2', 'm2', 2, '{"type":"text","text":"Storage is SQLite-backed"}');
        """#
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeFixtureError.sqlite
        }
    }

    private func createOpenCodeRetentionDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw OpenCodeFixtureError.sqlite
        }
        defer { sqlite3_close(database) }
        let messages = (0..<13).map { index in
            let role = index.isMultiple(of: 2) ? "user" : "assistant"
            return "INSERT INTO message VALUES ('m\(index)', 'retention-session', \(index), '{\"role\":\"\(role)\"}');"
        }
        let parts = (0..<13).map { index in
            "INSERT INTO part VALUES ('p\(index)', 'm\(index)', \(index), '{\"type\":\"text\",\"text\":\"OpenCode turn \(index)\"}');"
        }
        let sql = ([
            "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);",
            "CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT);",
        ] + messages + parts).joined(separator: "\n")
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeFixtureError.sqlite
        }
    }

    private func createOpenCodeToolHeavyDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw OpenCodeFixtureError.sqlite
        }
        defer { sqlite3_close(database) }
        let toolParts = (0..<600).map { index in
            """
            INSERT INTO part VALUES (
              'tool-\(index)',
              'm3',
              \(index + 3),
              '{"type":"tool","tool":"Read","state":{"output":"excluded-\(index)"}}'
            );
            """
        }
        let sql = ([
            "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);",
            "CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT);",
            #"INSERT INTO message VALUES ('m1', 'tool-heavy-session', 1, '{"role":"user"}');"#,
            #"INSERT INTO message VALUES ('m2', 'tool-heavy-session', 2, '{"role":"assistant"}');"#,
            #"INSERT INTO message VALUES ('m3', 'tool-heavy-session', 3, '{"role":"assistant"}');"#,
            #"INSERT INTO part VALUES ('p1', 'm1', 1, '{"type":"text","text":"OpenCode opening request"}');"#,
            #"INSERT INTO part VALUES ('p2', 'm2', 2, '{"type":"text","text":"LATEST-OPENCODE-DIALOGUE"}');"#,
        ] + toolParts).joined(separator: "\n")
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeFixtureError.sqlite
        }
    }

    private func launcherScripts(in directory: URL) -> Set<URL> {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return Set(urls.filter {
            $0.pathExtension == "zsh" && $0.lastPathComponent.hasPrefix("r")
        })
    }

    private func launcherScript(
        from initialInput: String?
    ) throws -> (url: URL, contents: String) {
        let input = try #require(initialInput)
        let prefix = " /bin/zsh '"
        let suffix = "'\n"
        guard input.hasPrefix(prefix), input.hasSuffix(suffix) else {
            throw OpenCodeFixtureError.invalidLauncherInput
        }
        let path = String(input.dropFirst(prefix.count).dropLast(suffix.count))
        let url = URL(fileURLWithPath: path)
        return (
            url,
            try String(contentsOf: url, encoding: .utf8)
        )
    }
}

private struct FailingSourceAdapter: AgentConversationSourceAdapter {
    func supports(_ source: AgentConversationSource) -> Bool { true }

    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn]? {
        throw OpenCodeFixtureError.unexpectedRead
    }
}

private struct SuspendingSourceAdapter: AgentConversationSourceAdapter {
    let gate: SuspendingTranscriptGate

    func supports(_ source: AgentConversationSource) -> Bool { true }

    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn]? {
        await gate.read()
    }
}

private struct ExecutableReplacingSourceAdapter: AgentConversationSourceAdapter {
    let executableURL: URL

    func supports(_ source: AgentConversationSource) -> Bool { true }

    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn]? {
        try "#!/bin/zsh\n/usr/bin/printf 'unrelated 9.9.9\\n'\n".write(
            to: executableURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        return [
            SessionTranscriptTurn(id: 0, role: .user, text: "Continue safely"),
        ]
    }
}

private actor SuspendingTranscriptGate {
    private var readStarted = false
    private var readStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var readContinuation: CheckedContinuation<[SessionTranscriptTurn], Never>?

    func read() async -> [SessionTranscriptTurn] {
        readStarted = true
        readStartWaiters.forEach { $0.resume() }
        readStartWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            readContinuation = continuation
        }
    }

    func waitUntilReadStarts() async {
        guard !readStarted else { return }
        await withCheckedContinuation { continuation in
            readStartWaiters.append(continuation)
        }
    }

    func finishRead() {
        readContinuation?.resume(returning: [
            SessionTranscriptTurn(id: 0, role: .user, text: "Continue the original work"),
        ])
        readContinuation = nil
    }
}

private actor ReadRecordingSourceAdapter: AgentConversationSourceAdapter {
    private(set) var readCount = 0

    nonisolated func supports(_ source: AgentConversationSource) -> Bool { true }

    func read(_ source: AgentConversationSource) async throws -> [SessionTranscriptTurn]? {
        readCount += 1
        return []
    }
}

private enum OpenCodeFixtureError: Error {
    case invalidLauncherInput
    case sqlite
    case unexpectedRead
}
