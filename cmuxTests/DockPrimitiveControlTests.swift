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
                DockControlDefinition(id: "docs", title: "Docs", variant: .browser(url: "https://docs.cmux.dev", profile: "Unknown"))
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

    @Test("Project trust summaries distinguish command shell and browser controls")
    @MainActor
    func projectTrustSummariesDistinguishControlVariants() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("dock-\(UUID().uuidString).json", isDirectory: false)
        let controls = [
            DockControlDefinition(id: "git", title: "Git", variant: .command("lazygit")),
            DockControlDefinition(id: "shell", title: "Shell", variant: .terminal),
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

        let projectGeneration = projectStore.markConfigurationLoadInFlightForTesting(rootDirectory: root.path)
        projectStore.applyConfigurationLoadResult(.resolved(projectResolution), generation: projectGeneration, replacingPanels: true)
        let request = try #require(projectStore.trustRequest)
        #expect(request.controlSummaries.map(\.detail) == [
            .command("lazygit"),
            .loginShell,
            .browser("https://docs.cmux.dev")
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
}
