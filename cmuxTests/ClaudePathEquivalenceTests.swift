import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ClaudePathEquivalenceTests: XCTestCase {
    private func mapping(_ remote: String, _ local: String) -> CmuxVaultPathMapping {
        CmuxVaultPathMapping(remote: remote, local: local)
    }

    // MARK: normalizePrefix

    func testNormalizePrefixExpandsTilde() {
        XCTAssertEqual(
            ClaudePathEquivalence.normalizePrefix("~/code", homeDirectory: "/Users/me"),
            "/Users/me/code"
        )
        XCTAssertEqual(
            ClaudePathEquivalence.normalizePrefix("~", homeDirectory: "/Users/me"),
            "/Users/me"
        )
    }

    func testNormalizePrefixStripsTrailingSlashes() {
        XCTAssertEqual(
            ClaudePathEquivalence.normalizePrefix("/workspace///", homeDirectory: "/Users/me"),
            "/workspace"
        )
    }

    func testNormalizePrefixRejectsRootAndEmpty() {
        XCTAssertNil(ClaudePathEquivalence.normalizePrefix("/", homeDirectory: "/Users/me"))
        XCTAssertNil(ClaudePathEquivalence.normalizePrefix("   ", homeDirectory: "/Users/me"))
        XCTAssertNil(ClaudePathEquivalence.normalizePrefix("~", homeDirectory: "/"))
    }

    // MARK: variants

    func testVariantsWithoutMappingsReturnsSelf() {
        let eq = ClaudePathEquivalence(mappings: [], homeDirectory: "/Users/me")
        XCTAssertEqual(eq.variants(of: "/Users/me/p/x"), ["/Users/me/p/x"])
    }

    func testVariantsMapsBothDirections() {
        let eq = ClaudePathEquivalence(
            mappings: [mapping("/workspace", "/Users/me")],
            homeDirectory: "/Users/me"
        )
        XCTAssertEqual(
            Set(eq.variants(of: "/workspace/p/x")),
            ["/workspace/p/x", "/Users/me/p/x"]
        )
        XCTAssertEqual(
            Set(eq.variants(of: "/Users/me/p/x")),
            ["/Users/me/p/x", "/workspace/p/x"]
        )
    }

    func testVariantsMatchesExactPrefixPath() {
        let eq = ClaudePathEquivalence(
            mappings: [mapping("/workspace", "/Users/me")],
            homeDirectory: "/Users/me"
        )
        XCTAssertEqual(Set(eq.variants(of: "/workspace")), ["/workspace", "/Users/me"])
    }

    func testVariantsRespectsSegmentBoundary() {
        let eq = ClaudePathEquivalence(
            mappings: [mapping("/work", "/Users/me")],
            homeDirectory: "/Users/me"
        )
        // "/workspace" must not be rewritten by a "/work" mapping.
        XCTAssertEqual(eq.variants(of: "/workspace/p"), ["/workspace/p"])
    }

    // MARK: equates

    func testEquatesEqualPaths() {
        let eq = ClaudePathEquivalence(mappings: [], homeDirectory: "/Users/me")
        XCTAssertTrue(eq.equates("/Users/me/p", "/Users/me/p"))
    }

    func testEquatesMappedPaths() {
        let eq = ClaudePathEquivalence(
            mappings: [mapping("/workspace", "/Users/me")],
            homeDirectory: "/Users/me"
        )
        XCTAssertTrue(eq.equates("/workspace/p/x", "/Users/me/p/x"))
        XCTAssertTrue(eq.equates("/Users/me/p/x", "/workspace/p/x"))
    }

    func testEquatesRejectsUnrelatedPaths() {
        let eq = ClaudePathEquivalence(
            mappings: [mapping("/workspace", "/Users/me")],
            homeDirectory: "/Users/me"
        )
        XCTAssertFalse(eq.equates("/workspace/p/x", "/Users/me/p/y"))
        XCTAssertFalse(eq.equates("/workspace/p/x", "/opt/p/x"))
    }

    func testEquatesRespectsSegmentBoundary() {
        let eq = ClaudePathEquivalence(
            mappings: [mapping("/work", "/Users/me")],
            homeDirectory: "/Users/me"
        )
        XCTAssertFalse(eq.equates("/workspace/p", "/Users/me/p"))
    }

    func testEquatesExpandsTildeInLocalMapping() {
        let eq = ClaudePathEquivalence(
            mappings: [mapping("/workspace", "~/code")],
            homeDirectory: "/Users/me"
        )
        XCTAssertTrue(eq.equates("/workspace/p", "/Users/me/code/p"))
    }

    // MARK: projectDirSlugCandidates

    func testSlugCandidatesLiteralFirstThenMapped() {
        let eq = ClaudePathEquivalence(
            mappings: [mapping("/workspace", "/Users/me")],
            homeDirectory: "/Users/me"
        )
        let slugs = eq.projectDirSlugCandidates(forCwd: "/Users/me/p/x")
        XCTAssertEqual(slugs.first, "-Users-me-p-x")
        XCTAssertTrue(slugs.contains("-workspace-p-x"))
    }

    func testSlugCandidatesWithoutMappingsIsSingleLiteral() {
        let eq = ClaudePathEquivalence(mappings: [], homeDirectory: "/Users/me")
        XCTAssertEqual(eq.projectDirSlugCandidates(forCwd: "/Users/me/p/x"), ["-Users-me-p-x"])
    }

    func testSlugCandidatesDedupes() {
        // A mapping whose variant encodes to the same slug must not duplicate.
        let eq = ClaudePathEquivalence(
            mappings: [mapping("/a.b", "/a-b")],
            homeDirectory: "/Users/me"
        )
        let slugs = eq.projectDirSlugCandidates(forCwd: "/a.b/p")
        XCTAssertEqual(slugs, Array(NSOrderedSet(array: slugs).map { $0 as! String }))
    }

    // MARK: config decode

    func testVaultConfigDecodesRootsAndMappings() throws {
        let json = Data("""
        {
          "vault": {
            "claudeSessionRoots": ["~/mnt/devcontainer/.claude", "  ", "~/mnt/devcontainer/.claude"],
            "claudePathMappings": [
              { "remote": "/workspace", "local": "/Users/me" }
            ]
          }
        }
        """.utf8)
        let config = try JSONDecoder().decode(CmuxConfigFile.self, from: json)
        let vault = try XCTUnwrap(config.vault)
        // Blank entries dropped, duplicates collapsed.
        XCTAssertEqual(vault.claudeSessionRoots, ["~/mnt/devcontainer/.claude"])
        XCTAssertEqual(vault.claudePathMappings.count, 1)
        XCTAssertEqual(vault.claudePathMappings.first?.remote, "/workspace")
        XCTAssertEqual(vault.claudePathMappings.first?.local, "/Users/me")
        XCTAssertTrue(vault.agents.isEmpty)
    }

    func testVaultConfigDefaultsWhenKeysOmitted() throws {
        let json = Data(#"{"vault":{"agents":[]}}"#.utf8)
        let config = try JSONDecoder().decode(CmuxConfigFile.self, from: json)
        let vault = try XCTUnwrap(config.vault)
        XCTAssertTrue(vault.claudeSessionRoots.isEmpty)
        XCTAssertTrue(vault.claudePathMappings.isEmpty)
    }

    func testVaultPathMappingRejectsBlankSides() {
        let json = Data(#"{"vault":{"claudePathMappings":[{"remote":"","local":"/Users/me"}]}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CmuxConfigFile.self, from: json))
    }

    // MARK: loadVaultClaudeConfig

    func testLoadVaultClaudeConfigReadsUserConfig() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("cmux-equiv-\(UUID().uuidString)", isDirectory: true)
        let configDir = home.appendingPathComponent(".config/cmux", isDirectory: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let configURL = configDir.appendingPathComponent("cmux.json")
        try Data("""
        {
          "vault": {
            "claudeSessionRoots": ["~/mnt/.claude"],
            "claudePathMappings": [{ "remote": "/workspace", "local": "~/code" }]
          }
        }
        """.utf8).write(to: configURL)

        let result = ClaudePathEquivalence.loadVaultClaudeConfig(homeDirectory: home.path)
        XCTAssertEqual(result.extraRoots, ["~/mnt/.claude"])
        XCTAssertTrue(result.equivalence.equates("/workspace/p", home.appendingPathComponent("code/p").path))
    }

    func testLoadVaultClaudeConfigMissingFileReturnsEmpty() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-equiv-missing-\(UUID().uuidString)", isDirectory: true)
        let result = ClaudePathEquivalence.loadVaultClaudeConfig(homeDirectory: home.path)
        XCTAssertTrue(result.extraRoots.isEmpty)
        XCTAssertTrue(result.equivalence.isEmpty)
    }
}
