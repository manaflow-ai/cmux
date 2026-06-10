import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Tmux process-detected resume binding
extension SessionPersistenceTests {
    func testTmuxProcessDetectedResumeBindingPreservesSocketFlags() throws {
        let binding = try XCTUnwrap(
            SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
                processName: "tmux: client",
                processPath: "/opt/homebrew/bin/tmux",
                arguments: ["/opt/homebrew/bin/tmux", "-L", "dev", "attach-session", "-t", "work"],
                environment: ["PWD": "/tmp/project"]
            )
        )

        XCTAssertEqual(binding.kind, "tmux")
        XCTAssertEqual(binding.source, "process-detected")
        XCTAssertEqual(binding.allowsAutomaticResume, true)
        XCTAssertEqual(binding.checkpointId, "work")
        XCTAssertEqual(binding.cwd, "/tmp/project")
        XCTAssertEqual(binding.command, "'/opt/homebrew/bin/tmux' '-L' 'dev' 'attach' '-t' 'work'")
    }

    func testTmuxProcessDetectedResumeBindingPreservesTmuxTmpdir() throws {
        let binding = try XCTUnwrap(
            SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
                processName: "tmux: client",
                processPath: "/opt/homebrew/bin/tmux",
                arguments: ["/opt/homebrew/bin/tmux", "-L", "dev", "attach-session", "-t", "work"],
                environment: [
                    "PWD": "/tmp/project",
                    "TMUX": "/tmp/tmux-current,123,0",
                    "TMUX_TMPDIR": "/var/folders/custom-tmux",
                ]
            )
        )

        XCTAssertEqual(binding.command, "'/opt/homebrew/bin/tmux' '-L' 'dev' 'attach' '-t' 'work'")
        XCTAssertEqual(binding.environment, ["TMUX_TMPDIR": "/var/folders/custom-tmux"])
        let startupInput = try XCTUnwrap(binding.startupInput)
        XCTAssertTrue(startupInput.contains("'TMUX_TMPDIR=/var/folders/custom-tmux'"), startupInput)
        XCTAssertFalse(startupInput.contains("TMUX="), startupInput)
    }

    func testTmuxProcessDetectedResumeBindingParsesAttachAlias() throws {
        let binding = try XCTUnwrap(
            SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
                processName: "tmux: client",
                processPath: "/opt/homebrew/bin/tmux",
                arguments: ["/opt/homebrew/bin/tmux", "a", "-t", "work"],
                environment: [:]
            )
        )

        XCTAssertEqual(binding.checkpointId, "work")
        XCTAssertEqual(binding.command, "'/opt/homebrew/bin/tmux' 'attach' '-t' 'work'")
    }

    func testTmuxProcessDetectedResumeBindingDoesNotUseProcessTitleAsExecutable() throws {
        let binding = try XCTUnwrap(
            SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
                processName: "tmux: client",
                processPath: "/opt/homebrew/bin/tmux",
                arguments: ["tmux: client", "attach-session", "-t", "work"],
                environment: [:]
            )
        )

        XCTAssertEqual(binding.command, "'/opt/homebrew/bin/tmux' 'attach' '-t' 'work'")
    }

    func testTmuxProcessDetectedResumeBindingDropsFullClientProcessTitle() throws {
        let binding = try XCTUnwrap(
            SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
                processName: "tmux: client (/dev/ttys001)",
                processPath: nil,
                arguments: ["tmux: client (/dev/ttys001)", "attach-session", "-t", "work"],
                environment: ["PWD": "/tmp/project"]
            )
        )

        XCTAssertEqual(binding.checkpointId, "work")
        XCTAssertEqual(binding.cwd, "/tmp/project")
        XCTAssertEqual(binding.command, "'tmux' 'attach' '-t' 'work'")
    }

    func testTmuxProcessDetectedResumeBindingRejectsFullServerProcessTitle() {
        let binding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux: server (/private/tmp/tmux-501/default)",
            processPath: nil,
            arguments: ["tmux: server (/private/tmp/tmux-501/default)"],
            environment: [:]
        )

        XCTAssertNil(binding)
    }

    func testTmuxProcessDetectedResumeBindingRejectsServerProcessTitle() {
        let binding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux: server",
            processPath: "/opt/homebrew/bin/tmux",
            arguments: ["tmux: server"],
            environment: [:]
        )

        XCTAssertNil(binding)
    }

    func testTmuxAttachFlagParserTreatsConfigFlagAsValueTaking() {
        let binding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "new", "-fA"],
            environment: [:]
        )

        XCTAssertNil(binding)
    }

    func testTmuxAttachFlagParserTreatsShellCommandFlagAsValueTaking() throws {
        let binding = try XCTUnwrap(
            SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
                processName: "tmux",
                processPath: nil,
                arguments: ["tmux", "-c", "/bin/zsh", "attach", "-t", "work"],
                environment: [:]
            )
        )

        XCTAssertEqual(binding.checkpointId, "work")
        XCTAssertEqual(binding.command, "'tmux' 'attach' '-t' 'work'")
    }

    func testTmuxProcessDetectedResumeBindingRejectsUnnamedAttach() {
        let attachBinding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "attach"],
            environment: [:]
        )
        let aliasBinding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "a"],
            environment: [:]
        )

        XCTAssertNil(attachBinding)
        XCTAssertNil(aliasBinding)
    }

    func testTmuxProcessDetectedResumeBindingRejectsCommandlessClient() {
        let executableOnlyBinding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux"],
            environment: [:]
        )
        let processTitleBinding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux: client",
            processPath: nil,
            arguments: ["tmux: client"],
            environment: [:]
        )

        XCTAssertNil(executableOnlyBinding)
        XCTAssertNil(processTitleBinding)
    }

    func testTmuxOptionValueDoesNotReadTargetFromConfigValue() {
        let binding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "attach", "-factive-pane"],
            environment: [:]
        )

        XCTAssertNil(binding)
    }

    func testTmuxOptionValueStopsAtValueTakingClusterOption() {
        let binding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "new", "-Ans"],
            environment: [:]
        )

        XCTAssertNil(binding)
    }

    func testTmuxOptionValueStopsAtCommandTerminator() {
        let attachBinding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "attach", "--", "-t", "work"],
            environment: [:]
        )
        let newBinding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "new", "-A", "--", "-s", "work"],
            environment: [:]
        )

        XCTAssertNil(attachBinding)
        XCTAssertNil(newBinding)
    }

    func testTmuxProcessDetectedResumeBindingRejectsUnnamedNewAttachSession() {
        let binding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "new-session", "-A"],
            environment: [:]
        )

        XCTAssertNil(binding)
    }

    func testTmuxProcessDetectedResumeBindingParsesNewAttachSession() throws {
        let binding = try XCTUnwrap(
            SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
                processName: "tmux",
                processPath: nil,
                arguments: ["tmux", "new", "-As", "work"],
                environment: [:]
            )
        )

        XCTAssertEqual(binding.checkpointId, "work")
        XCTAssertEqual(binding.command, "'tmux' 'attach' '-t' 'work'")
    }

    func testTmuxProcessDetectedResumeBindingRejectsSessionNameThatLooksLikeAttachFlag() {
        let binding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "new", "-sA"],
            environment: [:]
        )

        XCTAssertNil(binding)
    }

}
