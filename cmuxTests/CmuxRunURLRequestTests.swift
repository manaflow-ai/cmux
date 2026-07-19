import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Secure command deep links", .serialized)
struct CmuxRunURLRequestTests {
    private let scheme = "cmux-test"

    @Test func parsesMinimalWorkspaceRequestWithoutRewritingCommand() throws {
        let request = try parsed([
            .init(name: "command", value: "  claude --resume  "),
            .init(name: "cwd", value: "/tmp/project")
        ])

        #expect(request.command == "  claude --resume  ")
        #expect(request.workingDirectory == "/tmp/project")
        #expect(request.placement == .workspace)
        #expect(request.workspaceId == nil)
        #expect(request.anchor == nil)
    }

    @Test func parsesSurfacePlacementWithPaneAnchor() throws {
        let workspaceId = UUID()
        let paneId = UUID()
        let request = try parsed([
            .init(name: "command", value: "codex"),
            .init(name: "cwd", value: "/tmp/project"),
            .init(name: "placement", value: "surface"),
            .init(name: "workspace", value: workspaceId.uuidString),
            .init(name: "pane", value: paneId.uuidString)
        ])

        #expect(request.workspaceId == workspaceId)
        #expect(request.anchor == .pane(paneId))
        #expect(request.direction == nil)
    }

    @Test func parsesPanePlacementWithStableSurfaceAnchor() throws {
        let workspaceId = UUID()
        let surfaceId = UUID()
        let request = try parsed([
            .init(name: "command", value: "npm test"),
            .init(name: "cwd", value: "/tmp/project"),
            .init(name: "placement", value: "pane"),
            .init(name: "workspace", value: workspaceId.uuidString),
            .init(name: "surface", value: surfaceId.uuidString),
            .init(name: "direction", value: "left")
        ])

        #expect(request.workspaceId == workspaceId)
        #expect(request.anchor == .surface(surfaceId))
        #expect(request.direction == .left)
    }

    @Test func allowsVisibleMultilineShellCommands() throws {
        let request = try parsed([
            .init(name: "command", value: "printf 'one\\n'\nprintf '\ttwo\\n'"),
            .init(name: "cwd", value: "/tmp")
        ])

        #expect(request.command.contains("\n"))
        #expect(request.command.contains("\t"))
    }

    @Test func shellWrapperPreservesQuotesAndExpansion() throws {
        let command = "printf '%s\\n' \"$HOME\""
        let launchCommand = CmuxRunShellCommandBuilder(
            command: command,
            workingDirectory: "/tmp/project's",
            approvedIdentity: .init(device: 1, inode: 2)
        ).launchCommand
        let script = try #require(decodedGuardedScript(from: launchCommand))
        #expect(script.contains("/tmp/project"))
        #expect(script.contains("printf"))
        #expect(script.contains("%s\\n"))
        #expect(script.contains("$HOME"))
    }

    @Test func shellWrapperBindsTheReviewedWorkingDirectoryFailClosed() throws {
        let launchCommand = CmuxRunExecutionPlan(
            command: "printf reviewed",
            workingDirectory: "/tmp/reviewed-directory",
            workingDirectoryIdentity: .init(device: 1, inode: 2),
            target: .newWindow,
            placementDescription: "New workspace",
            targetDescription: "New window"
        ).launchCommand
        let script = try #require(decodedGuardedScript(from: launchCommand))

        #expect(launchCommand.hasPrefix("exec /bin/zsh -dflc "))
        #expect(script.contains("cd -- "))
        #expect(script.contains("/tmp/reviewed-directory"))
        #expect(script.contains("|| builtin exit"))
        #expect(
            script.range(of: "/tmp/reviewed-directory")!.lowerBound
                < script.range(of: "printf reviewed")!.lowerBound
        )
    }

    @Test func shellWrapperExecutesThroughGhosttyEmbeddedShellContract() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let marker = root.appendingPathComponent("command-ran")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let resolved = try CmuxRunWorkingDirectoryResolver().resolve(root.path).get()
        let launchCommand = CmuxRunShellCommandBuilder(
            command: "/usr/bin/touch \(marker.path)",
            workingDirectory: resolved.path,
            approvedIdentity: resolved.identity
        ).launchCommand

        #expect(try runInitialTerminalCommand(launchCommand) == EXIT_SUCCESS)
        #expect(fileManager.fileExists(atPath: marker.path))
    }

    @Test func shellWrapperRevalidatesApprovedDirectoryIdentityAfterEntering() throws {
        let launchCommand = CmuxRunShellCommandBuilder(
            command: "printf reviewed",
            workingDirectory: "/tmp/reviewed-directory",
            approvedIdentity: .init(device: 1, inode: 2)
        ).launchCommand
        let script = try #require(decodedGuardedScript(from: launchCommand))

        #expect(script.contains("builtin cd -- "))
        #expect(script.contains("/usr/bin/stat -f"))
        #expect(
            script.range(of: "/usr/bin/stat -f")!.lowerBound
                < script.range(of: "printf reviewed")!.lowerBound
        )
    }

    @Test func shellWrapperBlocksSamePathDirectoryReplacement() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let approved = root.appendingPathComponent("approved", isDirectory: true)
        let displaced = root.appendingPathComponent("displaced", isDirectory: true)
        try fileManager.createDirectory(at: approved, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let resolved = try CmuxRunWorkingDirectoryResolver().resolve(approved.path).get()
        let launchCommand = CmuxRunShellCommandBuilder(
            command: "true",
            workingDirectory: resolved.path,
            approvedIdentity: resolved.identity
        ).launchCommand

        #expect(try runInitialTerminalCommand(launchCommand) == EXIT_SUCCESS)

        try fileManager.moveItem(at: approved, to: displaced)
        try fileManager.createDirectory(at: approved, withIntermediateDirectories: false)

        #expect(try runInitialTerminalCommand(launchCommand) == 125)
    }

    @Test func shellWrapperDoesNotExposeIdentityStateToReviewedCommand() throws {
        let resolved = try CmuxRunWorkingDirectoryResolver().resolve("/tmp").get()
        let launchCommand = CmuxRunShellCommandBuilder(
            command: "[[ -z ${cmux_directory_identity+x} ]]",
            workingDirectory: resolved.path,
            approvedIdentity: resolved.identity
        ).launchCommand

        #expect(try runInitialTerminalCommand(launchCommand) == EXIT_SUCCESS)
    }

    @Test func shellWrapperSafetyExitsCannotBeAliasedByZshStartupFiles() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let marker = root.appendingPathComponent("command-ran")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        var environment = ProcessInfo.processInfo.environment
        environment["ZDOTDIR"] = root.path
        let bashEnvironment = root.appendingPathComponent("bash-env")
        try "exec() { :; }\n".write(
            to: bashEnvironment,
            atomically: true,
            encoding: .utf8
        )
        environment["BASH_ENV"] = bashEnvironment.path
        environment["BASH_FUNC_exec%%"] = "() { :; }"
        for startupFile in [
            "alias exit=':'\nalias builtin=':'\nalias command=':'\n",
            "exit() { :; }\nbuiltin() { :; }\ncommand() { print '0:0'; }\n"
        ] {
            try startupFile.write(
                to: root.appendingPathComponent(".zshenv"),
                atomically: true,
                encoding: .utf8
            )
            let launchCommand = CmuxRunShellCommandBuilder(
                command: "touch \(marker.path)",
                workingDirectory: root.path,
                approvedIdentity: .init(device: 0, inode: 0)
            ).launchCommand

            #expect(
                try runInitialTerminalCommand(launchCommand, environment: environment) == 125
            )
            #expect(!fileManager.fileExists(atPath: marker.path))
        }
    }

    @Test(arguments: ["\u{0000}", "\r", "\u{202E}", "\u{2066}", "\u{2028}"])
    func rejectsHiddenCommandCharacters(_ hidden: String) throws {
        let result = parse([
            .init(name: "command", value: "echo safe\(hidden)unsafe"),
            .init(name: "cwd", value: "/tmp")
        ])
        #expect(result == .failure(.unsafeCharacters("command")))
    }

    @Test func rejectsCaseInsensitiveDuplicateParameters() throws {
        let url = try #require(URL(string: "\(scheme)://run?command=true&Command=false&cwd=/tmp"))
        #expect(
            CmuxRunURLRequest.parse(url, supportedSchemes: [scheme])
                == .failure(.duplicateParameter("Command"))
        )
    }

    @Test func rejectsUnknownAuthorityExpandingParameters() throws {
        let result = parse([
            .init(name: "command", value: "true"),
            .init(name: "cwd", value: "/tmp"),
            .init(name: "env", value: "TOKEN=secret")
        ])
        #expect(result == .failure(.unsupportedParameter("env")))
    }

    @Test func byteLimitCannotBeBypassedWithCombiningScalars() {
        let oversized = "echo " + String(repeating: "\u{0301}", count: 4_000)
        #expect(oversized.count < CmuxRunURLRequest.maxCommandLength)
        #expect(oversized.utf8.count > CmuxRunURLRequest.maxCommandLength)

        #expect(parse([
            .init(name: "command", value: oversized),
            .init(name: "cwd", value: "/tmp")
        ]) == .failure(.valueTooLong(
            parameter: "command",
            maxLength: CmuxRunURLRequest.maxCommandLength
        )))
    }

    @Test func rejectsMissingCommandAndDirectory() {
        #expect(parse([.init(name: "cwd", value: "/tmp")]) == .failure(.missingParameter("command")))
        #expect(parse([.init(name: "command", value: "true")]) == .failure(.missingParameter("cwd")))
    }

    @Test func rejectsHiddenDirectoryCharacters() {
        #expect(parse([
            .init(name: "command", value: "true"),
            .init(name: "cwd", value: "/tmp/safe\u{202E}hidden")
        ]) == .failure(.unsafeCharacters("cwd")))
    }

    @Test func rejectsInvalidPlacementDirectionAndIdentifiers() {
        let workspaceId = UUID().uuidString
        let paneId = UUID().uuidString
        let base = [
            URLQueryItem(name: "command", value: "true"),
            URLQueryItem(name: "cwd", value: "/tmp")
        ]

        #expect(parse(base + [
            .init(name: "placement", value: "window")
        ]) == .failure(.invalidPlacement("placement")))
        #expect(parse(base + [
            .init(name: "placement", value: "pane"),
            .init(name: "workspace", value: workspaceId),
            .init(name: "pane", value: paneId),
            .init(name: "direction", value: "diagonal")
        ]) == .failure(.invalidDirection("direction")))
        #expect(parse(base + [
            .init(name: "placement", value: "surface"),
            .init(name: "workspace", value: "not-a-uuid"),
            .init(name: "pane", value: paneId)
        ]) == .failure(.invalidIdentifier("workspace")))
    }

    @Test func rejectsAmbiguousOrIncompletePlacementTargets() {
        let workspaceId = UUID().uuidString
        let paneId = UUID().uuidString
        let surfaceId = UUID().uuidString
        let base = [
            URLQueryItem(name: "command", value: "true"),
            URLQueryItem(name: "cwd", value: "/tmp")
        ]

        #expect(parse(base + [
            .init(name: "placement", value: "workspace"),
            .init(name: "workspace", value: workspaceId)
        ]) == .failure(.invalidTargetCombination))
        #expect(parse(base + [
            .init(name: "placement", value: "surface"),
            .init(name: "workspace", value: workspaceId),
            .init(name: "pane", value: paneId),
            .init(name: "surface", value: surfaceId)
        ]) == .failure(.invalidTargetCombination))
        #expect(parse(base + [
            .init(name: "placement", value: "pane"),
            .init(name: "workspace", value: workspaceId),
            .init(name: "pane", value: paneId)
        ]) == .failure(.missingParameter("direction")))
        #expect(parse(base + [
            .init(name: "placement", value: "surface"),
            .init(name: "workspace", value: workspaceId),
            .init(name: "pane", value: paneId),
            .init(name: "direction", value: "right")
        ]) == .failure(.invalidTargetCombination))
    }

    @Test func rejectsURLAuthorityAndPathAmbiguity() throws {
        for rawURL in [
            "\(scheme)://user@run?command=true&cwd=/tmp",
            "\(scheme)://run/extra?command=true&cwd=/tmp",
            "\(scheme)://run?command=true&cwd=/tmp#fragment"
        ] {
            let url = try #require(URL(string: rawURL))
            #expect(
                CmuxRunURLRequest.parse(url, supportedSchemes: [scheme])
                    == .failure(.unsupportedURLShape)
            )
        }
    }

    @Test func ignoresOtherSchemesAndRoutes() throws {
        let otherScheme = try #require(URL(string: "https://run?command=true&cwd=/tmp"))
        let otherRoute = try #require(URL(string: "\(scheme)://prompt?command=true&cwd=/tmp"))
        #expect(CmuxRunURLRequest.parse(otherScheme, supportedSchemes: [scheme]) == .success(nil))
        #expect(CmuxRunURLRequest.parse(otherRoute, supportedSchemes: [scheme]) == .success(nil))
    }

    @Test func rejectsPathStyleRunRouteInsteadOfSilentlyIgnoringIt() throws {
        let url = try #require(URL(string: "\(scheme):/run?command=true&cwd=/tmp"))

        #expect(
            CmuxRunURLRequest.parse(url, supportedSchemes: [scheme])
                == .failure(.unsupportedURLShape)
        )
    }

    @Test @MainActor func classifiesEachMalformedExternalURLAsOneIntent() throws {
        let urls = try [
            #require(URL(string: "\(scheme)://run?cwd=/tmp")),
            #require(URL(string: "\(scheme)://ssh?title=Missing")),
            #require(URL(string: "\(scheme)://workspace/not-a-uuid")),
            #require(URL(string: "\(scheme)://prompt")),
            #require(URL(string: "\(scheme)://unsupported"))
        ]

        let counts = AppDelegate.cmuxExternalURLIntentCounts(
            in: urls,
            supportedSchemes: [scheme]
        )

        #expect(counts.run == 1)
        #expect(counts.ssh == 1)
        #expect(counts.navigation == 1)
        #expect(counts.text == 1)
        #expect(counts.total == 4)
    }

    @Test @MainActor func mixedExternalURLsTakePriorityOverRunBusyRejection() {
        let mixedCounts = AppDelegate.CmuxExternalURLIntentCounts(
            run: 1,
            ssh: 1,
            navigation: 0,
            text: 0
        )
        let runCounts = AppDelegate.CmuxExternalURLIntentCounts(
            run: 1,
            ssh: 0,
            navigation: 0,
            text: 0
        )

        #expect(AppDelegate.cmuxExternalURLAdmission(
            intentCounts: mixedCounts,
            isRunBusy: true
        ) == .multipleRunLinks)
        #expect(AppDelegate.cmuxExternalURLAdmission(
            intentCounts: runCounts,
            isRunBusy: true
        ) == .busy)
    }

    @Test @MainActor func activeRunApprovalBlocksOtherExecutableLinkTypes() {
        let sshCounts = AppDelegate.CmuxExternalURLIntentCounts(
            run: 0,
            ssh: 1,
            navigation: 0,
            text: 0
        )
        let textCounts = AppDelegate.CmuxExternalURLIntentCounts(
            run: 0,
            ssh: 0,
            navigation: 0,
            text: 1
        )
        let navigationCounts = AppDelegate.CmuxExternalURLIntentCounts(
            run: 0,
            ssh: 0,
            navigation: 1,
            text: 0
        )

        #expect(AppDelegate.cmuxExternalURLAdmission(
            intentCounts: sshCounts,
            isRunBusy: true
        ) == .busy)
        #expect(AppDelegate.cmuxExternalURLAdmission(
            intentCounts: textCounts,
            isRunBusy: true
        ) == .busy)
        #expect(AppDelegate.cmuxExternalURLAdmission(
            intentCounts: navigationCounts,
            isRunBusy: true
        ) == .route)
    }

    @Test @MainActor func nonRunURLBatchesKeepTheirExistingAllOrNothingAdmission() {
        let sshCounts = AppDelegate.CmuxExternalURLIntentCounts(
            run: 0,
            ssh: 2,
            navigation: 0,
            text: 0
        )
        let mixedCounts = AppDelegate.CmuxExternalURLIntentCounts(
            run: 0,
            ssh: 1,
            navigation: 0,
            text: 1
        )
        let singleSSHCounts = AppDelegate.CmuxExternalURLIntentCounts(
            run: 0,
            ssh: 1,
            navigation: 0,
            text: 0
        )

        #expect(AppDelegate.cmuxExternalURLAdmission(
            intentCounts: sshCounts,
            isRunBusy: false
        ) == .multipleSSHLinks)
        #expect(AppDelegate.cmuxExternalURLAdmission(
            intentCounts: mixedCounts,
            isRunBusy: false
        ) == .multipleNonRunLinks)
        #expect(AppDelegate.cmuxExternalURLAdmission(
            intentCounts: singleSSHCounts,
            isRunBusy: false
        ) == .route)
    }

    @Test func resolvesAndCanonicalizesExistingDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(
            CmuxRunWorkingDirectoryResolver().resolve(link.path).map(\.path)
                == .success(real.path)
        )
        #expect(
            await CmuxRunWorkingDirectoryResolver().resolveWithDeadline(link.path).map(\.path)
                == .success(real.path)
        )
    }

    @Test func rejectsRelativeMissingAndFileWorkingDirectories() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(
            CmuxRunWorkingDirectoryResolver().resolve("relative/path")
                == .failure(.workingDirectoryMustBeAbsolute)
        )
        #expect(
            CmuxRunWorkingDirectoryResolver().resolve("/tmp/cmux-missing-\(UUID().uuidString)")
                == .failure(.workingDirectoryNotFound)
        )
        #expect(
            CmuxRunWorkingDirectoryResolver().resolve(file.path)
                == .failure(.workingDirectoryNotFound)
        )
    }

    @Test func rejectsWorkingDirectoriesChangedByWhitespaceTrimming() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trailingSpace = root.appendingPathComponent("approved-target ", isDirectory: true)
        try FileManager.default.createDirectory(at: trailingSpace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(
            CmuxRunWorkingDirectoryResolver().resolve(trailingSpace.path)
                == .failure(.workingDirectoryContainsSurroundingWhitespace)
        )
    }

    @Test func rejectsSafeLookingSymlinksToDirectoriesWithHiddenCharacters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let hiddenTarget = root.appendingPathComponent("hidden\ncanonical", isDirectory: true)
        let safeLink = root.appendingPathComponent("safe-link", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: safeLink, withDestinationURL: hiddenTarget)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = CmuxRunWorkingDirectoryResolver()
        if case .success = resolver.resolve(safeLink.path) {
            Issue.record("Canonical working directories must reject hidden characters")
        }
        #expect(
            await resolver.resolveWithDeadline(safeLink.path)
                == .failure(.workingDirectoryContainsUnsafeCharacters)
        )
    }

    @Test func resolverPermitAdmitsRetryOnlyAfterRecordedProcessTermination() async {
        let limiter = CmuxRunWorkingDirectoryProcessLimiter()

        let firstAcquisition = await limiter.acquire()
        let overlappingAcquisition = await limiter.acquire()
        guard case .success(let permit) = firstAcquisition else {
            Issue.record("Expected the first verifier permit to be acquired")
            return
        }
        #expect(overlappingAcquisition == .failure(.busy))

        await limiter.markUnavailable(permit)
        #expect(await limiter.acquire() == .failure(.workingDirectoryVerifierUnavailable))

        await limiter.recordTermination(permit)
        let acquisitionAfterTermination = await limiter.acquire()
        guard case .success(let retryPermit) = acquisitionAfterTermination else {
            Issue.record("Expected termination to recover the verifier permit")
            return
        }
        await limiter.recordTermination(retryPermit)
    }

    @Test func resolutionDeadlineDoesNotWaitForProcessTermination() async {
        let gate = CmuxRunWorkingDirectoryProcessGate()
        let waiter = Task {
            await gate.value()
        }

        #expect(await gate.requestTimeout())
        switch await waiter.value {
        case .timedOut:
            break
        case .completed:
            Issue.record("Expected the deadline gate to return its timeout outcome")
        }
    }

    @Test func concurrentResolutionDoesNotSpawnASecondProcess() async throws {
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let resolver = CmuxRunWorkingDirectoryResolver { _ in
            startedContinuation.yield()
            return CmuxRunWorkingDirectoryCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
                arguments: []
            )
        }
        let first = Task {
            await resolver.resolveWithDeadline("/tmp", timeout: .seconds(1))
        }
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()

        #expect(
            await resolver.resolveWithDeadline("/tmp", timeout: .zero)
                == .failure(.busy)
        )

        first.cancel()
        #expect(await first.value == .failure(.workingDirectoryResolutionTimedOut))
        startedContinuation.finish()
    }

    @Test func deadlineResolverRequiresIdentityFromTheBoundedVerifier() async {
        let resolver = CmuxRunWorkingDirectoryResolver { _ in
            CmuxRunWorkingDirectoryCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '/tmp\\n'"]
            )
        }

        #expect(
            await resolver.resolveWithDeadline("/tmp")
                == .failure(.workingDirectoryNotFound)
        )
    }

    @Test func canonicalVerifierKeepsBlockingOperationsInTheTrackedProcess() {
        let command = CmuxRunWorkingDirectoryResolver.canonicalDirectoryCommand(for: "/tmp")
        let script = command.arguments.joined(separator: " ")

        #expect(!script.contains("$("))
        #expect(script.contains("pwd -P"))
        #expect(script.contains("exec /usr/bin/stat"))
    }

    private func parsed(_ queryItems: [URLQueryItem]) throws -> CmuxRunURLRequest {
        switch parse(queryItems) {
        case .success(let request):
            return try #require(request)
        case .failure(let error):
            throw error
        }
    }

    private func parse(
        _ queryItems: [URLQueryItem]
    ) -> Result<CmuxRunURLRequest?, CmuxRunURLParseError> {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "run"
        components.queryItems = queryItems
        guard let url = components.url else {
            return .failure(.unsupportedURLShape)
        }
        return CmuxRunURLRequest.parse(url, supportedSchemes: [scheme])
    }

    private func runInitialTerminalCommand(
        _ command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func decodedGuardedScript(from command: String) -> String? {
        guard let encodedScript = command.split(separator: " ").last,
              let data = Data(base64Encoded: encodedScript) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
