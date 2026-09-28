import CmuxFoundation
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `emptyPane.artFile` reaches the defaults the empty pane observes, and the
/// loader turns the file into art or falls back to the default view.
@Suite("Empty pane art settings", .serialized)
struct EmptyPaneArtSettingsTests {
    private let artFileKey = EmptyPaneCatalogSection().artFile.userDefaultsKey

    @Test func settingsFileStoreAppliesArtFilePath() throws {
        try withSettingsFile(#"{ "emptyPane": { "artFile": "~/.config/cmux/empty-pane.ans" } }"#) { defaults in
            #expect(defaults.string(forKey: artFileKey) == "~/.config/cmux/empty-pane.ans")
        }
        #expect(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("emptyPane.artFile"))
    }

    @Test func settingsFileStoreIgnoresNonStringArtFile() throws {
        try withSettingsFile(#"{ "emptyPane": { "artFile": 42 } }"#) { defaults in
            #expect(defaults.object(forKey: artFileKey) == nil)
        }
    }

    @Test func loaderParsesColoredArtAndFollowsSymlinks() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("art.ans")
        try "\u{1B}[31m/\\_/\\\u{1B}[0m\n( o.o )\n".write(to: file, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent("linked.ans")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let loader = EmptyPaneArtLoader()
        let art = try #require(loader.art(atPath: "  \(file.path)\n"))
        #expect(art.lines.map(\.text) == ["/\\_/\\", "( o.o )"])
        #expect(art.lines[0].runs.first?.style.foreground == .indexed(1))
        #expect(loader.art(atPath: link.path) == art)
    }

    @Test func loaderFallsBackForUnusableFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blank = directory.appendingPathComponent("blank.txt")
        try " \n\n".write(to: blank, atomically: true, encoding: .utf8)
        let oversized = directory.appendingPathComponent("big.txt")
        try Data(repeating: 0x41, count: ANSIArtParser.defaultMaxBytes + 1).write(to: oversized)

        let loader = EmptyPaneArtLoader()
        #expect(loader.art(atPath: "") == nil)
        #expect(loader.art(atPath: directory.appendingPathComponent("missing.ans").path) == nil)
        #expect(loader.art(atPath: directory.path) == nil)
        #expect(loader.art(atPath: blank.path) == nil)
        #expect(loader.art(atPath: oversized.path) == nil)
    }

    private func withSettingsFile(_ json: String, verify: (UserDefaults) throws -> Void) throws {
        let suiteName = "cmux-empty-pane-art-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsFile = directory.appendingPathComponent("cmux.json")
        try json.write(to: settingsFile, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFile.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            notificationCenter: NotificationCenter(),
            userDefaults: defaults,
            startWatching: false,
            isUserDefaultsKeyForcedByProfile: { _ in false }
        )
        #expect(store.activeSourcePath == settingsFile.path)
        try verify(defaults)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-empty-pane-art-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
