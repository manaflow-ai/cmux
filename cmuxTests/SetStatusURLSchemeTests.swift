import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #3390: `cmux set-status --url=` must accept any
/// non-http scheme that LaunchServices can route. `set_status` and
/// `report_meta` share `upsertSidebarMetadata`, so this exercises both.
@MainActor
final class SetStatusURLSchemeTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        TerminalController.shared.setActiveTabManager(nil)
        try await super.tearDown()
    }

    private func bindNewTabManager(file: StaticString = #filePath, line: UInt = #line) throws -> (TabManager, Workspace) {
        let manager = TabManager()
        let workspace = try XCTUnwrap(
            manager.selectedWorkspace,
            "TabManager() should construct a default workspace",
            file: file,
            line: line
        )
        TerminalController.shared.setActiveTabManager(manager)
        return (manager, workspace)
    }

    private func sendSocketLine(_ line: String) -> String {
        TerminalController.shared.handleSocketLine(line)
    }

    private func drainMutations() {
        TerminalMutationBus.shared.drainForTesting()
    }

    func testSetStatusAcceptsAnyURLSchemeAndRoundTripsValue() throws {
        let (_, workspace) = try bindNewTabManager()

        let cases: [(key: String, url: String)] = [
            ("obsidian-deeplink", "obsidian://open?vault=Work&file=meeting.md"),
            ("vscode-deeplink", "vscode://file/tmp/x.swift:10:5"),
            ("file-deeplink", "file:///tmp/cmux-3390.txt"),
            ("mailto-deeplink", "mailto:hello@example.com"),
            ("slack-deeplink", "slack://channel?team=T0&id=C0"),
            ("linear-deeplink", "linear://issue/CMUX-123"),
            ("https-allowed-still", "https://github.com/manaflow-ai/cmux/issues/3390"),
            ("http-allowed-still", "http://localhost:3000/health"),
        ]

        for (key, url) in cases {
            let response = sendSocketLine("set_status \(key) ok --url=\(url)")
            XCTAssertEqual(
                response,
                "OK",
                "set_status with --url=\(url) should be accepted; got: \(response)"
            )
        }

        drainMutations()

        for (key, url) in cases {
            let entry = try XCTUnwrap(
                workspace.statusEntries[key],
                "Expected statusEntries[\(key)] to be populated"
            )
            XCTAssertEqual(
                entry.url?.absoluteString,
                url,
                "URL for status \(key) should round-trip exactly"
            )
        }
    }

    func testReportMetaAlsoAcceptsNonHttpScheme() throws {
        let (_, workspace) = try bindNewTabManager()

        let url = "obsidian://open?vault=Work&file=note.md"
        let response = sendSocketLine("report_meta deeplink note --url=\(url)")
        XCTAssertEqual(response, "OK", "report_meta --url=\(url) should be accepted; got: \(response)")

        drainMutations()

        let entry = try XCTUnwrap(workspace.statusEntries["deeplink"])
        XCTAssertEqual(entry.url?.absoluteString, url)
    }

    // Negative gate: relaxation is "any non-empty scheme", NOT "no scheme".
    // Do NOT weaken — typos like `--url=foo` must still be rejected.
    func testSetStatusRejectsURLWithoutScheme() throws {
        _ = try bindNewTabManager()

        let response = sendSocketLine("set_status broken something --url=justrandomweird")
        XCTAssertTrue(
            response.hasPrefix("ERROR: Invalid metadata URL"),
            "Scheme-less input should still be rejected; got: \(response)"
        )
    }

    // Negative gate: empty-scheme URLs (e.g. `://example.com`) are also rejected.
    // Do NOT weaken — empirically `URL(string: "://example.com")?.scheme == ""`
    // (NOT nil — Foundation accepts this and only the `!scheme.isEmpty` clause catches it).
    func testSetStatusRejectsURLWithEmptyScheme() throws {
        _ = try bindNewTabManager()

        let response = sendSocketLine("set_status broken something --url=://example.com")
        XCTAssertTrue(
            response.hasPrefix("ERROR: Invalid metadata URL"),
            "Empty-scheme input should still be rejected; got: \(response)"
        )
    }

    // Contract: `--url=` (empty value) is treated as "URL not provided", NOT
    // an error. The status entry is still created, just without a click target.
    // This matches `normalizedOptionValue` behavior for every other flag and
    // keeps `cmux set-status key value --url=""` as a safe way to clear the URL.
    func testSetStatusEmptyURLValueIsTreatedAsNoURL() throws {
        let (_, workspace) = try bindNewTabManager()

        let response = sendSocketLine("set_status emptyurl ok --url=")
        XCTAssertEqual(response, "OK", "Empty --url= should not error; got: \(response)")

        drainMutations()

        let entry = try XCTUnwrap(workspace.statusEntries["emptyurl"])
        XCTAssertNil(entry.url, "Empty --url= should result in no stored URL")
        XCTAssertEqual(entry.value, "ok")
    }
}
