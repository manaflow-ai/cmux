import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct TerminalUploadCommandTests {
    // MARK: - Host normalization

    @Test func hostForMatchingStripsUserAndLowercases() {
        #expect(
            TerminalUploadCommand.hostForMatching("Me@Host1.Corp.Example.COM")
                == "host1.corp.example.com"
        )
        #expect(TerminalUploadCommand.hostForMatching("[2001:db8::1]") == "2001:db8::1")
        #expect(TerminalUploadCommand.hostForMatching("  host  ") == "host")
    }

    // MARK: - Glob matching (fnmatch / ssh_config style)

    @Test func hostMatchesGlob() {
        #expect(TerminalUploadCommand.hostMatches(pattern: "*.example.com", host: "host1.corp.example.com"))
        #expect(TerminalUploadCommand.hostMatches(pattern: "host*", host: "host1.corp.example.com"))
        #expect(!TerminalUploadCommand.hostMatches(pattern: "*.example.com", host: "localhost"))
        // Pattern is lowercased to match the pre-lowercased host.
        #expect(TerminalUploadCommand.hostMatches(pattern: "LOCALHOST", host: "localhost"))
        #expect(!TerminalUploadCommand.hostMatches(pattern: "", host: "localhost"))
    }

    // MARK: - Rule resolution (first-match-wins, catch-all, enabled)

    @Test func commandFirstMatchWins() {
        let resolver = TerminalUploadCommand(rules: [
            TerminalUploadCommandRule(hostPattern: "host*.corp.example.com", command: "A"),
            TerminalUploadCommandRule(hostPattern: "*.example.com", command: "B"),
            TerminalUploadCommandRule(hostPattern: nil, command: "C"),
        ])
        #expect(resolver.command(forDestination: "me@host1.corp.example.com") == "A")
        #expect(resolver.command(forDestination: "other.example.com") == "B")
        // No hostPattern acts as a catch-all (so localhost hits it here).
        #expect(resolver.command(forDestination: "localhost") == "C")
    }

    @Test func noMatchWithoutCatchAllReturnsNil() {
        let resolver = TerminalUploadCommand(rules: [
            TerminalUploadCommandRule(hostPattern: "*.example.com", command: "A"),
        ])
        #expect(resolver.command(forDestination: "localhost") == nil)
    }

    @Test func disabledRuleIsSkipped() {
        let resolver = TerminalUploadCommand(rules: [
            TerminalUploadCommandRule(hostPattern: "*", command: "A", enabled: false),
            TerminalUploadCommandRule(hostPattern: "*", command: "B"),
        ])
        #expect(resolver.command(forDestination: "anything") == "B")
    }

    // MARK: - Decoding (strict, whole-array) — the SettingCodable path used by cmux.json

    /// Decodes the rule array the way the settings catalog does (all-or-nothing).
    private func decode(_ json: String) -> [TerminalUploadCommandRule]? {
        let raw = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        return [TerminalUploadCommandRule].decodeFromJSON(raw)
    }

    @Test func decodeValidArray() {
        guard let rules = decode(#"[{"hostPattern":"*.example.com","command":"upload-tool put"}]"#) else {
            Issue.record("expected a decoded rule")
            return
        }
        #expect(rules.count == 1)
        #expect(rules[0].command == "upload-tool put")
        #expect(rules[0].hostPattern == "*.example.com")
        #expect(rules[0].enabled)
    }

    @Test func decodeRejectsWholeArrayOnMalformedEntry() {
        // Second entry has no `command` → the array rejects as a whole, so no rules
        // apply and the built-in scp runs.
        #expect(decode(#"[{"command":"ok"},{"hostPattern":"x"}]"#) == nil)
    }

    @Test func decodeRejectsBlankCommand() {
        #expect(decode(#"[{"command":"   "}]"#) == nil)
    }

    @Test func decodeRejectsScalarElementWithoutCrashing() {
        // A user misreading the setting as a list of command strings must fail
        // closed, not crash (JSONSerialization raises an uncatchable exception on a
        // non-collection value unless we guard on the object shape first).
        #expect(decode(#"["my-upload $CMUX_UPLOAD_LOCAL_PATH"]"#) == nil)
        #expect(decode(#"[42]"#) == nil)
    }

    @Test func decodeRejectsUnknownKey() {
        // A typoed key (e.g. "enable") must reject the rule, not silently default
        // enabled to true and run the command.
        #expect(decode(#"[{"command":"ok","enable":false}]"#) == nil)
        #expect(decode(#"[{"hostpattern":"*.example.com","command":"ok"}]"#) == nil)
    }

    @Test func decodeRejectsBlankHostPatternButAllowsNullCatchAll() {
        // Present-but-blank hostPattern is rejected (not a silent catch-all)...
        #expect(decode(#"[{"hostPattern":"  ","command":"ok"}]"#) == nil)
        // ...while explicit null is a catch-all.
        guard let rules = decode(#"[{"hostPattern":null,"command":"ok"}]"#) else {
            Issue.record("null hostPattern should decode as a catch-all")
            return
        }
        #expect(rules.count == 1)
        #expect(rules[0].hostPattern == nil)
    }

    @Test func ruleRoundTripsThroughSettingCodable() {
        let rule = TerminalUploadCommandRule(hostPattern: "*.example.com", command: "up", enabled: false)
        #expect(TerminalUploadCommandRule.decodeFromJSON(rule.encodeForJSON()) == rule)
    }

    // MARK: - Emitted text

    @Test func emittedTextPrefersTrimmedStdout() {
        #expect(
            TerminalUploadCommand.emittedText(commandStdout: "  https://x/y  \n", remotePath: "/tmp/p")
                == "https://x/y"
        )
    }

    @Test func emittedTextFallsBackToEscapedRemotePath() {
        // Empty output → the shell-escaped remote path (spaces quoted).
        let emitted = TerminalUploadCommand.emittedText(commandStdout: "  \n", remotePath: "/tmp/a b.png")
        #expect(emitted != "/tmp/a b.png")
        #expect(emitted.contains("a b.png") || emitted.contains("a\\ b.png"))
    }

    @Test func emittedTextStripsControlCharacters() {
        // Interior ESC / CR / newline must not reach the terminal as input.
        let emitted = TerminalUploadCommand.emittedText(
            commandStdout: "https://x/\u{1b}[31my\r\nrm -rf",
            remotePath: "/tmp/p"
        )
        #expect(!emitted.contains("\u{1b}"))
        #expect(!emitted.contains("\r"))
        #expect(!emitted.contains("\n"))
    }

    @Test func emittedTextFallsBackWhenOutputIsOnlyControlCharacters() {
        // Output that is entirely control characters must collapse to empty and
        // fall back to the escaped remote path — not yield "" (a spurious failure).
        let emitted = TerminalUploadCommand.emittedText(
            commandStdout: "\u{1b}\u{01}\u{02}",
            remotePath: "/tmp/cmux-drop-x.png"
        )
        #expect(emitted.contains("cmux-drop"))
    }

    // MARK: - Environment

    @Test func environmentCarriesContext() {
        let env = TerminalUploadCommand.environment(
            localPath: "/l",
            remotePath: "/r",
            destination: "me@h",
            port: 2222,
            identityFile: "/id",
            sshOptions: ["A=B", "C=D"]
        )
        #expect(env["CMUX_UPLOAD_LOCAL_PATH"] == "/l")
        #expect(env["CMUX_UPLOAD_REMOTE_PATH"] == "/r")
        #expect(env["CMUX_UPLOAD_DESTINATION"] == "me@h")
        #expect(env["CMUX_UPLOAD_PORT"] == "2222")
        #expect(env["CMUX_UPLOAD_IDENTITY_FILE"] == "/id")
        #expect(env["CMUX_UPLOAD_SSH_OPTIONS"] == "A=B\nC=D")
    }

    @Test func environmentOmitsAbsentOptionalFields() {
        let env = TerminalUploadCommand.environment(
            localPath: "/l",
            remotePath: "/r",
            destination: "h",
            port: nil,
            identityFile: nil,
            sshOptions: []
        )
        #expect(env["CMUX_UPLOAD_PORT"] == nil)
        #expect(env["CMUX_UPLOAD_IDENTITY_FILE"] == nil)
        #expect(env["CMUX_UPLOAD_SSH_OPTIONS"] == nil)
    }
}

@Suite struct TerminalCustomUploadRunnerTests {
    private func endpoint() -> TerminalCustomUploadRunner.Endpoint {
        TerminalCustomUploadRunner.Endpoint(
            destination: "me@host.example.com",
            port: nil,
            identityFile: nil,
            sshOptions: []
        )
    }

    /// A runner with a deterministic fake process runner injected in place of the
    /// real `/bin/sh` spawn.
    private func runner(
        _ fake: @escaping TerminalCustomUploadRunner.ProcessRunner
    ) -> TerminalCustomUploadRunner {
        TerminalCustomUploadRunner(runProcess: fake)
    }

    @Test func perFileStdoutJoinedWithSpaces() {
        let result = runner { _, env, _, _ in
            (0, "OUT:\(env["CMUX_UPLOAD_LOCAL_PATH"] ?? "")", "")
        }.runSync(
            fileURLs: [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")],
            endpoint: endpoint(),
            command: "x",
            operation: TerminalImageTransferOperation()
        )
        guard case .success(let text) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(text == "OUT:/tmp/a.png OUT:/tmp/b.png")
    }

    @Test func nonZeroExitFailsClosed() {
        let result = runner { _, _, _, _ in (1, "", "boom") }.runSync(
            fileURLs: [URL(fileURLWithPath: "/tmp/a.png")],
            endpoint: endpoint(),
            command: "x",
            operation: TerminalImageTransferOperation()
        )
        if case .success = result {
            Issue.record("non-zero exit must fail closed")
        }
    }

    @Test func emptyStdoutEmitsEscapedRemotePath() {
        let result = runner { _, _, _, _ in (0, "", "") }.runSync(
            fileURLs: [URL(fileURLWithPath: "/tmp/a.png")],
            endpoint: endpoint(),
            command: "x",
            operation: TerminalImageTransferOperation()
        )
        guard case .success(let text) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        // Falls back to the cmux-chosen remote path (escaped).
        #expect(text.contains("cmux-drop"))
    }

    @Test func cancelledOperationFailsClosed() {
        let operation = TerminalImageTransferOperation()
        operation.cancel()
        let result = runner { _, _, _, _ in (0, "ok", "") }.runSync(
            fileURLs: [URL(fileURLWithPath: "/tmp/a.png")],
            endpoint: endpoint(),
            command: "x",
            operation: operation
        )
        if case .success = result {
            Issue.record("cancelled operation must fail closed")
        }
    }

    // MARK: - Real /bin/sh process — exercises the default spawnCommand path

    @Test func realProcessCapturesLargeOutputWithoutDeadlock() {
        // Output far larger than a pipe buffer, from a pipeline (so the writer is a
        // grandchild): must not deadlock waiting on an unread pipe.
        let result = TerminalCustomUploadRunner().runSync(
            fileURLs: [URL(fileURLWithPath: "/tmp/a.png")],
            endpoint: endpoint(),
            command: "head -c 200000 /dev/zero | tr '\\0' 'x'",
            operation: TerminalImageTransferOperation()
        )
        guard case .success(let text) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(text.count == 200_000)
    }

    @Test func realProcessFailsClosedOnExcessiveOutput() {
        // Output past the 1 MiB stdout cap must fail closed, not accumulate to OOM.
        let result = TerminalCustomUploadRunner().runSync(
            fileURLs: [URL(fileURLWithPath: "/tmp/a.png")],
            endpoint: endpoint(),
            command: "head -c 2000000 /dev/zero | tr '\\0' 'x'",
            operation: TerminalImageTransferOperation()
        )
        if case .success = result { Issue.record("output over the cap must fail closed") }
    }

    @Test func realProcessTimesOutInsteadOfHanging() {
        // The 1s timeout must make a slow command fail closed. The test is
        // self-bounded (it returns as soon as the timeout fires); asserting only on
        // the functional outcome, not on measured wall-clock, keeps it CI-stable.
        let result = TerminalCustomUploadRunner().runSync(
            fileURLs: [URL(fileURLWithPath: "/tmp/a.png")],
            endpoint: endpoint(),
            command: "sleep 30",
            operation: TerminalImageTransferOperation(),
            timeout: 1
        )
        if case .success = result { Issue.record("timed-out command must fail closed") }
    }

    @Test func realProcessDoesNotHangOnBackgroundedChild() {
        // The shell exits immediately but leaves a backgrounded process holding the
        // stdout write end; the bounded drain must still return with the echoed
        // output rather than waiting on the orphan.
        let result = TerminalCustomUploadRunner().runSync(
            fileURLs: [URL(fileURLWithPath: "/tmp/a.png")],
            endpoint: endpoint(),
            command: "sleep 30 & echo done",
            operation: TerminalImageTransferOperation()
        )
        guard case .success(let text) = result else {
            Issue.record("expected success, got \(String(describing: result))")
            return
        }
        #expect(text == "done")
    }
}
