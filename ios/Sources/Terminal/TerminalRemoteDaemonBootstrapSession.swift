import Foundation

protocol TerminalRemoteDaemonCommandRunner: Sendable {
    func run(_ command: String, standardInput: Data?) async throws -> String
}

extension TerminalRemoteDaemonCommandRunner {
    func run(_ command: String) async throws -> String {
        try await run(command, standardInput: nil)
    }
}

struct TerminalRemoteDaemonLaunchConfig: Equatable, Sendable {
    let remoteBinaryPath: String
    let launchCommand: String
    let platform: RemotePlatform
}

struct TerminalRemoteDaemonBootstrapSession: Sendable {
    private let commandRunner: any TerminalRemoteDaemonCommandRunner
    private let bundleLocator: TerminalRemoteDaemonBootstrap.BundleLocator
    private let version: String
    private let remoteRoot: String

    init(
        commandRunner: any TerminalRemoteDaemonCommandRunner,
        bundleLocator: TerminalRemoteDaemonBootstrap.BundleLocator = .init(),
        version: String = "dev",
        remoteRoot: String = "~/.cmux/bin/cmuxd-remote"
    ) {
        self.commandRunner = commandRunner
        self.bundleLocator = bundleLocator
        self.version = version
        self.remoteRoot = remoteRoot
    }

    func prepareDaemon() async throws -> TerminalRemoteDaemonLaunchConfig {
        let probeOutput = try await commandRunner.run(Self.platformProbeCommand)
        let platform = try TerminalRemoteDaemonBootstrap.parsePlatform(stdout: probeOutput)
        let binaryURL = try bundleLocator.binaryURL(
            goOS: platform.goOS,
            goArch: platform.goArch,
            version: version
        )
        let binaryData = try Data(contentsOf: binaryURL)
        let remoteBinaryPath = Self.remoteBinaryPath(
            remoteRoot: remoteRoot,
            platform: platform,
            version: version
        )
        let installScript = try TerminalRemoteDaemonBootstrap.installScript(remotePath: remoteBinaryPath)
        let encodedBinary = binaryData.base64EncodedData()

        _ = try await commandRunner.run(
            "sh -lc \(Self.shellSingleQuoted(installScript))",
            standardInput: encodedBinary
        )

        return TerminalRemoteDaemonLaunchConfig(
            remoteBinaryPath: remoteBinaryPath,
            launchCommand: "\(remoteBinaryPath) serve --stdio",
            platform: platform
        )
    }

    private static let platformProbeCommand = "uname -s\nuname -m"

    private static func remoteBinaryPath(
        remoteRoot: String,
        platform: RemotePlatform,
        version: String
    ) -> String {
        "\(remoteRoot)/\(version)/\(platform.resourceDirectoryName)/cmuxd-remote"
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
