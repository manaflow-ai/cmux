import Foundation

/// The result of requesting one bounded page of normal-screen tmux history.
///
/// Rows are ordered oldest-to-newest within the page and have no line
/// terminator. `beforeRow` is the cursor used for this page: `nil` means the
/// newest page, while a value means the page ends immediately before that
/// absolute row. The host owns the cursor space; the phone only requires
/// that adjacent pages meet exactly at a row boundary.
public struct SSHTmuxHistoryPage: Hashable, Sendable {
    public static let maximumRows = 256
    public static let maximumRowBytes = 64 * 1024

    public let server: SSHTmuxServerEpoch
    public let windowID: String
    public let paneID: String
    public let beforeRow: UInt64?
    public let oldestRow: UInt64
    public let rows: [Data]
    public let hasMore: Bool

    /// A page is accepted only when its ids and row arithmetic are safe to
    /// use as a parser-history boundary. Empty pages are terminal pages.
    public init?(
        server: SSHTmuxServerEpoch,
        windowID: String,
        paneID: String,
        beforeRow: UInt64?,
        oldestRow: UInt64,
        rows: [Data],
        hasMore: Bool
    ) {
        guard SSHTmuxWindow.isValidID(windowID, prefix: "@"),
              SSHTmuxWindow.isValidID(paneID, prefix: "%"),
              rows.count <= Self.maximumRows,
              rows.allSatisfy({ $0.count <= Self.maximumRowBytes }) else { return nil }

        if rows.isEmpty {
            guard !hasMore else { return nil }
        } else {
            let (end, overflow) = oldestRow.addingReportingOverflow(UInt64(rows.count))
            guard !overflow else { return nil }
            if let beforeRow {
                guard end == beforeRow else { return nil }
            }
        }
        if hasMore {
            guard !rows.isEmpty else { return nil }
        }

        self.server = server
        self.windowID = windowID
        self.paneID = paneID
        self.beforeRow = beforeRow
        self.oldestRow = oldestRow
        self.rows = rows
        self.hasMore = hasMore
    }

    /// The cursor to use for the next older page, if one exists.
    public var nextBeforeRow: UInt64? {
        hasMore ? oldestRow : nil
    }
}

/// A bounded, deterministic history-page assembler for a single tmux pane.
///
/// This value performs no SSH or tmux I/O. It gives a future renderer owner a
/// safe way to request older rows without mixing server generations, panes,
/// overlapping pages, or unbounded host output into parser state.
public struct SSHTmuxHistoryBuffer: Hashable, Sendable {
    public static let maximumRows = 4_096

    public enum Error: Swift.Error, Equatable, Sendable {
        case staleServer
        case wrongTarget
        case cursorDiscontinuity
        case historyFinished
        case tooManyRows
    }

    public let server: SSHTmuxServerEpoch
    public let windowID: String
    public let paneID: String
    private(set) public var rows: [Data] = []
    private(set) public var nextBeforeRow: UInt64?
    private var receivedPage = false

    public init(server: SSHTmuxServerEpoch, windowID: String, paneID: String) {
        self.server = server
        self.windowID = windowID
        self.paneID = paneID
        self.nextBeforeRow = nil
    }

    /// True before the first request and after a terminal page. Callers can
    /// use ``request(limit:)`` to distinguish those states without guessing.
    public var isFinished: Bool { receivedPage && nextBeforeRow == nil }

    /// Builds the next request cursor. A nil result means no more pages are
    /// available, while the first request intentionally carries a nil cursor.
    public func request(limit: Int = SSHTmuxHistoryPage.maximumRows) -> SSHTmuxHistoryRequest? {
        guard !isFinished else { return nil }
        return SSHTmuxHistoryRequest(server: server, windowID: windowID, paneID: paneID,
                                     beforeRow: receivedPage ? nextBeforeRow : nil, limit: limit)
    }

    /// Prepends one older page after checking identity and exact cursor
    /// continuity. The returned rows are the complete oldest-to-newest view.
    @discardableResult
    public mutating func append(_ page: SSHTmuxHistoryPage) throws -> [Data] {
        guard page.server == server else { throw Error.staleServer }
        guard page.windowID == windowID, page.paneID == paneID else { throw Error.wrongTarget }
        guard !isFinished else { throw Error.historyFinished }

        if receivedPage {
            guard page.beforeRow == nextBeforeRow else { throw Error.cursorDiscontinuity }
        } else {
            guard page.beforeRow == nil else { throw Error.cursorDiscontinuity }
        }
        guard rows.count + page.rows.count <= Self.maximumRows else { throw Error.tooManyRows }
        rows = page.rows + rows
        nextBeforeRow = page.nextBeforeRow
        receivedPage = true
        return rows
    }
}

/// A bounded request for one older history page. The host adapter may map the
/// value to its own control-mode command or durable owner RPC.
public struct SSHTmuxHistoryRequest: Hashable, Sendable {
    public static let maximumLimit = SSHTmuxHistoryPage.maximumRows

    public let server: SSHTmuxServerEpoch
    public let windowID: String
    public let paneID: String
    public let beforeRow: UInt64?
    public let limit: Int

    public init?(
        server: SSHTmuxServerEpoch,
        windowID: String,
        paneID: String,
        beforeRow: UInt64?,
        limit: Int
    ) {
        guard SSHTmuxWindow.isValidID(windowID, prefix: "@"),
              SSHTmuxWindow.isValidID(paneID, prefix: "%"),
              (1...Self.maximumLimit).contains(limit) else { return nil }
        self.server = server
        self.windowID = windowID
        self.paneID = paneID
        self.beforeRow = beforeRow
        self.limit = limit
    }
}
