import CmuxBrowserStream
import CmuxiOSBrowserCore
import CmuxiOSFeatureKit
import Foundation
import Testing

/// E1: page updates a consumer has not read never pile up. Each kind keeps
/// its newest value (page, page size, cursor, text focus, clipboard).
@Suite("page update back-pressure")
struct PageUpdatesBackPressureTests {
    @Test func unreadPageUpdatesKeepTheNewestOfEachKind() async throws {
        let h = try await BrowserHostHarness.make(cursorFlood: 3000)
        defer { Task { await h.shutdown() } }
        let session = try await h.source.open("tab_b1", on: HostID("h_mac1"))
        // Test-only settle: let the host's events reach the session unread.
        try await Task.sleep(for: .milliseconds(800))
        let pages = await session.pageUpdates()
        let counter = UpdateLog()
        let reader = Task {
            for await update in pages { await counter.append(update) }
        }
        defer { reader.cancel() }
        var last = -1
        while true {
            try await Task.sleep(for: .milliseconds(200))
            let now = await counter.updates.count
            if now == last { break }
            last = now
        }
        let updates = await counter.updates
        #expect(updates.count <= 5, "\(updates.count) page updates were queued for a consumer that read nothing")
        #expect(updates.contains(.pageSize(width: 1440, height: 900)))
        #expect(updates.contains(.textFocus(true)))
        #expect(updates.last(where: { if case .cursor = $0 { true } else { false } }) == .cursor("pointer"))
        await session.close()
    }
}

actor UpdateLog {
    private(set) var updates: [BrowserPageUpdate] = []
    func append(_ update: BrowserPageUpdate) { updates.append(update) }
}
