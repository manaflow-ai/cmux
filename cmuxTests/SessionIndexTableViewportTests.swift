import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SessionIndexTableViewportTests {
    @MainActor
    @Test
    func vaultUsesViewportBoundedAppKitRowsAtScale() throws {
        let defaults = SessionIndexDefaultsSnapshot()
        defer { defaults.restore() }

        let store = SessionIndexStore()
        store.grouping = .directory
        store.directoryOrder = []
        store.replaceEntriesForTesting(
            (0..<46).map { index in
                SessionEntry(
                    id: "claude:/tmp/vault-scale/session-\(index).jsonl",
                    agent: .claude,
                    sessionId: "session-\(index)",
                    title: "Synthetic session \(index)",
                    cwd: "/tmp/vault-scale/project-\(index)",
                    gitBranch: nil,
                    pullRequest: nil,
                    modified: Date(timeIntervalSince1970: TimeInterval(10_000 - index)),
                    fileURL: nil,
                    specifics: .claude(
                        model: nil,
                        permissionMode: nil,
                        configDirectoryForResume: nil
                    )
                )
            }
        )

        let host = NSHostingView(
            rootView: SessionIndexView(store: store, onResume: nil)
                .frame(width: 320, height: 300)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = window.contentView?.bounds ?? .zero
        host.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()

        let table = try #require(host.firstDescendant(of: NSTableView.self))
        let visibleRows = table.rows(in: table.visibleRect)
        let realizedRows = (0..<table.numberOfRows).filter { row in
            table.view(atColumn: 0, row: row, makeIfNecessary: false) != nil
        }

        #expect(table.numberOfRows >= 46)
        #expect(visibleRows.length > 0)
        #expect(table.numberOfRows > visibleRows.length)
        #expect(realizedRows.count <= visibleRows.length + 2)
    }
}

private struct SessionIndexDefaultsSnapshot {
    private let values: [(key: String, value: Any?)]

    init(defaults: UserDefaults = .standard) {
        values = Self.keys.map { key in (key, defaults.object(forKey: key)) }
    }

    func restore(defaults: UserDefaults = .standard) {
        for item in values {
            if let value = item.value {
                defaults.set(value, forKey: item.key)
            } else {
                defaults.removeObject(forKey: item.key)
            }
        }
    }

    private static let keys = [
        "sessionIndex.agentOrder",
        "sessionIndex.directoryOrder",
        "sessionIndex.grouping",
    ]
}

private extension NSView {
    func firstDescendant<ViewType: NSView>(of type: ViewType.Type) -> ViewType? {
        if let match = self as? ViewType {
            return match
        }
        for subview in subviews {
            if let match = subview.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}
