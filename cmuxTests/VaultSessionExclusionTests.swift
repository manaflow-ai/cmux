import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Vault session exclusions")
struct VaultSessionExclusionTests {
    @Test("Claude metadata preserves an SDK entrypoint")
    func claudeMetadataReadsEntrypoint() {
        let parsed = SessionIndexStore.extractClaudeMetadata(
            head: #"{"type":"user","entrypoint":"sdk-py","cwd":"/tmp/cmux-vault-test","message":{"role":"user","content":"Review this change"}}"#,
            tail: "",
            projectDir: "-Users-me-project"
        )

        #expect(parsed.entrypoint == "sdk-py")
        #expect(parsed.title == "Review this change")
        #expect(parsed.cwd == "/tmp/cmux-vault-test")
    }

    @Test("SDK hiding only removes Claude SDK sessions")
    func sdkHidingIsScopedToClaude() {
        let registry = CmuxVaultAgentRegistry(
            registrations: [],
            hideClaudeSDKSessions: true
        )
        let claudeSDK = makeEntry(agent: .claude, entrypoint: "sdk-py")
        let claudeCLI = makeEntry(agent: .claude, entrypoint: "cli")
        let codexSDK = makeEntry(agent: .codex, entrypoint: "sdk-py")

        #expect(registry.excludes(claudeSDK))
        #expect(!registry.excludes(claudeCLI))
        #expect(!registry.excludes(codexSDK))
    }

    @Test("Exclusion rules combine fields and support label patterns")
    func exclusionRuleMatchesAllFields() throws {
        let decoded = try JSONDecoder().decode(
            CmuxVaultConfigDefinition.self,
            from: Data(#"{"exclude":[{"agent":"claude","folder":"/work/*","entrypoint":"sdk-*","labelPattern":"re:^Review this"}]}"#.utf8)
        )
        let registry = CmuxVaultAgentRegistry(
            registrations: [],
            sessionExclusions: decoded.exclude
        )
        let matching = makeEntry(
            agent: .claude,
            entrypoint: "sdk-py",
            title: "Review this change",
            cwd: "/work/cmux"
        )
        let wrongFolder = makeEntry(
            agent: .claude,
            entrypoint: "sdk-py",
            title: "Review this change",
            cwd: "/other/cmux"
        )
        let wrongEntrypoint = makeEntry(
            agent: .claude,
            entrypoint: "cli",
            title: "Review this change",
            cwd: "/work/cmux"
        )

        #expect(registry.excludes(matching))
        #expect(!registry.excludes(wrongFolder))
        #expect(!registry.excludes(wrongEntrypoint))
    }

    @Test("Vault config can contain filters without agent registrations")
    func configDefaultsAgentsToEmpty() throws {
        let config = try JSONDecoder().decode(
            CmuxVaultConfigDefinition.self,
            from: Data(#"{"hideClaudeSDKSessions":true,"exclude":[{"labelPattern":"*background*"}]}"#.utf8)
        )

        #expect(config.agents.isEmpty)
        #expect(config.hideClaudeSDKSessions)
        #expect(config.exclude.count == 1)
    }

    @Test("Pattern is accepted as a label matcher alias")
    func patternAliasDecodes() throws {
        let config = try JSONDecoder().decode(
            CmuxVaultConfigDefinition.self,
            from: Data(#"{"exclude":[{"pattern":"*background*"}]}"#.utf8)
        )

        #expect(config.exclude.first?.matches(makeEntry(agent: .claude, title: "background review")) == true)
    }

    @Test("Registry loads Vault filters from the user config")
    func registryLoadsFilters() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-vault-filter-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }
        try #"{"vault":{"hideClaudeSDKSessions":true,"exclude":[{"agent":"codex"}]}}"#.write(
            to: configDirectory.appendingPathComponent("cmux.json"),
            atomically: true,
            encoding: .utf8
        )

        let registry = CmuxVaultAgentRegistry.load(homeDirectory: home.path, environment: [:])

        #expect(registry.hasSessionExclusions(for: .claude))
        #expect(registry.excludes(makeEntry(agent: .claude, entrypoint: "sdk-ts")))
        #expect(registry.excludes(makeEntry(agent: .codex)))
        #expect(!registry.excludes(makeEntry(agent: .claude, entrypoint: "cli")))
    }

    @Test("A label pattern without re: is a wildcard, not a substring regex")
    func labelPatternIsWildcardUnlessPrefixed() {
        let wildcard = CmuxVaultSessionExclusion(labelPattern: "Draft*")
        let regex = CmuxVaultSessionExclusion(labelPattern: "re:draft")

        #expect(wildcard.matches(makeEntry(agent: .claude, title: "Draft notes")))
        #expect(!wildcard.matches(makeEntry(agent: .claude, title: "Redrafting notes")))
        #expect(regex.matches(makeEntry(agent: .claude, title: "Redrafting notes")))
    }

    @Test("A wildcard still spans a literal star in the label")
    func wildcardSpansLiteralStar() {
        let rule = CmuxVaultSessionExclusion(labelPattern: "*review*")

        #expect(rule.matches(makeEntry(agent: .claude, title: "**Bold** review this")))
    }

    @Test("Exclusions only make an agent filter when a rule can match it")
    func exclusionsAreScopedPerAgent() {
        let sdkOnly = CmuxVaultAgentRegistry(registrations: [], hideClaudeSDKSessions: true)
        let codexRule = CmuxVaultAgentRegistry(
            registrations: [],
            sessionExclusions: [CmuxVaultSessionExclusion(agent: "codex")]
        )
        let anyAgentRule = CmuxVaultAgentRegistry(
            registrations: [],
            sessionExclusions: [CmuxVaultSessionExclusion(folder: "/scratch/*")]
        )

        #expect(sdkOnly.hasSessionExclusions(for: .claude))
        #expect(!sdkOnly.hasSessionExclusions(for: .codex))
        #expect(codexRule.hasSessionExclusions(for: .codex))
        #expect(!codexRule.hasSessionExclusions(for: .claude))
        #expect(anyAgentRule.hasSessionExclusions(for: .claude))
        #expect(anyAgentRule.hasSessionExclusions(for: .codex))
    }

    @Test("A filtered page grows its source read only until the page is full")
    func filteredPageGrowsSourceRead() async {
        let source = (0..<200).map { makeEntry(agent: .claude, title: "s\($0)") }
        let hidden = Set(source.prefix(40).map(\.id))
        let requests = LimitRecorder()

        let page = await SessionIndexStore.filteredSourcePage(
            offset: 5,
            limit: 10,
            ceiling: 1500,
            shortReadMeansExhausted: true,
            load: { limit in
                requests.append(limit)
                return Array(source.prefix(limit))
            },
            isIncluded: { !hidden.contains($0.id) }
        )

        #expect(page.map(\.title) == (45..<55).map { "s\($0)" })
        #expect(requests.values == [30, 60])
    }

    @Test("A filtered page stops when the source is exhausted or at the ceiling")
    func filteredPageStopsAtSourceEnd() async {
        let source = (0..<50).map { makeEntry(agent: .claude, title: "s\($0)") }
        let exhausted = LimitRecorder()
        let capped = LimitRecorder()

        let short = await SessionIndexStore.filteredSourcePage(
            offset: 0,
            limit: 30,
            ceiling: 1500,
            shortReadMeansExhausted: true,
            load: { limit in
                exhausted.append(limit)
                return Array(source.prefix(limit))
            },
            isIncluded: { $0.title != "s0" }
        )
        _ = await SessionIndexStore.filteredSourcePage(
            offset: 0,
            limit: 100,
            ceiling: 120,
            shortReadMeansExhausted: true,
            load: { limit in
                capped.append(limit)
                return Array(repeating: source[0], count: limit)
            },
            isIncluded: { _ in false }
        )

        #expect(short.count == 30)
        #expect(exhausted.values == [60])
        #expect(capped.values == [120])
    }

    @Test("A loader that drops part of its window keeps growing until the page fills")
    func filteredPageKeepsGrowingPastShortWindowedReads() async {
        // Like Claude's loader: each read parses a window of 2x the request
        // and returns only the sessions in this folder, so a short read does
        // not mean the source is exhausted.
        let source = (0..<400).map { makeEntry(agent: .claude, title: "s\($0)") }
        let inFolder = Set(source.enumerated().filter { $0.offset % 10 == 0 }.map(\.element.id))
        let requests = LimitRecorder()

        let page = await SessionIndexStore.filteredSourcePage(
            offset: 0,
            limit: 20,
            ceiling: 200,
            shortReadMeansExhausted: false,
            load: { limit in
                requests.append(limit)
                return Array(source.prefix(limit * 2).filter { inFolder.contains($0.id) }.prefix(limit))
            },
            isIncluded: { _ in true }
        )

        #expect(page.count == 20)
        #expect(requests.values == [40, 80, 160])
    }

    private final class LimitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Int] = []
        func append(_ value: Int) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(value)
        }
        var values: [Int] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
    }

    private func makeEntry(
        agent: SessionAgent,
        entrypoint: String? = nil,
        title: String = "session",
        cwd: String = "/work"
    ) -> SessionEntry {
        SessionEntry(
            id: agent.rawValue + ":" + title,
            agent: agent,
            sessionId: "session-id",
            title: title,
            entrypoint: entrypoint,
            cwd: cwd,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1),
            fileURL: nil,
            specifics: agent == .claude
                ? .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil)
                : .codex(model: nil, approvalPolicy: nil, sandboxMode: nil, effort: nil)
        )
    }
}
