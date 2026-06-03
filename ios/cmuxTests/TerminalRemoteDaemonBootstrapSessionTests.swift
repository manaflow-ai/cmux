import XCTest
@testable import cmux_DEV

final class TerminalRemoteDaemonBootstrapSessionTests: XCTestCase {
    func testPrepareDaemonInstallsBundledBinaryForProbedPlatform() async throws {
        let fixtureRoot = try makeFixtureRoot(
            version: "dev",
            goOS: "linux",
            goArch: "amd64",
            binaryData: Data("ABC".utf8)
        )
        let runner = StubRemoteDaemonCommandRunner(
            responses: [
                "uname -s\nuname -m": "Linux\nx86_64\n",
                #"sh -lc 'set -eu"#: "",
            ]
        )
        let session = TerminalRemoteDaemonBootstrapSession(
            commandRunner: runner,
            bundleLocator: TerminalRemoteDaemonBootstrap.BundleLocator(resourceRoot: fixtureRoot),
            version: "dev"
        )

        let launchConfig = try await session.prepareDaemon()

        XCTAssertEqual(
            launchConfig.remoteBinaryPath,
            "~/.cmux/bin/cmuxd-remote/dev/linux-amd64/cmuxd-remote"
        )
        XCTAssertEqual(
            launchConfig.launchCommand,
            "~/.cmux/bin/cmuxd-remote/dev/linux-amd64/cmuxd-remote serve --stdio"
        )

        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands.first, "uname -s\nuname -m")

        let installCommand = try XCTUnwrap(commands.last)
        XCTAssertFalse(installCommand.contains("QUJD"))
        XCTAssertTrue(installCommand.contains("chmod 755"))
        XCTAssertTrue(installCommand.contains("~/.cmux/bin/cmuxd-remote/dev/linux-amd64/cmuxd-remote"))

        let standardInputs = await runner.recordedStandardInputs()
        XCTAssertEqual(standardInputs.last, Data("QUJD".utf8))
    }

    private func makeFixtureRoot(
        version: String,
        goOS: String,
        goArch: String,
        binaryData: Data
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let binaryDirectory = root
            .appendingPathComponent("cmuxd-remote", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let binaryURL = binaryDirectory.appendingPathComponent("cmuxd-remote", isDirectory: false)
        FileManager.default.createFile(atPath: binaryURL.path, contents: binaryData, attributes: nil)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}

private actor StubRemoteDaemonCommandRunner: TerminalRemoteDaemonCommandRunner {
    private let responses: [String: String]
    private var commands: [String] = []
    private var standardInputs: [Data?] = []

    init(responses: [String: String]) {
        self.responses = responses
    }

    func run(_ command: String, standardInput: Data?) async throws -> String {
        commands.append(command)
        standardInputs.append(standardInput)

        if let exact = responses[command] {
            return exact
        }

        if let match = responses.first(where: { command.hasPrefix($0.key) }) {
            return match.value
        }

        throw StubRemoteDaemonCommandRunnerError.missingResponse(command)
    }

    func recordedCommands() -> [String] {
        commands
    }

    func recordedStandardInputs() -> [Data?] {
        standardInputs
    }
}

private enum StubRemoteDaemonCommandRunnerError: Error {
    case missingResponse(String)
}
