import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit tests for the Inline VS Code `serve-web` configuration pipeline:
/// the presence-aware cmux.json reader, the config/env/default resolver, and
/// the pure `serve-web` argument builder. These cover the behavior exposed by
/// issue #6645 (settings for inline VS Code serve-web launches).
@Suite("InlineVSCodeServeWebOptions")
struct InlineVSCodeServeWebOptionsTests {
    private static let home = "/Users/tester"

    private func makeData(_ json: String) -> Data { Data(json.utf8) }

    private func readValues(_ json: String) -> InlineVSCodeConfigFileValues {
        InlineVSCodeServeWebSupport.readFileValues(
            configFileURL: URL(fileURLWithPath: "/dev/null"),
            dataReader: { _ in self.makeData(json) }
        )
    }

    // MARK: - Reader

    @Test func readerReturnsEmptyWhenBlockAbsent() {
        #expect(readValues("{}") == .empty)
        #expect(readValues("{ \"terminal\": { \"copyOnSelect\": true } }") == .empty)
    }

    @Test func readerReturnsEmptyWhenFileMissingOrUnreadable() {
        let values = InlineVSCodeServeWebSupport.readFileValues(
            configFileURL: URL(fileURLWithPath: "/dev/null"),
            dataReader: { _ in nil }
        )
        #expect(values == .empty)
    }

    @Test func readerDecodesAllFields() {
        let values = readValues("""
        {
          "inlineVSCode": {
            "persistServeWebState": false,
            "port": 8123,
            "serverDataDir": "~/vscode",
            "extraArgs": ["--a", "--b"]
          }
        }
        """)
        #expect(values.persistServeWebState == false)
        #expect(values.port == 8123)
        #expect(values.serverDataDir == "~/vscode")
        #expect(values.extraArgs == ["--a", "--b"])
    }

    @Test func readerIsPresenceAwareForPartialBlock() {
        let values = readValues("{ \"inlineVSCode\": { \"port\": 9000 } }")
        #expect(values.port == 9000)
        #expect(values.persistServeWebState == nil)
        #expect(values.serverDataDir == nil)
        #expect(values.extraArgs == nil)
    }

    @Test func readerToleratesJSONCCommentsAndTrailingCommas() {
        let values = readValues("""
        {
          // inline VS Code options
          "inlineVSCode": {
            "port": 7000, /* pinned */
          },
        }
        """)
        #expect(values.port == 7000)
    }

    @Test func readerReturnsEmptyOnTypeMismatch() {
        // A string where a number is expected fails decoding -> fall back to empty.
        #expect(readValues("{ \"inlineVSCode\": { \"port\": \"oops\" } }") == .empty)
    }

    // MARK: - Resolver precedence

    @Test func resolverUsesDefaultsWhenNothingConfigured() {
        let options = InlineVSCodeServeWebOptionsResolver.resolve(
            file: .empty,
            environment: [:],
            homeDirectoryPath: Self.home
        )
        #expect(options == .default)
        #expect(options.port == 0)
        #expect(options.serverDataDir == nil)
        #expect(options.persistServeWebState == true)
        #expect(options.extraArgs.isEmpty)
    }

    @Test func resolverFileOverridesEnvironment() {
        let file = InlineVSCodeConfigFileValues(
            port: 1111,
            serverDataDir: "/from/file",
            persistServeWebState: false,
            extraArgs: ["--file"]
        )
        let env = [
            InlineVSCodeServeWebOptionsResolver.EnvironmentKey.port: "2222",
            InlineVSCodeServeWebOptionsResolver.EnvironmentKey.serverDataDir: "/from/env",
            InlineVSCodeServeWebOptionsResolver.EnvironmentKey.persistState: "true",
            InlineVSCodeServeWebOptionsResolver.EnvironmentKey.extraArgs: "--env",
        ]
        let options = InlineVSCodeServeWebOptionsResolver.resolve(
            file: file,
            environment: env,
            homeDirectoryPath: Self.home
        )
        #expect(options.port == 1111)
        #expect(options.serverDataDir == "/from/file")
        #expect(options.persistServeWebState == false)
        #expect(options.extraArgs == ["--file"])
    }

    @Test func resolverFallsBackToEnvironmentWhenFileAbsent() {
        let env = [
            InlineVSCodeServeWebOptionsResolver.EnvironmentKey.port: "3333",
            InlineVSCodeServeWebOptionsResolver.EnvironmentKey.serverDataDir: "~/envdir",
            InlineVSCodeServeWebOptionsResolver.EnvironmentKey.persistState: "0",
            InlineVSCodeServeWebOptionsResolver.EnvironmentKey.extraArgs: "--x  --y\t--z",
        ]
        let options = InlineVSCodeServeWebOptionsResolver.resolve(
            file: .empty,
            environment: env,
            homeDirectoryPath: Self.home
        )
        #expect(options.port == 3333)
        #expect(options.serverDataDir == "/Users/tester/envdir")
        #expect(options.persistServeWebState == false)
        #expect(options.extraArgs == ["--x", "--y", "--z"])
    }

    @Test func resolverRejectsOutOfRangePortAndFallsBackToZero() {
        let optionsHigh = InlineVSCodeServeWebOptionsResolver.resolve(
            file: InlineVSCodeConfigFileValues(port: 70000, serverDataDir: nil, persistServeWebState: nil, extraArgs: nil),
            environment: [:],
            homeDirectoryPath: Self.home
        )
        #expect(optionsHigh.port == 0)

        let optionsNegative = InlineVSCodeServeWebOptionsResolver.resolve(
            file: InlineVSCodeConfigFileValues(port: -1, serverDataDir: nil, persistServeWebState: nil, extraArgs: nil),
            environment: [:],
            homeDirectoryPath: Self.home
        )
        #expect(optionsNegative.port == 0)
    }

    @Test func resolverParsesBooleanEnvironmentVariants() {
        for raw in ["1", "true", "TRUE", "yes", "on"] {
            let options = InlineVSCodeServeWebOptionsResolver.resolve(
                file: .empty,
                environment: [InlineVSCodeServeWebOptionsResolver.EnvironmentKey.persistState: raw],
                homeDirectoryPath: Self.home
            )
            #expect(options.persistServeWebState == true, "expected true for \(raw)")
        }
        for raw in ["0", "false", "no", "off"] {
            let options = InlineVSCodeServeWebOptionsResolver.resolve(
                file: .empty,
                environment: [InlineVSCodeServeWebOptionsResolver.EnvironmentKey.persistState: raw],
                homeDirectoryPath: Self.home
            )
            #expect(options.persistServeWebState == false, "expected false for \(raw)")
        }
        // Unrecognized value falls back to the default (true).
        let fallback = InlineVSCodeServeWebOptionsResolver.resolve(
            file: .empty,
            environment: [InlineVSCodeServeWebOptionsResolver.EnvironmentKey.persistState: "maybe"],
            homeDirectoryPath: Self.home
        )
        #expect(fallback.persistServeWebState == true)
    }

    @Test func resolverDropsBlankExtraArgsAndTrims() {
        let file = InlineVSCodeConfigFileValues(
            port: nil,
            serverDataDir: nil,
            persistServeWebState: nil,
            extraArgs: ["  --keep  ", "", "   ", "--also"]
        )
        let options = InlineVSCodeServeWebOptionsResolver.resolve(
            file: file,
            environment: [:],
            homeDirectoryPath: Self.home
        )
        #expect(options.extraArgs == ["--keep", "--also"])
    }

    @Test func resolverTrimsBlankServerDataDirToNil() {
        let file = InlineVSCodeConfigFileValues(
            port: nil,
            serverDataDir: "   ",
            persistServeWebState: nil,
            extraArgs: nil
        )
        let options = InlineVSCodeServeWebOptionsResolver.resolve(
            file: file,
            environment: [:],
            homeDirectoryPath: Self.home
        )
        #expect(options.serverDataDir == nil)
    }

    // MARK: - Tilde expansion

    @Test func tildeExpansion() {
        #expect(InlineVSCodeServeWebOptionsResolver.expandingTilde("~", homeDirectoryPath: "/Users/me") == "/Users/me")
        #expect(InlineVSCodeServeWebOptionsResolver.expandingTilde("~/x/y", homeDirectoryPath: "/Users/me") == "/Users/me/x/y")
        #expect(InlineVSCodeServeWebOptionsResolver.expandingTilde("~/x", homeDirectoryPath: "/Users/me/") == "/Users/me/x")
        #expect(InlineVSCodeServeWebOptionsResolver.expandingTilde("/abs/path", homeDirectoryPath: "/Users/me") == "/abs/path")
        #expect(InlineVSCodeServeWebOptionsResolver.expandingTilde("relative/~tilde", homeDirectoryPath: "/Users/me") == "relative/~tilde")
    }

    // MARK: - Argument builder

    private func args(_ options: InlineVSCodeServeWebOptions, ephemeral: String? = "/tmp/ephemeral") -> [String] {
        InlineVSCodeServeWebSupport.serveWebArguments(
            argumentsPrefix: ["serve-web"],
            options: options,
            connectionTokenFilePath: "/tmp/token",
            makeEphemeralServerDataDir: { ephemeral }
        )
    }

    @Test func argumentsForDefaultOptionsMatchHistoricalBehavior() {
        let result = args(.default)
        #expect(result == [
            "serve-web",
            "--accept-server-license-terms",
            "--host", "127.0.0.1",
            "--port", "0",
            "--connection-token-file", "/tmp/token",
        ])
        // No --server-data-dir and no extra args by default.
        #expect(!result.contains("--server-data-dir"))
    }

    @Test func argumentsUsePinnedPort() {
        let result = args(InlineVSCodeServeWebOptions(port: 8123, serverDataDir: nil, persistServeWebState: true, extraArgs: []))
        let portIndex = try! #require(result.firstIndex(of: "--port"))
        #expect(result[portIndex + 1] == "8123")
    }

    @Test func argumentsIncludeExplicitServerDataDir() {
        let result = args(InlineVSCodeServeWebOptions(port: 0, serverDataDir: "/data/dir", persistServeWebState: true, extraArgs: []))
        let index = try! #require(result.firstIndex(of: "--server-data-dir"))
        #expect(result[index + 1] == "/data/dir")
    }

    @Test func argumentsUseEphemeralDirWhenNonPersistentWithoutExplicitDir() {
        let result = args(InlineVSCodeServeWebOptions(port: 0, serverDataDir: nil, persistServeWebState: false, extraArgs: []))
        let index = try! #require(result.firstIndex(of: "--server-data-dir"))
        #expect(result[index + 1] == "/tmp/ephemeral")
    }

    @Test func explicitDirWinsOverNonPersistentEphemeral() {
        let options = InlineVSCodeServeWebOptions(port: 0, serverDataDir: "/explicit", persistServeWebState: false, extraArgs: [])
        #expect(InlineVSCodeServeWebSupport.effectiveServerDataDir(options: options, makeEphemeralServerDataDir: { "/tmp/ephemeral" }) == "/explicit")
    }

    @Test func persistentWithoutExplicitDirOmitsServerDataDir() {
        let options = InlineVSCodeServeWebOptions(port: 0, serverDataDir: nil, persistServeWebState: true, extraArgs: [])
        #expect(InlineVSCodeServeWebSupport.effectiveServerDataDir(options: options, makeEphemeralServerDataDir: { "/tmp/ephemeral" }) == nil)
    }

    @Test func ephemeralFailureFallsBackToOmittingFlag() {
        let result = args(
            InlineVSCodeServeWebOptions(port: 0, serverDataDir: nil, persistServeWebState: false, extraArgs: []),
            ephemeral: nil
        )
        #expect(!result.contains("--server-data-dir"))
    }

    @Test func extraArgsAreAppendedAfterManagedArguments() {
        let options = InlineVSCodeServeWebOptions(
            port: 5000,
            serverDataDir: "/data",
            persistServeWebState: true,
            extraArgs: ["--verbose", "--log", "debug"]
        )
        let result = args(options)
        #expect(Array(result.suffix(3)) == ["--verbose", "--log", "debug"])
        // server-data-dir comes before the extra args.
        let dirIndex = try! #require(result.firstIndex(of: "--server-data-dir"))
        let extraIndex = try! #require(result.firstIndex(of: "--verbose"))
        #expect(dirIndex < extraIndex)
        // The connection token is always present.
        #expect(result.contains("--connection-token-file"))
    }
}
