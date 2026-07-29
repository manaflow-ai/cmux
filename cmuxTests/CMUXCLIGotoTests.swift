import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct CMUXCLIGotoTests {

    // MARK: - Short ref parsing

    @Test func testWorkspaceRefParses() throws {
        let result = try CMUXCLI.parseGotoTarget("workspace:7")
        guard case .workspace(let handle) = result else {
            Issue.record("expected .workspace, got \(result)")
            return
        }
        #expect(handle == "workspace:7")
    }

    @Test func testPaneRefParses() throws {
        let result = try CMUXCLI.parseGotoTarget("pane:34")
        guard case .pane(let handle) = result else {
            Issue.record("expected .pane, got \(result)")
            return
        }
        #expect(handle == "pane:34")
    }

    @Test func testSurfaceRefParses() throws {
        let result = try CMUXCLI.parseGotoTarget("surface:243")
        guard case .surface(let handle) = result else {
            Issue.record("expected .surface, got \(result)")
            return
        }
        #expect(handle == "surface:243")
    }

    @Test func testWorkspaceRefCaseInsensitive() throws {
        let result = try CMUXCLI.parseGotoTarget("Workspace:1")
        guard case .workspace(let handle) = result else {
            Issue.record("expected .workspace, got \(result)")
            return
        }
        #expect(handle == "Workspace:1")
    }

    @Test func testPaneRefCaseInsensitive() throws {
        let result = try CMUXCLI.parseGotoTarget("PANE:5")
        guard case .pane(let handle) = result else {
            Issue.record("expected .pane, got \(result)")
            return
        }
        #expect(handle == "PANE:5")
    }

    // MARK: - UUID parsing

    @Test func testUUIDParses() throws {
        let uuid = "8A3F2B1C-4D5E-6F70-8192-A3B4C5D6E7F8"
        let result = try CMUXCLI.parseGotoTarget(uuid)
        guard case .uuid(let parsed) = result else {
            Issue.record("expected .uuid, got \(result)")
            return
        }
        #expect(parsed == uuid)
    }

    @Test func testLowercaseUUIDParses() throws {
        let uuid = "8a3f2b1c-4d5e-6f70-8192-a3b4c5d6e7f8"
        let result = try CMUXCLI.parseGotoTarget(uuid)
        guard case .uuid = result else {
            Issue.record("expected .uuid, got \(result)")
            return
        }
    }

    // MARK: - Ambiguous bare numeric

    @Test func testBareNumericThrowsAmbiguous() {
        #expect(throws: CLIError.self) {
            _ = try CMUXCLI.parseGotoTarget("42")
        }
    }

    @Test func testBareNumericErrorMessageContainsPrefix() throws {
        do {
            _ = try CMUXCLI.parseGotoTarget("7")
            Issue.record("expected error")
        } catch let error as CLIError {
            #expect(error.message.contains("ambiguous"))
            #expect(error.message.contains("workspace:"))
            #expect(error.message.contains("pane:"))
            #expect(error.message.contains("surface:"))
        }
    }

    // MARK: - Invalid targets

    @Test func testEmptyTargetThrows() {
        #expect(throws: CLIError.self) {
            _ = try CMUXCLI.parseGotoTarget("")
        }
    }

    @Test func testWhitespaceOnlyTargetThrows() {
        #expect(throws: CLIError.self) {
            _ = try CMUXCLI.parseGotoTarget("   ")
        }
    }

    @Test func testUnknownPrefixThrows() {
        #expect(throws: CLIError.self) {
            _ = try CMUXCLI.parseGotoTarget("tab:3")
        }
    }

    @Test func testGarbageStringThrows() {
        #expect(throws: CLIError.self) {
            _ = try CMUXCLI.parseGotoTarget("not-a-valid-target")
        }
    }

    @Test func testRefWithNonNumericSuffixThrows() {
        // workspace:abc is not a valid ref (suffix must be numeric)
        #expect(throws: CLIError.self) {
            _ = try CMUXCLI.parseGotoTarget("workspace:abc")
        }
    }

    // MARK: - Stale ID simulation

    @Test func testStaleUUIDFormatIsStillParsedAsUUID() throws {
        // A stale UUID still parses; the runtime resolution step detects
        // it is gone. This test verifies parsing accepts valid UUID syntax
        // even for IDs that no longer exist on the server.
        let staleUUID = "DEADBEEF-0000-0000-0000-000000000000"
        let result = try CMUXCLI.parseGotoTarget(staleUUID)
        guard case .uuid(let parsed) = result else {
            Issue.record("expected .uuid, got \(result)")
            return
        }
        #expect(parsed == staleUUID)
    }

    // MARK: - Whitespace trimming

    @Test func testLeadingTrailingWhitespaceIsTrimmed() throws {
        let result = try CMUXCLI.parseGotoTarget("  workspace:3  ")
        guard case .workspace(let handle) = result else {
            Issue.record("expected .workspace, got \(result)")
            return
        }
        #expect(handle == "workspace:3")
    }

    // MARK: - Edge ref numbers

    @Test func testRefWithZeroIndex() throws {
        let result = try CMUXCLI.parseGotoTarget("pane:0")
        guard case .pane(let handle) = result else {
            Issue.record("expected .pane, got \(result)")
            return
        }
        #expect(handle == "pane:0")
    }

    @Test func testRefWithLargeIndex() throws {
        let result = try CMUXCLI.parseGotoTarget("surface:99999")
        guard case .surface(let handle) = result else {
            Issue.record("expected .surface, got \(result)")
            return
        }
        #expect(handle == "surface:99999")
    }
}
