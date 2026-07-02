import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Extracted from cmuxTests/FileExplorerStateModePersistenceTests.swift so this
// branch's new notes coverage lives in a Swift Testing suite while the original
// XCTest file stays identical to main.
@Suite
struct RightSidebarNotesCliArgumentSwiftTests {
    @Test func testCLIArgumentNormalizerMapsNotesMode() {
        #expect(RightSidebarMode.from(cliArgument: "notes") == .notes)
    }
}
