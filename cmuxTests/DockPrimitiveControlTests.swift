import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Dock primitive controls", .serialized)
struct DockPrimitiveControlTests {
    private func decode(_ json: String) throws -> DockControlDefinition {
        try JSONDecoder().decode(DockControlDefinition.self, from: Data(json.utf8))
    }

    private func encodeSorted(_ control: DockControlDefinition) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(control)
        return try #require(String(data: data, encoding: .utf8))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-dock-primitives-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func panel(in store: DockSplitStore, titled title: String) throws -> any Panel {
        for tabId in store.bonsplitController.allTabIds {
            guard store.bonsplitController.tab(tabId)?.title == title,
                  let panel = store.panel(for: tabId) else { continue }
            return panel
        }
        Issue.record("Missing Dock panel titled \(title)")
        throw NSError(domain: "cmux.tests", code: 1)
    }

    @Test("Parsing matrix covers command terminal browser and profile")
    func parsingMatrix() throws {
        let terminal = try decode(#"{"id":"shell","title":"Shell","type":"terminal","cwd":".","height":240}"#)
        #expect(terminal.variant == .terminal)
        #expect(terminal.command == nil)
        #expect(terminal.surfaceKind == .terminal)

        let legacyAlias = try decode(#"{"id":"old","title":"Old","type":"terminal","command":"lazygit"}"#)
        #expect(legacyAlias.variant == .command("lazygit"))
        #expect(legacyAlias.surfaceKind == .terminal)

        let explicitCommand = try decode(#"{"id":"cmd","title":"Command","type":"command","command":"pnpm test"}"#)
        #expect(explicitCommand.variant == .command("pnpm test"))

        #expect(throws: (any Error).self) {
            _ = try decode(#"{"id":"missing","title":"Missing","type":"command"}"#)
        }
        #expect(throws: (any Error).self) {
            _ = try decode(#"{"id":"blank","title":"Blank","type":"command","command":"   "}"#)
        }
        #expect(throws: (any Error).self) {
            _ = try decode(#"{"id":"blank-terminal","title":"Blank Terminal","type":"terminal","command":"   "}"#)
        }

        let profiledBrowser = try decode(#"{"id":"docs","title":"Docs","type":"browser","url":"https://docs.cmux.dev","profile":" Work "}"#)
        #expect(profiledBrowser.variant == .browser(url: "https://docs.cmux.dev", profile: "Work"))
        #expect(profiledBrowser.profile == "Work")

        let defaultBrowser = try decode(#"{"id":"docs","title":"Docs","type":"browser","url":"https://docs.cmux.dev","profile":"   "}"#)
        #expect(defaultBrowser.variant == .browser(url: "https://docs.cmux.dev", profile: nil))
    }

    @Test("Encoding preserves command and browser stability")
    func encodingStability() throws {
        let command = DockControlDefinition(id: "git", title: "Git", variant: .command("lazygit"))
        #expect(try encodeSorted(command) == #"{"command":"lazygit","id":"git","title":"Git"}"#)

        let legacyAlias = try decode(#"{"id":"git","title":"Git","type":"terminal","command":"lazygit"}"#)
        #expect(try encodeSorted(legacyAlias) == #"{"command":"lazygit","id":"git","title":"Git"}"#)

        let terminal = DockControlDefinition(id: "shell", title: "Shell", variant: .terminal, cwd: ".", height: 240)
        let terminalJSON = try encodeSorted(terminal)
        #expect(terminalJSON.contains(#""type":"terminal""#))
        #expect(!terminalJSON.contains(#""command""#))

        let browser = DockControlDefinition(
            id: "docs",
            title: "Docs",
            variant: .browser(url: "https://docs.cmux.dev", profile: nil)
        )
        #expect(try encodeSorted(browser) == #"{"id":"docs","title":"Docs","type":"browser","url":"https://docs.cmux.dev"}"#)
    }

    @Test("Runtime seeding branches command terminal and browser controls")
    @MainActor
    func runtimeSeedingBranchesControlVariants() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { root.path },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }

        let resolution = DockConfigResolution(
            controls: [
                DockControlDefinition(id: "git", title: "Git", variant: .command("lazygit"), cwd: "."),
                DockControlDefinition(id: "shell", title: "Shell", variant: .terminal, cwd: "."),
                DockControlDefinition(id: "docs", title: "Docs", variant: .browser(url: "https://docs.cmux.dev", profile: nil))
            ],
            sourceURL: nil,
            baseDirectory: root.path,
            isProjectSource: false
        )

        let generation = store.markConfigurationLoadInFlightForTesting(rootDirectory: root.path)
        store.applyConfigurationLoadResult(.resolved(resolution), generation: generation, replacingPanels: true)

        #expect(store.panels.count == 3)
        let commandPanel = try #require(try panel(in: store, titled: "Git") as? TerminalPanel)
        let shellPanel = try #require(try panel(in: store, titled: "Shell") as? TerminalPanel)
        let browserPanel = try panel(in: store, titled: "Docs")

        #expect(commandPanel.surface.initialCommand != nil)
        #expect(shellPanel.surface.initialCommand == nil)
        #expect(shellPanel.surface.requestedWorkingDirectory == DockSplitStore.resolvedWorkingDirectory(".", baseDirectory: root.path))
        #expect(browserPanel is BrowserPanel)
    }

    @Test("Unavailable browser controls skip profile lookup while seeding terminals")
    @MainActor
    func unavailableBrowserControlsSkipProfileLookupWhileSeedingTerminals() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { root.path },
            browserAvailabilityProvider: { false }
        )
        defer { store.closeAllPanels() }

        let resolution = DockConfigResolution(
            controls: [
                DockControlDefinition(id: "git", title: "Git", variant: .command("lazygit"), cwd: "."),
                DockControlDefinition(
                    id: "docs",
                    title: "Docs",
                    variant: .browser(url: "https://docs.cmux.dev", profile: "missing-\(UUID().uuidString)")
                ),
                DockControlDefinition(id: "shell", title: "Shell", variant: .terminal, cwd: ".")
            ],
            sourceURL: nil,
            baseDirectory: root.path,
            isProjectSource: false
        )

        let generation = store.markConfigurationLoadInFlightForTesting(rootDirectory: root.path)
        store.applyConfigurationLoadResult(.resolved(resolution), generation: generation, replacingPanels: true)

        #expect(store.errorMessage == nil)
        #expect(store.panels.count == 2)
        _ = try #require(try panel(in: store, titled: "Git") as? TerminalPanel)
        _ = try #require(try panel(in: store, titled: "Shell") as? TerminalPanel)
    }

    @Test("Browser profile references use stable IDs and fail closed on ambiguous names")
    @MainActor
    func browserProfileReferencesUseStableIDsAndFailClosed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let profileName = "Dock Profile \(UUID().uuidString)"
        let profile = try #require(BrowserProfileStore.shared.createProfile(named: profileName))
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: profile.id) }

        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { root.path },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }

        let resolution = DockConfigResolution(
            controls: [
                DockControlDefinition(
                    id: "docs",
                    title: "Docs",
                    variant: .browser(url: "https://docs.cmux.dev", profile: profile.id.uuidString)
                )
            ],
            sourceURL: nil,
            baseDirectory: root.path,
            isProjectSource: false
        )

        let generation = store.markConfigurationLoadInFlightForTesting(rootDirectory: root.path)
        store.applyConfigurationLoadResult(.resolved(resolution), generation: generation, replacingPanels: true)

        let browserPanel = try #require(try panel(in: store, titled: "Docs") as? BrowserPanel)
        #expect(browserPanel.profileID == profile.id)

        let duplicateName = "Dock Duplicate \(UUID().uuidString)"
        let firstDuplicate = try #require(BrowserProfileStore.shared.createProfile(named: duplicateName))
        let secondDuplicate = try #require(BrowserProfileStore.shared.createProfile(named: duplicateName))
        defer {
            _ = BrowserProfileStore.shared.deleteProfile(id: firstDuplicate.id)
            _ = BrowserProfileStore.shared.deleteProfile(id: secondDuplicate.id)
        }

        let ambiguousStore = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { root.path },
            browserAvailabilityProvider: { true }
        )
        defer { ambiguousStore.closeAllPanels() }

        let ambiguousResolution = DockConfigResolution(
            controls: [
                DockControlDefinition(
                    id: "before",
                    title: "Before",
                    variant: .command("echo should-not-start")
                ),
                DockControlDefinition(
                    id: "ambiguous",
                    title: "Ambiguous",
                    variant: .browser(url: "https://docs.cmux.dev", profile: duplicateName)
                )
            ],
            sourceURL: nil,
            baseDirectory: root.path,
            isProjectSource: false
        )

        let ambiguousGeneration = ambiguousStore.markConfigurationLoadInFlightForTesting(rootDirectory: root.path)
        ambiguousStore.applyConfigurationLoadResult(
            .resolved(ambiguousResolution),
            generation: ambiguousGeneration,
            replacingPanels: true
        )

        #expect(ambiguousStore.panels.isEmpty)
        #expect(ambiguousStore.errorMessage?.contains("matches multiple") == true)
    }

    @Test("UUID-shaped browser profile names fall back to name lookup")
    func uuidShapedBrowserProfileNamesFallBackToNameLookup() throws {
        let defaultID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let profileID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let uuidShapedName = "00000000-0000-0000-0000-000000000003"

        var index = DockBrowserProfileIndex(
            defaultProfileID: defaultID,
            defaultProfileDisplayName: "Default"
        )
        index.addProfile(id: defaultID, displayName: "Default", slug: "default")
        index.addProfile(id: profileID, displayName: uuidShapedName, slug: "uuid-shaped")

        let resolution = try index.resolve(uuidShapedName)

        #expect(resolution.id == profileID)
        #expect(resolution.displayName == uuidShapedName)
        #expect(!resolution.isDefault)
    }

    @Test("Project trust fingerprints bind browser profile identity")
    @MainActor
    func projectTrustFingerprintBindsBrowserProfileIdentity() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("dock-\(UUID().uuidString).json", isDirectory: false)
        let profileName = "Dock Trust \(UUID().uuidString)"

        func trustRequest() throws -> DockTrustRequest {
            let resolution = DockConfigResolution(
                controls: [
                    DockControlDefinition(
                        id: "docs",
                        title: "Docs",
                        variant: .browser(url: "https://docs.cmux.dev", profile: profileName)
                    )
                ],
                sourceURL: configURL,
                baseDirectory: root.path,
                isProjectSource: true
            )
            let store = DockSplitStore(
                workspaceId: UUID(),
                baseDirectoryProvider: { root.path },
                browserAvailabilityProvider: { true }
            )
            defer { store.closeAllPanels() }
            let generation = store.markConfigurationLoadInFlightForTesting(rootDirectory: root.path)
            store.applyConfigurationLoadResult(.resolved(resolution), generation: generation, replacingPanels: true)
            return try #require(store.trustRequest)
        }

        let firstProfile = try #require(BrowserProfileStore.shared.createProfile(named: profileName))
        let firstProfileID = firstProfile.id
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: firstProfileID) }
        let firstRequest = try trustRequest()
        let firstFingerprint = firstRequest.descriptor.fingerprint
        #expect(firstRequest.controlSummaries.map(\.detail) == [
            .browser(
                url: "https://docs.cmux.dev",
                profileDisplayName: profileName,
                profileIsDefault: false,
                profileID: firstProfileID.uuidString
            )
        ])

        _ = BrowserProfileStore.shared.deleteProfile(id: firstProfileID)
        let secondProfile = try #require(BrowserProfileStore.shared.createProfile(named: profileName))
        let secondProfileID = secondProfile.id
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: secondProfileID) }
        let secondFingerprint = try trustRequest().descriptor.fingerprint

        #expect(firstProfileID != secondProfileID)
        #expect(firstFingerprint != secondFingerprint)
    }

    @Test("Project trust summaries distinguish command shell and browser controls")
    @MainActor
    func projectTrustSummariesDistinguishControlVariants() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("dock-\(UUID().uuidString).json", isDirectory: false)
        let controls = [
            DockControlDefinition(
                id: "git",
                title: "Git",
                variant: .command("lazygit"),
                cwd: ".",
                env: ["PATH": "/tmp/cmux-bin"]
            ),
            DockControlDefinition(
                id: "shell",
                title: "Shell",
                variant: .terminal,
                cwd: "shell",
                env: ["ZDOTDIR": root.path]
            ),
            DockControlDefinition(id: "docs", title: "Docs", variant: .browser(url: "https://docs.cmux.dev", profile: nil))
        ]
        let projectResolution = DockConfigResolution(
            controls: controls,
            sourceURL: configURL,
            baseDirectory: root.path,
            isProjectSource: true
        )
        let globalResolution = DockConfigResolution(
            controls: controls,
            sourceURL: configURL,
            baseDirectory: root.path,
            isProjectSource: false
        )

        let projectStore = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { root.path },
            browserAvailabilityProvider: { true }
        )
        defer { projectStore.closeAllPanels() }

        let defaultProfileName = BrowserProfileStore.shared.displayName(
            for: BrowserProfileStore.shared.builtInDefaultProfileID
        )
        let projectGeneration = projectStore.markConfigurationLoadInFlightForTesting(rootDirectory: root.path)
        projectStore.applyConfigurationLoadResult(.resolved(projectResolution), generation: projectGeneration, replacingPanels: true)
        let request = try #require(projectStore.trustRequest)
        #expect(request.controlSummaries.map(\.detail) == [
            .command(
                command: "lazygit",
                workingDirectory: DockSplitStore.resolvedWorkingDirectory(".", baseDirectory: root.path),
                environment: ["PATH": "/tmp/cmux-bin"]
            ),
            .loginShell(
                workingDirectory: DockSplitStore.resolvedWorkingDirectory("shell", baseDirectory: root.path),
                environment: ["ZDOTDIR": root.path]
            ),
            .browser(
                url: "https://docs.cmux.dev",
                profileDisplayName: defaultProfileName,
                profileIsDefault: true,
                profileID: BrowserProfileStore.shared.builtInDefaultProfileID.uuidString
            )
        ])

        let globalStore = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { root.path },
            browserAvailabilityProvider: { true }
        )
        defer { globalStore.closeAllPanels() }

        let globalGeneration = globalStore.markConfigurationLoadInFlightForTesting(rootDirectory: root.path)
        globalStore.applyConfigurationLoadResult(.resolved(globalResolution), generation: globalGeneration, replacingPanels: true)
        #expect(globalStore.trustRequest == nil)
    }

    @Test("Project trust summary shows default browser profile when browser is unavailable")
    @MainActor
    func projectTrustSummaryShowsDefaultBrowserProfileWhenBrowserUnavailable() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("dock-\(UUID().uuidString).json", isDirectory: false)
        let resolution = DockConfigResolution(
            controls: [
                DockControlDefinition(id: "docs", title: "Docs", variant: .browser(url: "https://docs.cmux.dev", profile: nil))
            ],
            sourceURL: configURL,
            baseDirectory: root.path,
            isProjectSource: true
        )

        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { root.path },
            browserAvailabilityProvider: { false }
        )
        defer { store.closeAllPanels() }

        let generation = store.markConfigurationLoadInFlightForTesting(rootDirectory: root.path)
        store.applyConfigurationLoadResult(.resolved(resolution), generation: generation, replacingPanels: true)

        let defaultProfileID = BrowserProfileStore.shared.builtInDefaultProfileID
        let defaultProfileName = BrowserProfileStore.shared.displayName(for: defaultProfileID)
        let request = try #require(store.trustRequest)
        #expect(request.controlSummaries.map(\.detail) == [
            .browser(
                url: "https://docs.cmux.dev",
                profileDisplayName: defaultProfileName,
                profileIsDefault: true,
                profileID: defaultProfileID.uuidString
            )
        ])
    }
}
