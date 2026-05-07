import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RipgrepResolverTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RipgrepResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    func testResolvePrefersCustomPathWhenExecutable() throws {
        let custom = try makeExecutableStub(named: "rg-custom")
        let resolved = RipgrepResolver.resolve(
            customPath: custom.path,
            commonPaths: [],
            environment: [:]
        )
        XCTAssertEqual(resolved, custom.path)
    }

    func testResolveFallsThroughWhenCustomPathIsNotExecutable() throws {
        let fallback = try makeExecutableStub(named: "rg-fallback")
        let bogus = tempDirectory.appendingPathComponent("nonexistent-rg").path

        let resolved = RipgrepResolver.resolve(
            customPath: bogus,
            commonPaths: [fallback.path],
            environment: [:]
        )

        XCTAssertEqual(
            resolved,
            fallback.path,
            "A configured-but-missing custom path must fall back to common paths so Find still works"
        )
    }

    func testResolveUsesCommonPathsWhenNoCustomPathConfigured() throws {
        let nixStyle = try makeExecutableStub(
            named: "rg",
            inSubdirectory: "etc/profiles/per-user/example/bin"
        )

        let resolved = RipgrepResolver.resolve(
            customPath: nil,
            commonPaths: [nixStyle.path],
            environment: [:]
        )

        XCTAssertEqual(resolved, nixStyle.path)
    }

    func testResolveFallsBackToPathEnvironmentWhenCommonPathsMiss() throws {
        let pathDir = tempDirectory.appendingPathComponent("custom-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: pathDir, withIntermediateDirectories: true)
        let stub = try makeExecutableStub(named: "rg", in: pathDir)

        let resolved = RipgrepResolver.resolve(
            customPath: nil,
            commonPaths: [],
            environment: ["PATH": pathDir.path]
        )

        XCTAssertEqual(resolved, stub.path)
    }

    func testResolveReturnsNilWhenNothingMatches() {
        let resolved = RipgrepResolver.resolve(
            customPath: nil,
            commonPaths: [tempDirectory.appendingPathComponent("missing-rg").path],
            environment: ["PATH": tempDirectory.appendingPathComponent("missing-bin").path]
        )
        XCTAssertNil(resolved)
    }

    func testDefaultCommonPathsIncludesNixDarwinProfilePaths() {
        let paths = RipgrepResolver.defaultCommonPaths(userName: "alice")
        XCTAssertTrue(
            paths.contains("/etc/profiles/per-user/alice/bin/rg"),
            "Per-user nix-darwin profile path must be present (#3657)"
        )
        XCTAssertTrue(
            paths.contains("/run/current-system/sw/bin/rg"),
            "nix-darwin system path must be present (#3657)"
        )
        XCTAssertTrue(
            paths.contains("/nix/var/nix/profiles/default/bin/rg"),
            "Single-user Nix profile path must be present (#3657)"
        )
    }

    func testDefaultCommonPathsPreservesHomebrewPrecedenceBeforeNixPaths() {
        let paths = RipgrepResolver.defaultCommonPaths(userName: "alice")
        guard let homebrewIndex = paths.firstIndex(of: "/opt/homebrew/bin/rg"),
              let nixUserIndex = paths.firstIndex(of: "/etc/profiles/per-user/alice/bin/rg") else {
            XCTFail("Expected both Homebrew and nix-darwin paths in default list")
            return
        }
        XCTAssertLessThan(
            homebrewIndex,
            nixUserIndex,
            "Homebrew must keep precedence so existing users aren't silently switched to a nix rg"
        )
    }

    func testCustomRipgrepPathSettingTrimsWhitespaceAndIgnoresEmpty() {
        let suiteName = "RipgrepResolverTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("   ", forKey: RipgrepIntegrationSettings.customRipgrepPathKey)
        XCTAssertNil(RipgrepIntegrationSettings.customRipgrepPath(defaults: defaults))

        defaults.set("  /opt/homebrew/bin/rg  ", forKey: RipgrepIntegrationSettings.customRipgrepPathKey)
        XCTAssertEqual(
            RipgrepIntegrationSettings.customRipgrepPath(defaults: defaults),
            "/opt/homebrew/bin/rg"
        )

        defaults.removeObject(forKey: RipgrepIntegrationSettings.customRipgrepPathKey)
        XCTAssertNil(RipgrepIntegrationSettings.customRipgrepPath(defaults: defaults))
    }

    private func makeExecutableStub(
        named name: String,
        inSubdirectory subdirectory: String? = nil,
        in parent: URL? = nil
    ) throws -> URL {
        let baseDirectory = parent ?? tempDirectory!
        let containingDirectory: URL
        if let subdirectory {
            containingDirectory = baseDirectory.appendingPathComponent(subdirectory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: containingDirectory,
                withIntermediateDirectories: true
            )
        } else {
            containingDirectory = baseDirectory
        }
        let url = containingDirectory.appendingPathComponent(name, isDirectory: false)
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        return url
    }
}
