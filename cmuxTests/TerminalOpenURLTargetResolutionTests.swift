import Foundation
import Testing
import CmuxSettings
import CmuxTerminalCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct TerminalOpenURLTargetResolutionTests {
    @Test func resolvesHTTPSAsEmbeddedBrowser() throws {
        let target = try #require(TerminalBrowserHostNormalizer().resolveOpenURLTarget("https://example.com/path?q=1"))
        guard case let .embeddedBrowser(url) = target else {
            Issue.record("Expected web URL to route to embedded browser")
            return
        }
        #expect(url.scheme == "https")
        #expect(url.host == "example.com")
        #expect(url.path == "/path")
    }

    @Test func resolvesBareDomainAsEmbeddedBrowser() throws {
        let target = try #require(TerminalBrowserHostNormalizer().resolveOpenURLTarget("example.com/docs"))
        guard case let .embeddedBrowser(url) = target else {
            Issue.record("Expected bare domain to be normalized as an HTTPS browser URL")
            return
        }
        #expect(url.scheme == "https")
        #expect(url.host == "example.com")
        #expect(url.path == "/docs")
    }

    @Test func resolvesSingleLabelHostAsEmbeddedBrowser() throws {
        let target = try #require(TerminalBrowserHostNormalizer().resolveOpenURLTarget("go/docs"))
        guard case let .embeddedBrowser(url) = target else {
            Issue.record("Expected a single-label internal host to remain browser-routable")
            return
        }
        #expect(url.host == "go")
        #expect(url.path == "/docs")
    }

    @MainActor
    @Test func locationCapableEditorBypassesPreviewButPlainOpenerDoesNot() throws {
        let suiteName = "cmux-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "openSupportedFilesInCmux")

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-location-routing-\(UUID().uuidString).swift")
        try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let resolution = TerminalPathResolution(path: fileURL.path, line: 1, column: 5)
        let routeSettings = FileRouteSettingsStore(defaults: defaults)

        let locationRouter = CommandClickFileOpenRouter(
            routeSettings: routeSettings,
            supportsExternalLocations: { true },
            openExternal: { _, _, _ in }
        )
        #expect(!locationRouter.shouldRouteInCmux(resolution: resolution))

        let plainRouter = CommandClickFileOpenRouter(
            routeSettings: routeSettings,
            supportsExternalLocations: { false },
            openExternal: { _, _, _ in }
        )
        #expect(plainRouter.shouldRouteInCmux(resolution: resolution))
    }

    @Test func resolvesFileSchemeAsExternal() throws {
        let target = try #require(TerminalBrowserHostNormalizer().resolveOpenURLTarget("file:///tmp/cmux.txt"))
        guard case let .external(url) = target else {
            Issue.record("Expected file URL to open externally")
            return
        }
        #expect(url.isFileURL)
        #expect(url.path == "/tmp/cmux.txt")
    }

    @Test func resolvesAbsolutePathAsExternalFileURL() throws {
        let target = try #require(TerminalBrowserHostNormalizer().resolveOpenURLTarget("/tmp/cmux-path.txt"))
        guard case let .external(url) = target else {
            Issue.record("Expected absolute file path to open externally")
            return
        }
        #expect(url.isFileURL)
        #expect(url.path == "/tmp/cmux-path.txt")
    }

    @Test func resolvesNonWebSchemeAsExternal() throws {
        let target = try #require(TerminalBrowserHostNormalizer().resolveOpenURLTarget("mailto:test@example.com"))
        guard case let .external(url) = target else {
            Issue.record("Expected non-web scheme to open externally")
            return
        }
        #expect(url.scheme == "mailto")
    }

    @Test func resolvesHostlessHTTPSAsExternal() throws {
        let target = try #require(TerminalBrowserHostNormalizer().resolveOpenURLTarget("https:///tmp/cmux.txt"))
        guard case let .external(url) = target else {
            Issue.record("Expected hostless HTTPS URL to open externally")
            return
        }
        #expect(url.scheme == "https")
        #expect(url.host == nil)
        #expect(url.path == "/tmp/cmux.txt")
    }
}
