import CMUXAgentLaunch
import CmuxControlSocket
import Foundation
import ObjectiveC
import Testing
import os

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Counts the `ISO8601DateFormatter` objects created on the main thread between
/// `init` and `remove()`. Creating one opens an ICU formatter, which is the cost
/// #45401 measured, so the count is the thing to keep flat.
private final class MainThreadISO8601FormatterCreationCounter: Sendable {
    private typealias Initializer = @convention(c) (Unmanaged<AnyObject>, Selector) -> Unmanaged<AnyObject>?

    private let created = OSAllocatedUnfairLock(initialState: 0)
    private nonisolated(unsafe) let method: Method
    private nonisolated(unsafe) let original: IMP

    var count: Int { created.withLock { $0 } }

    init?() {
        let selector = #selector(NSObject.init)
        // Only swap an `init` the class defines itself. An inherited one belongs
        // to every other formatter in the test host.
        guard let method = class_getInstanceMethod(ISO8601DateFormatter.self, selector),
              method != class_getInstanceMethod(class_getSuperclass(ISO8601DateFormatter.self), selector)
        else { return nil }
        self.method = method
        let original = method_getImplementation(method)
        self.original = original
        let created = created
        let replacement: @convention(block) (Unmanaged<AnyObject>) -> Unmanaged<AnyObject>? = { formatter in
            if Thread.isMainThread {
                created.withLock { $0 += 1 }
            }
            return unsafeBitCast(original, to: Initializer.self)(formatter, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    func remove() {
        method_setImplementation(method, original)
    }
}

extension FeedCoordinatorTests {
    /// #45401: `feed.list` answers on the main thread and created a date
    /// formatter for every item, so listing a full Feed stalled the UI.
    @MainActor
    @Test func feedListCreatesOneDateFormatterForTheWholeList() throws {
        let store = WorkstreamStore(ringCapacity: 100)
        for index in 0..<40 {
            store.ingest(WorkstreamEvent(
                sessionId: "feed-list-date-formatter-\(index)",
                hookEventName: .postToolUse,
                source: "claude",
                toolName: "Bash",
                receivedAt: Date(timeIntervalSince1970: 1_763_388_498 + Double(index) * 61)
            ))
        }
        FeedCoordinator.shared.install(store: store)
        let expectedFormatter = ISO8601DateFormatter()
        let expectedCreatedAt = store.items.map { expectedFormatter.string(from: $0.createdAt) }
        #expect(expectedCreatedAt.first == "2025-11-17T14:08:18Z")

        let counter = try #require(MainThreadISO8601FormatterCreationCounter())
        defer { counter.remove() }
        // The counter has to see a formatter being created, or a count of zero
        // below would pass without proving anything.
        _ = ISO8601DateFormatter()
        #expect(counter.count == 1)

        let items = TerminalController.shared.controlFeedSnapshotItems(pendingOnly: false)

        #expect(counter.count - 1 <= 1)
        let createdAt = items.map { item -> String? in
            guard case .object(let fields) = item, case .string(let value)? = fields["created_at"] else {
                return nil
            }
            return value
        }
        #expect(createdAt == expectedCreatedAt)
    }
}
