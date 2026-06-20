import Foundation
import Testing
import CmuxBrowser

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct OpenChatBrowserPanelTests {
    @Test func openChatLoopbackURLIsNotPersistedForSessionRestore() throws {
        let token = UUID().uuidString.lowercased()
        let url = try #require(URL(string: "http://127.0.0.1:49152/\(token)/chat.html#cmux-open-chat"))
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            renderInitialNavigation: false
        )

        #expect(panel.preferredURLStringForOmnibar() == url.absoluteString)
        #expect(panel.preferredURLStringForSessionSnapshot() == nil)
        #expect(!panel.shouldPersistSessionSnapshot())
        #expect(!panel.shouldRenderWebViewForSessionSnapshot())
    }

    @Test func arbitraryLocalhostURLWithOpenChatMarkerStillPersists() throws {
        let url = try #require(URL(string: "http://127.0.0.1:49152/app#cmux-open-chat"))
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            renderInitialNavigation: false
        )

        #expect(panel.preferredURLStringForSessionSnapshot() == url.absoluteString)
        #expect(panel.shouldPersistSessionSnapshot())
    }

    @Test func openChatLoopbackURLIsNotRecordedInBrowserHistory() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-open-chat-browser-history-\(UUID().uuidString).json")
        let store = BrowserHistoryStore(fileURL: fileURL)
        defer {
            store.clearHistory()
            try? FileManager.default.removeItem(at: fileURL)
        }

        let token = UUID().uuidString.lowercased()
        let openChatURL = try #require(URL(string: "http://127.0.0.1:49152/\(token)/chat.html#cmux-open-chat"))
        let normalURL = try #require(URL(string: "http://127.0.0.1:49152/app#cmux-open-chat"))

        store.recordVisit(url: openChatURL, title: "Chat")
        store.recordTypedNavigation(url: openChatURL)
        #expect(store.entries.isEmpty)

        store.recordVisit(url: normalURL, title: "Normal")
        #expect(store.entries.map(\.url) == [normalURL.absoluteString])
    }
}
