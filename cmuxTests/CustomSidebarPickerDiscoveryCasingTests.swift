import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// The provider picker lists exactly the sidebars that can actually be opened.
///
/// The picker scan lowercased each file's extension before matching, while resolution builds
/// `<name>.<ext>` from the lowercase list and the classifier matches exactly. On a case-sensitive
/// volume that disagreement is visible: `board.HTML` appeared in the picker and then resolved to
/// nothing when selected. Listing only what resolves is the version of this that is right on every
/// filesystem.
@Suite("Custom sidebar picker discovery casing")
@MainActor
struct CustomSidebarPickerDiscoveryCasingTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to directory: URL, as name: String) throws {
        try contents.write(
            to: directory.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    private func discoveredNames(in directory: URL) -> [String] {
        CmuxExtensionSidebarSelection.withCustomSidebarsDirectoryForTesting(directory) {
            CmuxExtensionSidebarSelection.customSidebarDescriptors.map { descriptor in
                String(descriptor.id.dropFirst(CmuxExtensionSidebarSelection.customSidebarProviderPrefix.count))
            }
        }
    }

    @Test("lowercase extensions are discovered")
    func lowercaseExtensionsAreDiscovered() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Text(\"a\")", to: dir, as: "alpha.swift")
        try write("{}", to: dir, as: "bravo.json")
        try write("<!doctype html>", to: dir, as: "charlie.html")
        try write("http://127.0.0.1:8787/", to: dir, as: "delta.url")

        #expect(discoveredNames(in: dir) == ["alpha", "bravo", "charlie", "delta"])
    }

    @Test(
        "an uppercase extension is not listed, because it would not resolve",
        arguments: ["board.HTML", "board.URL", "board.SWIFT", "board.Json"]
    )
    func uppercaseExtensionIsNotListed(fileName: String) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("<!doctype html>", to: dir, as: fileName)

        #expect(discoveredNames(in: dir).isEmpty)
        #expect(
            CmuxExtensionSidebarSelection.customSidebarFileURL(
                forName: "board",
                sidebarsDirectory: dir
            ) == nil
        )
    }

    // The two halves agreeing is the actual requirement: everything listed must resolve.
    @Test("every discovered name resolves to a file")
    func discoveryAndResolutionAgree() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Text(\"a\")", to: dir, as: "alpha.swift")
        try write("<!doctype html>", to: dir, as: "bravo.HTML")
        try write("<!doctype html>", to: dir, as: "charlie.html")
        try write("nope", to: dir, as: "delta.txt")

        for name in discoveredNames(in: dir) {
            #expect(
                CmuxExtensionSidebarSelection.customSidebarFileURL(
                    forName: name,
                    sidebarsDirectory: dir
                ) != nil,
                "\(name) was listed but does not resolve"
            )
        }
        #expect(discoveredNames(in: dir) == ["alpha", "charlie"])
    }

    // An uppercase file must not shadow the lowercase one that does resolve.
    @Test("an uppercase file does not displace its lowercase sibling")
    func uppercaseDoesNotShadowLowercase() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("<!doctype html>", to: dir, as: "board.HTML")
        try write("Text(\"a\")", to: dir, as: "board.swift")

        #expect(discoveredNames(in: dir) == ["board"])
        #expect(
            CmuxExtensionSidebarSelection.customSidebarFileURL(
                forName: "board",
                sidebarsDirectory: dir
            )?.lastPathComponent == "board.swift"
        )
    }
}
