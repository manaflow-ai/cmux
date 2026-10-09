@testable import CmuxiOSSSHCore
import Foundation
import Testing

@Suite struct SSHTmuxHistoryTests {
    private let server = SSHTmuxServerEpoch(serverPID: 42, serverStart: 1_793_331_200)!

    @Test func pagesPrependOlderRowsAndAdvanceCursor() throws {
        var buffer = SSHTmuxHistoryBuffer(server: server, windowID: "@7", paneID: "%2")
        let firstRequest = try #require(buffer.request(limit: 2))
        #expect(firstRequest.beforeRow == nil)
        #expect(firstRequest.limit == 2)

        let newest = try #require(SSHTmuxHistoryPage(
            server: server, windowID: "@7", paneID: "%2", beforeRow: nil,
            oldestRow: 8, rows: [Data("eight".utf8), Data("nine".utf8)], hasMore: true))
        #expect(try buffer.append(newest) == [Data("eight".utf8), Data("nine".utf8)])
        #expect(buffer.request()?.beforeRow == 8)

        let older = try #require(SSHTmuxHistoryPage(
            server: server, windowID: "@7", paneID: "%2", beforeRow: 8,
            oldestRow: 6, rows: [Data("six".utf8), Data("seven".utf8)], hasMore: false))
        #expect(try buffer.append(older) == [Data("six".utf8), Data("seven".utf8), Data("eight".utf8), Data("nine".utf8)])
        #expect(buffer.isFinished)
        #expect(buffer.request() == nil)
    }

    @Test func staleAndOverlappingPagesFailClosed() throws {
        var buffer = SSHTmuxHistoryBuffer(server: server, windowID: "@7", paneID: "%2")
        let first = try #require(SSHTmuxHistoryPage(
            server: server, windowID: "@7", paneID: "%2", beforeRow: nil,
            oldestRow: 8, rows: [Data("eight".utf8)], hasMore: true))
        _ = try buffer.append(first)

        let wrongServer = try #require(SSHTmuxServerEpoch(serverPID: 43, serverStart: server.serverStart))
        let stale = try #require(SSHTmuxHistoryPage(
            server: wrongServer, windowID: "@7", paneID: "%2", beforeRow: 8,
            oldestRow: 7, rows: [Data("seven".utf8)], hasMore: false))
        #expect(throws: SSHTmuxHistoryBuffer.Error.staleServer) { try buffer.append(stale) }

        let overlap = try #require(SSHTmuxHistoryPage(
            server: server, windowID: "@7", paneID: "%2", beforeRow: 9,
            oldestRow: 8, rows: [Data("eight".utf8)], hasMore: false))
        #expect(throws: SSHTmuxHistoryBuffer.Error.cursorDiscontinuity) { try buffer.append(overlap) }
    }

    @Test func requestAndPageBoundsAreEnforced() {
        #expect(SSHTmuxHistoryRequest(server: server, windowID: "@7", paneID: "%2", beforeRow: nil, limit: 0) == nil)
        #expect(SSHTmuxHistoryRequest(server: server, windowID: "@7", paneID: "%2", beforeRow: nil, limit: SSHTmuxHistoryRequest.maximumLimit + 1) == nil)
        #expect(SSHTmuxHistoryPage(server: server, windowID: "@7", paneID: "%2", beforeRow: nil,
                                   oldestRow: 0, rows: [], hasMore: true) == nil)
        #expect(SSHTmuxHistoryPage(server: server, windowID: "@7", paneID: "%2", beforeRow: 0,
                                   oldestRow: 1, rows: [Data("wrong boundary".utf8)], hasMore: false) == nil)
        #expect(SSHTmuxHistoryPage(server: server, windowID: "@7", paneID: "%2", beforeRow: nil,
                                   oldestRow: 0, rows: [Data(repeating: 0, count: SSHTmuxHistoryPage.maximumRowBytes + 1)], hasMore: false) == nil)
    }

    @Test func pagePayloadAndRowBoundariesStayWithinTheControlBudget() {
        let fullRow = Data(repeating: 0x78, count: SSHTmuxHistoryPage.maximumRowBytes)
        let rowsAtLimit = Array(repeating: fullRow, count: SSHTmuxHistoryPage.maximumPageBytes / fullRow.count)
        #expect(SSHTmuxHistoryPage(server: server, windowID: "@7", paneID: "%2", beforeRow: nil,
                                   oldestRow: 0, rows: rowsAtLimit, hasMore: false) != nil)
        #expect(SSHTmuxHistoryPage(server: server, windowID: "@7", paneID: "%2", beforeRow: nil,
                                   oldestRow: 0, rows: rowsAtLimit + [Data("x".utf8)], hasMore: false) == nil)
        #expect(SSHTmuxHistoryPage(server: server, windowID: "@7", paneID: "%2", beforeRow: nil,
                                   oldestRow: 0, rows: [Data([0x6f, 0x0a, 0x6b])], hasMore: false) == nil)
    }

    @Test func pageIdentityAndRowLimitsRemainBounded() throws {
        let tooMany = Array(repeating: Data("x".utf8), count: SSHTmuxHistoryPage.maximumRows + 1)
        #expect(SSHTmuxHistoryPage(server: server, windowID: "@7", paneID: "%2", beforeRow: nil,
                                   oldestRow: 0, rows: tooMany, hasMore: false) == nil)

        var buffer = SSHTmuxHistoryBuffer(server: server, windowID: "@7", paneID: "%2")
        let page = try #require(SSHTmuxHistoryPage(server: server, windowID: "@7", paneID: "%2", beforeRow: nil,
                                                   oldestRow: 0, rows: [Data("x".utf8)], hasMore: false))
        _ = try buffer.append(page)
        #expect(throws: SSHTmuxHistoryBuffer.Error.historyFinished) { try buffer.append(page) }
    }
}
