import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SurfaceSelectionEventContractTests: XCTestCase {
    private let topic = "surface.selection_changed"

    private final class Source {}

    @MainActor
    private func identity(surfaceId: UUID) -> SurfaceSelectionEventIdentity {
        SurfaceSelectionEventIdentity(
            workspaceId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            workspaceRef: "workspace:1",
            surfaceId: surfaceId,
            surfaceRef: "surface:1"
        )
    }

    private func nextEvent(
        from subscription: CmuxEventSubscription,
        timeout: TimeInterval
    ) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: subscription.next(timeout: timeout))
            }
        }
    }

    func testUnfilteredSubscriptionDoesNotReceiveOrRetainSelectionText() throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let subscription = bus.subscribe(afterSequence: nil, names: [], categories: [])
        defer { bus.unsubscribe(subscription.subscription) }

        bus.publish(
            name: topic,
            category: "surface",
            source: "test",
            payload: ["text": "private selection"]
        )

        XCTAssertNil(subscription.subscription.next(timeout: 0.05))
        XCTAssertTrue(bus.retainedSnapshot().isEmpty)
        XCTAssertEqual(bus.latestSequence, 0)
    }

    func testCategoryOnlySubscriptionDoesNotOptIntoSelectionText() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let subscription = bus.subscribe(afterSequence: nil, names: [], categories: ["surface"])
        defer { bus.unsubscribe(subscription.subscription) }

        bus.publish(
            name: topic,
            category: "surface",
            source: "test",
            payload: ["text": "private selection"]
        )

        XCTAssertNil(subscription.subscription.next(timeout: 0.05))
        XCTAssertTrue(bus.retainedSnapshot().isEmpty)
    }

    func testExactNameSubscriptionOptsIntoSelectionText() throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let subscription = bus.subscribe(afterSequence: nil, names: [topic], categories: [])
        defer { bus.unsubscribe(subscription.subscription) }

        bus.publish(
            name: topic,
            category: "surface",
            source: "test",
            workspaceId: "workspace",
            surfaceId: "surface",
            payload: ["text": "private selection"]
        )

        let event = try XCTUnwrap(subscription.subscription.next(timeout: 0.2))
        XCTAssertEqual(event["name"] as? String, topic)
        XCTAssertEqual((event["payload"] as? [String: Any])?["text"] as? String, "private selection")
        XCTAssertEqual(bus.retainedSnapshot().count, 1)
    }

    @MainActor
    func testPublisherDebouncesAndCoalescesPerSurface() async throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let subscription = bus.subscribe(afterSequence: nil, names: [topic], categories: [])
        defer { bus.unsubscribe(subscription.subscription) }
        let publisher = SurfaceSelectionChangeEventPublisher(
            bus: bus,
            debounceNanoseconds: 5_000_000
        )
        let surfaceId = UUID()
        let source = Source()
        publisher.registerSnapshotSource(
            surfaceId: surfaceId,
            sourceIdentity: ObjectIdentifier(source),
            owner: source,
            identity: { self.identity(surfaceId: surfaceId) }
        )

        publisher.signal(
            surfaceId: surfaceId,
            snapshot: .selected(kind: "terminal", text: "first")
        )
        publisher.signal(
            surfaceId: surfaceId,
            snapshot: .selected(kind: "terminal", text: "latest")
        )

        let next = await nextEvent(from: subscription.subscription, timeout: 1.0)
        let event = try XCTUnwrap(next)
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(payload["text"] as? String, "latest")
        let extra = await nextEvent(from: subscription.subscription, timeout: 0.05)
        XCTAssertNil(extra)
    }

    @MainActor
    func testPublisherTeardownCancelsPendingEmission() async throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let subscription = bus.subscribe(afterSequence: nil, names: [topic], categories: [])
        defer { bus.unsubscribe(subscription.subscription) }
        let publisher = SurfaceSelectionChangeEventPublisher(
            bus: bus,
            debounceNanoseconds: 20_000_000
        )
        let surfaceId = UUID()
        let source = Source()
        publisher.registerSnapshotSource(
            surfaceId: surfaceId,
            sourceIdentity: ObjectIdentifier(source),
            owner: source,
            identity: { self.identity(surfaceId: surfaceId) }
        )
        publisher.signal(
            surfaceId: surfaceId,
            snapshot: .selected(kind: "browser", text: "stale")
        )
        publisher.unregister(surfaceId: surfaceId)

        XCTAssertTrue(bus.retainedSnapshot().isEmpty)
        let next = await nextEvent(from: subscription.subscription, timeout: 0.05)
        XCTAssertNil(next)
    }

    @MainActor
    func testPublisherCanReattachSourceAfterTransferTeardown() async throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let subscription = bus.subscribe(afterSequence: nil, names: [topic], categories: [])
        defer { bus.unsubscribe(subscription.subscription) }
        let publisher = SurfaceSelectionChangeEventPublisher(
            bus: bus,
            debounceNanoseconds: 5_000_000
        )
        let surfaceId = UUID()
        let source = Source()
        publisher.registerSnapshotSource(
            surfaceId: surfaceId,
            sourceIdentity: ObjectIdentifier(source),
            owner: source,
            identity: { self.identity(surfaceId: surfaceId) }
        )
        publisher.unregister(surfaceId: surfaceId)
        publisher.registerSnapshotSource(
            surfaceId: surfaceId,
            sourceIdentity: ObjectIdentifier(source),
            owner: source,
            identity: { self.identity(surfaceId: surfaceId) }
        )
        publisher.signal(
            surfaceId: surfaceId,
            snapshot: .selected(kind: "terminal", text: "after-transfer")
        )

        let next = await nextEvent(from: subscription.subscription, timeout: 1.0)
        let event = try XCTUnwrap(next)
        XCTAssertEqual(
            (event["payload"] as? [String: Any])?["text"] as? String,
            "after-transfer"
        )
    }

    @MainActor
    func testWebBridgeSuppressesPasswordSelectionAndPreservesShape() throws {
        let password = try XCTUnwrap(
            SurfaceSelectionWebBridge.snapshot(
                from: ["has_selection": true, "password": true, "text": "secret"],
                kind: "browser",
                url: "https://example.test"
            )
        )
        XCTAssertFalse(password.hasSelection)
        XCTAssertEqual(password.text, "")
        XCTAssertEqual(password.url, "https://example.test")

        let selected = try XCTUnwrap(
            SurfaceSelectionWebBridge.snapshot(
                from: ["has_selection": true, "text": "hello"],
                kind: "markdown",
                filePath: "/tmp/readme.md"
            )
        )
        XCTAssertTrue(selected.hasSelection)
        XCTAssertEqual(selected.text, "hello")
        XCTAssertEqual(selected.filePath, "/tmp/readme.md")
        XCTAssertTrue(SurfaceSelectionWebBridge.bootstrapScript.contains("selectionchange"))
        XCTAssertTrue(SurfaceSelectionWebBridge.bootstrapScript.contains("password"))
        XCTAssertTrue(SurfaceSelectionWebBridge.bootstrapScript.contains("lifecycle: 'document'"))
    }

    func testSupportedOwnerSnapshotsUseCommonFields() throws {
        let identity = SurfaceSelectionEventIdentity(
            workspaceId: UUID(),
            workspaceRef: "workspace:1",
            surfaceId: UUID(),
            surfaceRef: "surface:1"
        )
        for kind in ["terminal", "filepreview", "markdown", "browser"] {
            let snapshot = SurfaceSelectionEventSnapshot.selected(kind: kind, text: "context")
            let payload = snapshot.payload(identity: identity)
            XCTAssertEqual(payload["kind"] as? String, kind)
            XCTAssertEqual(payload["has_selection"] as? Bool, true)
            XCTAssertEqual(payload["text"] as? String, "context")
            XCTAssertEqual(payload["workspace_ref"] as? String, "workspace:1")
            XCTAssertEqual(payload["surface_ref"] as? String, "surface:1")
        }

        let contextual = SurfaceSelectionEventSnapshot.selected(
            kind: "filepreview",
            text: "line two",
            filePath: "/tmp/example.txt",
            lineRange: 2...2,
            url: "file:///tmp/example.txt"
        )
        let contextualPayload = contextual.payload(identity: identity)
        XCTAssertEqual(contextualPayload["file_path"] as? String, "/tmp/example.txt")
        XCTAssertEqual(contextualPayload["line_range"] as? [String: Int], ["start": 2, "end": 2])
        XCTAssertEqual(contextualPayload["url"] as? String, "file:///tmp/example.txt")
    }
}
