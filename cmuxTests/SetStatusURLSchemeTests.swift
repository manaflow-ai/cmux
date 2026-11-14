import AppKit
import CmuxSidebar
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #3390 through the shared sidebar metadata socket path.
@MainActor
@Suite(.serialized)
struct SetStatusURLSchemeTests {
    private func withWorkspace(_ test: (Workspace) throws -> Void) throws {
        _ = NSApplication.shared
        let controller = TerminalController.shared
        let previousManager = controller.activeTabManagerForCallerNotification()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        controller.setActiveTabManager(manager)
        defer {
            TerminalMutationBus.shared.drainForTesting()
            manager.tabs.forEach { $0.teardownAllPanels() }
            controller.setActiveTabManager(previousManager)
        }
        try withExtendedLifetime(manager) {
            try test(workspace)
        }
    }

    @Test func testSetStatusAcceptsAnyURLSchemeAndRoundTripsValue() throws {
        try withWorkspace { workspace in
            let cases: [(key: String, url: String)] = [
                ("obsidian-deeplink", "obsidian://open?vault=Work&file=meeting.md"),
                ("vscode-deeplink", "vscode://file/tmp/x.swift:10:5"),
                ("file-deeplink", "file:///tmp/cmux-3390.txt"),
                ("mailto-deeplink", "mailto:hello@example.com"),
                ("tel-deeplink", "tel:+12025550123"),
                ("custom-deeplink", "cmux-dev-tool://open/project"),
                ("slack-deeplink", "slack://channel?team=T0&id=C0"),
                ("linear-deeplink", "linear://issue/CMUX-123"),
                ("https-allowed-still", "https://github.com/manaflow-ai/cmux/issues/3390"),
                ("http-allowed-still", "http://localhost:3000/health"),
            ]

            for (key, url) in cases {
                let response = TerminalController.shared.handleSocketLine("set_status \(key) ok --url=\(url)")
                #expect(response == "OK", "set_status --url=\(url): \(response)")
            }

            TerminalMutationBus.shared.drainForTesting()

            for (key, url) in cases {
                let entry = try #require(workspace.statusEntries[key])
                #expect(entry.url?.absoluteString == url, "URL for status \(key) should round-trip exactly")
            }
        }
    }

    @Test func testReportMetaAlsoAcceptsNonHttpScheme() throws {
        try withWorkspace { workspace in
            let url = "obsidian://open?vault=Work&file=note.md"
            let response = TerminalController.shared.handleSocketLine("report_meta deeplink note --url=\(url)")
            #expect(response == "OK")

            TerminalMutationBus.shared.drainForTesting()

            let entry = try #require(workspace.statusEntries["deeplink"])
            #expect(entry.url?.absoluteString == url)
        }
    }

    @Test func testSetStatusRejectsURLWithoutScheme() throws {
        try withWorkspace { workspace in
            let response = TerminalController.shared.handleSocketLine("set_status broken something --url=justrandomweird")
            #expect(response.hasPrefix("ERROR:"))
            TerminalMutationBus.shared.drainForTesting()
            #expect(workspace.statusEntries["broken"] == nil)
        }
    }

    @Test func testSetStatusRejectsURLWithEmptyScheme() throws {
        try withWorkspace { workspace in
            let response = TerminalController.shared.handleSocketLine("set_status broken something --url=://example.com")
            #expect(response.hasPrefix("ERROR:"))
            TerminalMutationBus.shared.drainForTesting()
            #expect(workspace.statusEntries["broken"] == nil)
        }
    }

    @Test func testSetStatusEmptyURLValueIsTreatedAsNoURL() throws {
        try withWorkspace { workspace in
            let response = TerminalController.shared.handleSocketLine("set_status emptyurl ok --url=")
            #expect(response == "OK")

            TerminalMutationBus.shared.drainForTesting()

            let entry = try #require(workspace.statusEntries["emptyurl"])
            #expect(entry.url == nil)
            #expect(entry.value == "ok")
        }
    }
}
