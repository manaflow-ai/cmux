import XCTest
import CMUXAgentLaunch
import CmuxExtensionKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxEventBusPluginTests: XCTestCase {
    func testCompletedWorkstreamPhaseDoesNotDuplicatePluginLifecycleEvent() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let event = WorkstreamEvent(
            sessionId: "session",
            hookEventName: .postToolUse,
            source: "codex",
            workspaceId: "workspace",
            surfaceId: "surface"
        )

        bus.publishWorkstreamEvent(event, phase: "received")
        bus.publishWorkstreamEvent(event, phase: "completed")

        let names = bus.retainedSnapshot().compactMap { $0["name"] as? String }
        XCTAssertEqual(names.filter { $0 == "agent.session.state_changed" }.count, 1)
        XCTAssertEqual(names, [
            "agent.session.state_changed",
            "agent.hook.PostToolUse",
            "feed.item.received",
            "agent.hook.PostToolUse",
            "feed.item.completed",
        ])
    }

    func testRevokedPluginProcessIdentityRemainsClassifiedAsDenied() {
        let processID = pid_t(42)
        let pluginID = "dev.example.plugin"
        let resolver = CmuxPluginProcessAuthorizationResolver(
            parentProcessLookup: { _ in nil }
        )

        XCTAssertEqual(
            resolver.resolve(
                processID: processID,
                authorizations: [processID: .active(pluginID: pluginID)]
            )?.authorization,
            .active(pluginID: pluginID)
        )
        XCTAssertEqual(
            resolver.resolve(
                processID: processID,
                authorizations: [processID: .revoked]
            )?.authorization,
            .revoked
        )
        XCTAssertEqual(
            CmuxPluginRuntime.socketPeerPolicy(
                processAuthorization: .revoked,
                isEventStreamRequest: true
            ),
            .denied
        )
        XCTAssertEqual(
            CmuxPluginRuntime.socketPeerPolicy(
                processAuthorization: .active(pluginID: pluginID),
                isEventStreamRequest: false
            ),
            .denied
        )
        XCTAssertEqual(
            CmuxPluginRuntime.socketPeerPolicy(
                processAuthorization: .active(pluginID: pluginID),
                isEventStreamRequest: true
            ),
            .pluginEventStream
        )
    }

    func testEventSubscriptionDeliveryFilterScopesReplayBeforeQueueing() {
        let bus = CmuxEventBus(retainedEventLimit: 4)
        for pluginID in ["dev.example.one", "dev.example.two"] {
            bus.publish(
                name: "plugin.action.invoked",
                category: "plugin",
                source: "test",
                payload: ["plugin_id": pluginID]
            )
        }

        let snapshot = bus.subscribe(
            afterSequence: 0,
            names: ["plugin.action.invoked"],
            categories: [],
            deliveryFilter: { event in
                let payload = event["payload"] as? [String: Any]
                return payload?["plugin_id"] as? String == "dev.example.one"
            }
        )

        XCTAssertEqual(snapshot.replay.count, 1)
        XCTAssertEqual(snapshot.ack["replay_count"] as? Int, 1)
        let payload = snapshot.replay.first?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["plugin_id"] as? String, "dev.example.one")

        defer { bus.unsubscribe(snapshot.subscription) }
        for pluginID in ["dev.example.one", "dev.example.two"] {
            bus.publish(
                name: "plugin.action.invoked",
                category: "plugin",
                source: "test",
                payload: ["plugin_id": pluginID]
            )
        }
        let liveEvent = snapshot.subscription.next(timeout: 0.1)
        let livePayload = liveEvent?["payload"] as? [String: Any]
        XCTAssertEqual(livePayload?["plugin_id"] as? String, "dev.example.one")
        XCTAssertNil(snapshot.subscription.next(timeout: 0.01))
    }
}
