import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit tests for the Inline VS Code `serve-web` configuration pipeline:
/// the presence-aware cmux.json reader, the config/env/default resolver, and
/// the `serve-web` argument builder. These cover the behavior exposed by
/// issue #6645 (settings for inline VS Code serve-web launches).
@Suite("InlineVSCodeServeWebOptions")
struct InlineVSCodeServeWebOptionsTests {
    private static let home = "/Users/tester"
    private typealias Resolver = InlineVSCodeServeWebOptionsResolver

    private func makeData(_ json: String) -> Data { Data(json.utf8) }

    private func readValues(_ json: String) -> InlineVSCodeConfigFileValues {
        InlineVSCodeServeWebConfigurationLoader(
            configFileURL: URL(fileURLWithPath: "/dev/null"),
            dataReader: { _ in self.makeData(json) }
        ).readFileValues()
    }

    private func resolve(
        file: InlineVSCodeConfigFileValues,
        environment: [String: String] = [:]
    ) -> InlineVSCodeServeWebOptions {
        Resolver(environment: environment, homeDirectoryPath: Self.home).resolve(file: file)
    }

    // MARK: - Reader

    @Test func readerReturnsEmptyWhenBlockAbsent() {
        #expect(readValues("{}") == .empty)
        #expect(readValues("{ \"terminal\": { \"copyOnSelect\": true } }") == .empty)
    }

    @Test func readerReturnsEmptyWhenFileMissingOrUnreadable() {
        let values = InlineVSCodeServeWebConfigurationLoader(
            configFileURL: URL(fileURLWithPath: "/dev/null"),
            dataReader: { _ in nil }
        ).readFileValues()
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

    @Test func readerToleratesPerFieldTypeErrors() {
        // A bad `port` must not discard a valid `persistServeWebState` privacy choice.
        let values = readValues("{ \"inlineVSCode\": { \"port\": \"oops\", \"persistServeWebState\": false } }")
        #expect(values.port == nil)
        #expect(values.persistServeWebState == false)
    }

    @Test func readerRejectsBooleanForPortAndNumberForPersist() {
        let values = readValues("{ \"inlineVSCode\": { \"port\": true, \"persistServeWebState\": 1 } }")
        #expect(values.port == nil) // a JSON boolean is not a valid port
        #expect(values.persistServeWebState == nil) // a numeric 1 is not a valid boolean
    }

    // MARK: - Resolver precedence

    @Test func resolverUsesDefaultsWhenNothingConfigured() {
        let options = resolve(file: .empty)
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
            Resolver.portEnvironmentKey: "2222",
            Resolver.serverDataDirEnvironmentKey: "/from/env",
            Resolver.persistStateEnvironmentKey: "true",
            Resolver.extraArgsEnvironmentKey: "--env",
        ]
        let options = resolve(file: file, environment: env)
        #expect(options.port == 1111)
        #expect(options.serverDataDir == "/from/file")
        #expect(options.persistServeWebState == false)
        #expect(options.extraArgs == ["--file"])
    }

    @Test func resolverFallsBackToEnvironmentWhenFileAbsent() {
        let env = [
            Resolver.portEnvironmentKey: "3333",
            Resolver.serverDataDirEnvironmentKey: "~/envdir",
            Resolver.persistStateEnvironmentKey: "0",
            Resolver.extraArgsEnvironmentKey: "--x  --y\t--z",
        ]
        let options = resolve(file: .empty, environment: env)
        #expect(options.port == 3333)
        #expect(options.serverDataDir == "/Users/tester/envdir")
        #expect(options.persistServeWebState == false)
        #expect(options.extraArgs == ["--x", "--y", "--z"])
    }

    @Test func resolverRejectsOutOfRangePortAndFallsBackToZero() {
        let high = resolve(file: InlineVSCodeConfigFileValues(port: 70000, serverDataDir: nil, persistServeWebState: nil, extraArgs: nil))
        #expect(high.port == 0)
        let negative = resolve(file: InlineVSCodeConfigFileValues(port: -1, serverDataDir: nil, persistServeWebState: nil, extraArgs: nil))
        #expect(negative.port == 0)
    }

    @Test func resolverParsesBooleanEnvironmentVariants() {
        for raw in ["1", "true", "TRUE", "yes", "on"] {
            let options = resolve(file: .empty, environment: [Resolver.persistStateEnvironmentKey: raw])
            #expect(options.persistServeWebState == true, "expected true for \(raw)")
        }
        for raw in ["0", "false", "no", "off"] {
            let options = resolve(file: .empty, environment: [Resolver.persistStateEnvironmentKey: raw])
            #expect(options.persistServeWebState == false, "expected false for \(raw)")
        }
        // Unrecognized value falls back to the default (true).
        let fallback = resolve(file: .empty, environment: [Resolver.persistStateEnvironmentKey: "maybe"])
        #expect(fallback.persistServeWebState == true)
    }

    @Test func resolverDropsBlankExtraArgsAndTrims() {
        let file = InlineVSCodeConfigFileValues(
            port: nil,
            serverDataDir: nil,
            persistServeWebState: nil,
            extraArgs: ["  --keep  ", "", "   ", "--also"]
        )
        #expect(resolve(file: file).extraArgs == ["--keep", "--also"])
    }

    @Test func resolverTrimsBlankServerDataDirToNil() {
        let file = InlineVSCodeConfigFileValues(port: nil, serverDataDir: "   ", persistServeWebState: nil, extraArgs: nil)
        #expect(resolve(file: file).serverDataDir == nil)
    }

    @Test func resolverExpandsTildeInServerDataDir() {
        let file = InlineVSCodeConfigFileValues(port: nil, serverDataDir: "~/Library/x", persistServeWebState: nil, extraArgs: nil)
        #expect(resolve(file: file).serverDataDir == "/Users/tester/Library/x")
    }

    // MARK: - Tilde expansion

    @Test func tildeExpansion() {
        #expect(Resolver.expandingTilde("~", homeDirectoryPath: "/Users/me") == "/Users/me")
        #expect(Resolver.expandingTilde("~/x/y", homeDirectoryPath: "/Users/me") == "/Users/me/x/y")
        #expect(Resolver.expandingTilde("~/x", homeDirectoryPath: "/Users/me/") == "/Users/me/x")
        #expect(Resolver.expandingTilde("/abs/path", homeDirectoryPath: "/Users/me") == "/abs/path")
        #expect(Resolver.expandingTilde("relative/~tilde", homeDirectoryPath: "/Users/me") == "relative/~tilde")
    }

    // MARK: - Argument builder

    private func args(_ options: InlineVSCodeServeWebOptions, ephemeral: String = "/tmp/ephemeral") -> [String] {
        options.serveWebArguments(
            argumentsPrefix: ["serve-web"],
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

    @Test func nonPersistentAlwaysUsesEphemeralDirNeverThePersistentDefault() {
        let result = args(InlineVSCodeServeWebOptions(port: 0, serverDataDir: nil, persistServeWebState: false, extraArgs: []))
        let index = try! #require(result.firstIndex(of: "--server-data-dir"))
        #expect(result[index + 1] == "/tmp/ephemeral")
    }

    @Test func ephemeralDirsAreUniquePerLaunchAndDoNotWipeSiblings() {
        let loader = InlineVSCodeServeWebConfigurationLoader()
        let first = loader.makeEphemeralServerDataDir()
        let second = loader.makeEphemeralServerDataDir()
        defer {
            try? FileManager.default.removeItem(atPath: first)
            try? FileManager.default.removeItem(atPath: second)
        }
        #expect(first != second)
        #expect(first.contains("cmux-vscode-serve-web-ephemeral"))
        // Creating a new ephemeral dir must not remove an existing one — another
        // cmux instance's running serve-web may be using it.
        #expect(FileManager.default.fileExists(atPath: first))
    }

    @Test func explicitDirWinsOverNonPersistentEphemeral() {
        let options = InlineVSCodeServeWebOptions(port: 0, serverDataDir: "/explicit", persistServeWebState: false, extraArgs: [])
        #expect(options.effectiveServerDataDir(makeEphemeralServerDataDir: { "/tmp/ephemeral" }) == "/explicit")
    }

    @Test func persistentWithoutExplicitDirOmitsServerDataDir() {
        let options = InlineVSCodeServeWebOptions(port: 0, serverDataDir: nil, persistServeWebState: true, extraArgs: [])
        #expect(options.effectiveServerDataDir(makeEphemeralServerDataDir: { "/tmp/ephemeral" }) == nil)
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
        let dirIndex = try! #require(result.firstIndex(of: "--server-data-dir"))
        let extraIndex = try! #require(result.firstIndex(of: "--verbose"))
        #expect(dirIndex < extraIndex)
        #expect(result.contains("--connection-token-file"))
    }

    // MARK: - Reserved-flag sanitization (loopback/token invariants)

    @Test func sanitizeStripsReservedSpaceSeparatedFlagsAndValues() {
        let cleaned = InlineVSCodeServeWebOptions.sanitizedExtraArgs([
            "--host", "0.0.0.0",
            "--keep1",
            "--port", "9999",
            "--connection-token-file", "/evil",
            "--server-data-dir", "/evil-dir",
            "--keep2",
        ])
        #expect(cleaned == ["--keep1", "--keep2"])
    }

    @Test func sanitizeStripsReservedEqualsFormAndTokenDisablingFlag() {
        let cleaned = InlineVSCodeServeWebOptions.sanitizedExtraArgs([
            "--host=0.0.0.0",
            "--without-connection-token",
            "--accept-server-license-terms",
            "--port=80",
            "--good=value",
        ])
        #expect(cleaned == ["--good=value"])
    }

    @Test func argumentsCannotBeOverriddenByMaliciousExtraArgs() {
        let options = InlineVSCodeServeWebOptions(
            port: 1234,
            serverDataDir: nil,
            persistServeWebState: true,
            extraArgs: ["--host", "0.0.0.0", "--without-connection-token"]
        )
        let result = args(options)
        // The only host is the managed loopback; the token flag survives; no override leaked in.
        #expect(result.filter { $0 == "--host" }.count == 1)
        let hostIndex = try! #require(result.firstIndex(of: "--host"))
        #expect(result[hostIndex + 1] == "127.0.0.1")
        #expect(!result.contains("0.0.0.0"))
        #expect(!result.contains("--without-connection-token"))
        #expect(result.contains("--connection-token-file"))
    }
}
