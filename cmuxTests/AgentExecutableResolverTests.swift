import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

private func testComment(_ message: @autoclosure () -> String) -> Comment? {
    let value = message()
    return value.isEmpty ? nil : Comment(rawValue: value)
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(actual == expected, testComment(message()), sourceLocation: sourceLocation)
}

func expectNotEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(actual != expected, sourceLocation: sourceLocation)
}

func expectTrue(
    _ condition: Bool,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(condition, testComment(message()), sourceLocation: sourceLocation)
}

func expectFalse(
    _ condition: Bool,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(!condition, testComment(message()), sourceLocation: sourceLocation)
}

func expectNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value == nil, sourceLocation: sourceLocation)
}

func expectThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ handler: ((any Error) -> Void)? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        _ = try expression()
        Issue.record("Expected expression to throw", sourceLocation: sourceLocation)
    } catch {
        handler?(error)
    }
}

@Suite(.serialized)
struct AgentExecutableResolverTests {
    @Test
    func testResolvesExecutableFromInjectedPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = AgentExecutableResolver(
            environment: ["PATH": bin.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true)
        )

        let plan = try resolver.resolve(.codex)
        expectEqual(plan.executableURL.path, executable.standardizedFileURL.path)
        expectEqual(plan.arguments, AgentSessionProviderID.codex.launchArguments)
        expectFalse(plan.executableURL.path.contains("/Contents/Resources/bin/"))
    }

    @Test
    func testReturnsMissingForAbsentExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = AgentExecutableResolver(
            environment: ["PATH": root.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true),
            includeStandardSearchDirectories: false
        )

        expectThrowsError(try resolver.resolve(.opencode)) { error in
            guard
                case AgentExecutableResolverError.missing(let displayName, let executableName, _) = error
            else {
                Issue.record("Expected missing executable error, got \(error)")
                return
            }
            expectEqual(displayName, AgentSessionProviderID.opencode.displayName)
            expectEqual(executableName, "opencode")
        }
    }

    @Test
    func testResolvesExecutableInsideAnotherAppBundleResourceBin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let otherAppBin = root
            .appendingPathComponent("Other.app/Contents/Resources/bin", isDirectory: true)
        let cmuxResources = root
            .appendingPathComponent("cmux.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: otherAppBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cmuxResources, withIntermediateDirectories: true)
        let executable = otherAppBin.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = AgentExecutableResolver(
            environment: ["PATH": otherAppBin.path, "HOME": root.path],
            bundleResourceURL: cmuxResources,
            includeStandardSearchDirectories: false
        )

        let plan = try resolver.resolve(.codex)

        expectEqual(plan.executableURL.path, executable.standardizedFileURL.path)
    }

    @Test
    func testSkipsOlderCmuxAppBundleResourceBin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let oldCmuxBin = root
            .appendingPathComponent("cmux DEV old.app/Contents/Resources/bin", isDirectory: true)
        let userBin = root.appendingPathComponent("user-bin", isDirectory: true)
        let cmuxResources = root
            .appendingPathComponent("cmux.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: oldCmuxBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cmuxResources, withIntermediateDirectories: true)
        let bundledExecutable = oldCmuxBin.appendingPathComponent("codex")
        let userExecutable = userBin.appendingPathComponent("codex")
        for executable in [bundledExecutable, userExecutable] {
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = AgentExecutableResolver(
            environment: ["PATH": "\(oldCmuxBin.path):\(userBin.path)", "HOME": root.path],
            bundleResourceURL: cmuxResources,
            includeStandardSearchDirectories: false
        )

        let plan = try resolver.resolve(.codex)

        expectEqual(plan.executableURL.path, userExecutable.standardizedFileURL.path)
    }

    @Test
    func testResolvesConfiguredClaudePathBeforePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let configuredBin = root.appendingPathComponent("configured", isDirectory: true)
        let pathBin = root.appendingPathComponent("path", isDirectory: true)
        try FileManager.default.createDirectory(at: configuredBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pathBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configuredClaude = configuredBin.appendingPathComponent("claude")
        let pathClaude = pathBin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: configuredClaude, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: pathClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: configuredClaude.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pathClaude.path)

        let resolver = AgentExecutableResolver(
            environment: ["PATH": pathBin.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true),
            configuredExecutablePaths: [.claude: configuredClaude.path]
        )

        let plan = try resolver.resolve(.claude)
        expectEqual(plan.executableURL.path, configuredClaude.standardizedFileURL.path)
    }

    @Test
    func testConfiguredProviderDirectoryIsPrependedToRuntimePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let configuredBin = root.appendingPathComponent("configured", isDirectory: true)
        let pathBin = root.appendingPathComponent("path", isDirectory: true)
        try FileManager.default.createDirectory(at: configuredBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pathBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configuredClaude = configuredBin.appendingPathComponent("claude")
        let pathClaude = pathBin.appendingPathComponent("claude")
        try "#!/usr/bin/env node\n".write(to: configuredClaude, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: pathClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: configuredClaude.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pathClaude.path)

        let resolver = AgentExecutableResolver(
            environment: ["PATH": pathBin.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true),
            configuredExecutablePaths: [.claude: configuredClaude.path]
        )

        let plan = try resolver.resolve(.claude)
        let runtimePath = plan.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        expectEqual(plan.executableURL.path, configuredClaude.standardizedFileURL.path)
        expectEqual(runtimePath.first, configuredBin.standardizedFileURL.path)
    }

    @Test
    func testIgnoresBundleResourceBinEvenWhenExecutableExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let resourceBin =
            root
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceBin, withIntermediateDirectories: true)
        let bundledExecutable = resourceBin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: bundledExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: bundledExecutable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = AgentExecutableResolver(
            environment: ["PATH": resourceBin.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Contents/Resources", isDirectory: true),
            includeStandardSearchDirectories: false
        )

        expectThrowsError(try resolver.resolve(.claude)) { error in
            guard
                case AgentExecutableResolverError.missing(let displayName, let executableName, _) = error
            else {
                Issue.record("Expected missing executable error, got \(error)")
                return
            }
            expectEqual(displayName, AgentSessionProviderID.claude.displayName)
            expectEqual(executableName, "claude")
        }
    }

    @Test
    func testIgnoresOtherAppBundleResourceBinEntriesFromPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let otherAppResourceBin =
            root
            .appendingPathComponent("Older cmux.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: otherAppResourceBin, withIntermediateDirectories: true)
        let bundledClaude = otherAppResourceBin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: bundledClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledClaude.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = AgentExecutableResolver(
            environment: ["PATH": otherAppResourceBin.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Current.app/Contents/Resources", isDirectory: true),
            includeStandardSearchDirectories: false
        )

        expectThrowsError(try resolver.resolve(.claude)) { error in
            guard case AgentExecutableResolverError.missing(let displayName, let executableName, _) = error else {
                Issue.record("Expected missing executable error, got \(error)")
                return
            }
            expectEqual(displayName, AgentSessionProviderID.claude.displayName)
            expectEqual(executableName, "claude")
        }
    }

    @Test
    func testIgnoresConfiguredExecutableInsideAppBundleResourceBin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let otherAppResourceBin =
            root
            .appendingPathComponent("Older cmux.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: otherAppResourceBin, withIntermediateDirectories: true)
        let bundledClaude = otherAppResourceBin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: bundledClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledClaude.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = AgentExecutableResolver(
            environment: ["PATH": "", "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Current.app/Contents/Resources", isDirectory: true),
            includeStandardSearchDirectories: false,
            configuredExecutablePaths: [.claude: bundledClaude.path]
        )

        expectThrowsError(try resolver.resolve(.claude)) { error in
            guard case AgentExecutableResolverError.missing(let displayName, let executableName, _) = error else {
                Issue.record("Expected missing executable error, got \(error)")
                return
            }
            expectEqual(displayName, AgentSessionProviderID.claude.displayName)
            expectEqual(executableName, "claude")
        }
    }

    @Test
    func testSkipsCmuxClaudeCommandShim() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let shimBin = root.appendingPathComponent("shim-bin", isDirectory: true)
        let realBin = root.appendingPathComponent("real-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: shimBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let shimClaude = shimBin.appendingPathComponent("claude")
        let realClaude = realBin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 42\n".write(to: shimClaude, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: realClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimClaude.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realClaude.path)

        let resolver = AgentExecutableResolver(
            environment: [
                "PATH": "\(shimBin.path):\(realBin.path)",
                "HOME": root.path,
                "CMUX_CLAUDE_WRAPPER_SHIM": shimClaude.path,
                "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": shimBin.path,
            ],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true)
        )

        let plan = try resolver.resolve(.claude)
        expectEqual(plan.executableURL.path, realClaude.standardizedFileURL.path)
    }

    @Test
    func testProviderLaunchPlansNeverUseEnvFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for provider in AgentSessionProviderID.allCases {
            let executable = bin.appendingPathComponent(provider.executableName)
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let resolver = AgentExecutableResolver(
            environment: ["PATH": bin.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true)
        )

        for provider in AgentSessionProviderID.allCases {
            let plan = try resolver.resolve(provider)
            expectTrue(plan.executableURL.path.hasPrefix(bin.path))
            expectNotEqual(plan.executableURL.path, "/usr/bin/env")
            expectEqual(plan.arguments, provider.launchArguments)
        }
    }

    @Test
    func testClaudeLaunchPlanDoesNotRequestUnhandledPermissionPromptTool() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolver = AgentExecutableResolver(
            environment: ["PATH": bin.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true)
        )

        let plan = try resolver.resolve(.claude)
        expectFalse(plan.arguments.contains("--permission-prompt-tool"))
        expectEqual(
            plan.arguments,
            [
                "-p",
                "--output-format", "stream-json",
                "--input-format", "stream-json",
                "--include-partial-messages",
                "--verbose",
            ])
    }

    @Test
    func testOpenCodeLaunchPlanLetsProviderBindEphemeralPort() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = bin.appendingPathComponent("opencode")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolver = AgentExecutableResolver(
            environment: ["PATH": bin.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true)
        )

        let plan = try resolver.resolve(.opencode)
        expectEqual(
            plan.arguments,
            ["serve", "--hostname", "127.0.0.1", "--port", "0", "--print-logs"]
        )
    }

    @Test
    func testLaunchEnvironmentKeepsPWDInSyncWithWorkingDirectory() {
        let plan = AgentSessionLaunchPlan(
            provider: .codex,
            executableURL: URL(fileURLWithPath: "/tmp/codex"),
            arguments: AgentSessionProviderID.codex.launchArguments,
            environment: [
                "PATH": "/bin",
                "PWD": "/wrong",
            ]
        )

        let environment = plan.environment(
            overridingWorkingDirectory: "/tmp/cmux-agent-session/../cmux-agent-session")

        expectEqual(environment["PATH"], "/bin")
        expectEqual(environment["PWD"], "/tmp/cmux-agent-session")
    }

    @Test
    func testOpenCodeLaunchEnvironmentAddsLoopbackPassword() {
        let plan = AgentSessionLaunchPlan(
            provider: .opencode,
            executableURL: URL(fileURLWithPath: "/tmp/opencode"),
            arguments: AgentSessionProviderID.opencode.launchArguments,
            environment: [
                "PATH": "/bin"
            ]
        )

        let environment = plan.environment(overridingWorkingDirectory: nil)

        expectEqual(environment["OPENCODE_SERVER_USERNAME"], "opencode")
        expectTrue((environment["OPENCODE_SERVER_PASSWORD"] ?? "").count >= 32)
        expectNotEqual(environment["OPENCODE_SERVER_PASSWORD"], plan.environment["OPENCODE_SERVER_PASSWORD"])
    }

    @Test
    func testOpenCodeLaunchEnvironmentPreservesExplicitLoopbackPassword() {
        let plan = AgentSessionLaunchPlan(
            provider: .opencode,
            executableURL: URL(fileURLWithPath: "/tmp/opencode"),
            arguments: AgentSessionProviderID.opencode.launchArguments,
            environment: [
                "OPENCODE_SERVER_USERNAME": "cmux",
                "OPENCODE_SERVER_PASSWORD": "existing-secret",
                "PATH": "/bin"
            ]
        )

        let environment = plan.environment(overridingWorkingDirectory: nil)

        expectEqual(environment["OPENCODE_SERVER_USERNAME"], "cmux")
        expectEqual(environment["OPENCODE_SERVER_PASSWORD"], "existing-secret")
    }

    @Test
    func testAutoStartPolicyMatchesAppServerProviders() {
        expectTrue(AgentSessionProviderID.codex.shouldAutoStartSession)
        expectTrue(AgentSessionProviderID.opencode.shouldAutoStartSession)
        expectFalse(AgentSessionProviderID.claude.shouldAutoStartSession)
    }

    // https://github.com/manaflow-ai/cmux/issues/7035: the configured Claude
    // launch value may be a shell command (receiving the agent arguments as
    // "$@"), not just a binary path, so a `claude` defined as a shell function
    // in the user's rc can be reached.
    @Test
    func testConfiguredClaudeCommandStringResolvesToShellLaunchPlan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let command = #"/bin/zsh -lic 'claude "$@"' claude "$@""#
        let resolver = AgentExecutableResolver(
            environment: ["PATH": root.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true),
            includeStandardSearchDirectories: false,
            configuredExecutablePaths: [.claude: command]
        )

        let plan = try resolver.resolve(.claude)
        expectEqual(plan.executableURL.path, "/bin/sh")
        expectEqual(
            plan.arguments,
            ["-c", command, "claude"] + AgentSessionProviderID.claude.launchArguments)
        expectEqual(plan.environment["CMUX_CLAUDE_CUSTOM_COMMAND_ACTIVE"], "1")
    }

    @Test
    func testConfiguredClaudeCommandIgnoredWhenGuardAlreadyActive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = AgentExecutableResolver(
            environment: [
                "PATH": bin.path,
                "HOME": root.path,
                "CMUX_CLAUDE_CUSTOM_COMMAND_ACTIVE": "1",
            ],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true),
            includeStandardSearchDirectories: false,
            configuredExecutablePaths: [.claude: #"/bin/zsh -lic 'claude "$@"' claude "$@""#]
        )

        let plan = try resolver.resolve(.claude)
        expectEqual(plan.executableURL.path, executable.standardizedFileURL.path)
    }

    // The guard is active iff non-empty (matching the wrapper's `-z` check):
    // an empty inherited value must not disable command mode.
    @Test
    func testConfiguredClaudeCommandAppliesWhenGuardEnvValueIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let command = #"my-wrapper "$@""#
        let resolver = AgentExecutableResolver(
            environment: [
                "PATH": root.path,
                "HOME": root.path,
                "CMUX_CLAUDE_CUSTOM_COMMAND_ACTIVE": "",
            ],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true),
            includeStandardSearchDirectories: false,
            configuredExecutablePaths: [.claude: command]
        )

        let plan = try resolver.resolve(.claude)
        expectEqual(plan.executableURL.path, "/bin/sh")
    }

    // A stale spaced path (no "$@") must keep the silent PATH fallback, not
    // become a hard-failing /bin/sh command.
    @Test
    func testConfiguredStaleSpacedPathFallsBackToPathSearch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let staleSpacedPath = root.appendingPathComponent("dir with space/claude").path
        let resolver = AgentExecutableResolver(
            environment: ["PATH": bin.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true),
            includeStandardSearchDirectories: false,
            configuredExecutablePaths: [.claude: staleSpacedPath]
        )

        let plan = try resolver.resolve(.claude)
        expectEqual(plan.executableURL.path, executable.standardizedFileURL.path)
    }

    @Test
    func testConfiguredStalePlainPathStillFallsBackToPathSearch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let stalePath = root.appendingPathComponent("missing/claude").path
        let resolver = AgentExecutableResolver(
            environment: ["PATH": bin.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true),
            includeStandardSearchDirectories: false,
            configuredExecutablePaths: [.claude: stalePath]
        )

        let plan = try resolver.resolve(.claude)
        expectEqual(plan.executableURL.path, executable.standardizedFileURL.path)
    }

    @Test
    func testSearchesBunBinUnderHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let bunBin = root.appendingPathComponent(".bun/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bunBin, withIntermediateDirectories: true)
        let executable = bunBin.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = AgentExecutableResolver(
            environment: ["PATH": "", "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true)
        )

        let plan = try resolver.resolve(.codex)
        expectEqual(plan.executableURL.path, executable.standardizedFileURL.path)
    }

    @Test
    func testAddsNvmNodeBinToRuntimePathForBunInstalledProviders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let bunBin = root.appendingPathComponent(".bun/bin", isDirectory: true)
        let nodeBin = root.appendingPathComponent(".nvm/versions/node/v25.8.1/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bunBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nodeBin, withIntermediateDirectories: true)
        let executable = bunBin.appendingPathComponent("codex")
        try "#!/usr/bin/env node\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = AgentExecutableResolver(
            environment: ["PATH": "", "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true)
        )

        let plan = try resolver.resolve(.codex)
        let runtimePath = plan.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        expectEqual(plan.executableURL.path, executable.standardizedFileURL.path)
        expectTrue(runtimePath.contains(nodeBin.standardizedFileURL.path))
    }
}
