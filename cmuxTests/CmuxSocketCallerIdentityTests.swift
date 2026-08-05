import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for socket caller attribution
/// (https://github.com/manaflow-ai/cmux/issues/9611). Every test publishes
/// through the real `CmuxSocketEventMapper` and reads the event the bus actually
/// emitted, so the assertions cover the wire shape a consumer of `events.stream`
/// or `~/.cmuxterm/events.jsonl` sees.
@Suite(.serialized)
struct CmuxSocketCallerIdentityTests {
    private static let sendTextCommand =
        #"{"id":1,"method":"surface.send_text","params":{"surface_id":"s-1","text":"deploy prod"}}"#
    private static let sendTextResponse =
        #"{"id":1,"ok":true,"result":{"surface_id":"s-1"}}"#

    private func callerObject(of event: [String: Any]) -> [String: Any]? {
        event["caller"] as? [String: Any]
    }

    @Test
    func sendTextEventCarriesResolvedCallerIdentity() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let identity = CmuxSocketCallerIdentity(
            pid: 4242,
            processName: "cmux",
            surfaceId: "11111111-1111-1111-1111-111111111111"
        )
        CmuxSocketEventMapper.publish(
            command: Self.sendTextCommand,
            response: Self.sendTextResponse,
            caller: { identity }
        )

        let events = CmuxEventBus.shared.retainedSnapshot()
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event["name"] as? String == "surface.input_sent")
        #expect(event["source"] as? String == "socket.v2")

        let caller = try #require(callerObject(of: event))
        #expect((caller["pid"] as? NSNumber)?.int32Value == 4242)
        #expect(caller["process_name"] as? String == "cmux")
        #expect(caller["surface_id"] as? String == "11111111-1111-1111-1111-111111111111")
    }

    /// The gap the issue is about: `cmux send` must be distinguishable from
    /// human typing, and the transport alone cannot do that.
    @Test
    func callerIdentityIsIndependentOfTheTransportField() {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        CmuxSocketEventMapper.publish(
            command: Self.sendTextCommand,
            response: Self.sendTextResponse,
            caller: { CmuxSocketCallerIdentity(pid: 1, processName: "cmux", surfaceId: nil) }
        )
        CmuxSocketEventMapper.publish(
            command: Self.sendTextCommand,
            response: Self.sendTextResponse,
            caller: { CmuxSocketCallerIdentity(pid: 2, processName: "codex", surfaceId: nil) }
        )

        let events = CmuxEventBus.shared.retainedSnapshot()
        #expect(events.compactMap { $0["source"] as? String } == ["socket.v2", "socket.v2"])
        #expect(events.compactMap { callerObject(of: $0)?["process_name"] as? String }
            == ["cmux", "codex"])
    }

    /// A failed lookup must serialize as JSON `null`: present so a reader knows
    /// attribution was attempted, empty so nothing is fabricated.
    @Test
    func unresolvedCallerFieldsAreNullNotAbsent() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        CmuxSocketEventMapper.publish(
            command: Self.sendTextCommand,
            response: Self.sendTextResponse,
            caller: { .unknown }
        )

        let event = try #require(CmuxEventBus.shared.retainedSnapshot().first)
        let caller = try #require(callerObject(of: event))
        #expect(caller.keys.sorted() == ["pid", "process_name", "surface_id"])
        #expect(caller["pid"] is NSNull)
        #expect(caller["process_name"] is NSNull)
        #expect(caller["surface_id"] is NSNull)

        // The wire form, not just the dictionary: absent keys and `null` are the
        // same in Swift dictionaries but not to a JSON consumer.
        let line = try #require(CmuxEventBus.encodeLine(event))
        #expect(line.contains(#""pid":null"#))
        #expect(line.contains(#""process_name":null"#))
        #expect(line.contains(#""surface_id":null"#))
    }

    /// A pid that is not a live process must yield nil, never a guess.
    @Test
    func processNameLookupForADeadPidReturnsNil() {
        CmuxSocketCallerResolver.resetCacheForTesting()
        defer { CmuxSocketCallerResolver.resetCacheForTesting() }

        // Above the default `kern.maxproc` pid ceiling, so no live process owns it.
        #expect(CmuxSocketCallerResolver.processName(pid: 9_999_999) == nil)
        #expect(CmuxSocketCallerResolver.processName(pid: 0) == nil)
        #expect(CmuxSocketCallerResolver.processName(pid: -1) == nil)
        // A failed lookup must not be cached as a fabricated entry.
        #expect(CmuxSocketCallerResolver.cachedProcessNameCountForTesting == 0)
    }

    /// End to end through the real resolver: this test process is a live pid, so
    /// the name comes from `proc_pidpath` and is stable across repeat lookups.
    @Test
    func processNameResolvesLivePidAndCachesIt() throws {
        CmuxSocketCallerResolver.resetCacheForTesting()
        defer { CmuxSocketCallerResolver.resetCacheForTesting() }

        let selfPid = getpid()
        let name = try #require(CmuxSocketCallerResolver.processName(pid: selfPid))
        #expect(!name.isEmpty)
        #expect(!name.contains("/"))
        #expect(CmuxSocketCallerResolver.cachedProcessNameCountForTesting == 1)
        #expect(CmuxSocketCallerResolver.processName(pid: selfPid) == name)
        #expect(CmuxSocketCallerResolver.cachedProcessNameCountForTesting == 1)
    }

    /// A dead pid mixed into an otherwise resolvable identity must null exactly
    /// that field and still emit the event.
    @Test
    func partiallyResolvedIdentityNullsOnlyTheMissingField() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let identity = CmuxSocketCallerIdentity(
            pid: 9_999_999,
            processName: CmuxSocketCallerResolver.processName(pid: 9_999_999),
            surfaceId: nil
        )
        CmuxSocketEventMapper.publish(
            command: Self.sendTextCommand,
            response: Self.sendTextResponse,
            caller: { identity }
        )

        let event = try #require(CmuxEventBus.shared.retainedSnapshot().first)
        let caller = try #require(callerObject(of: event))
        #expect((caller["pid"] as? NSNumber)?.int32Value == 9_999_999)
        #expect(caller["process_name"] is NSNull)
        #expect(caller["surface_id"] is NSNull)
    }

    /// Attribution is not limited to `surface.input_sent`.
    @Test
    func v2SidebarAndNotificationEventsAlsoCarryTheCaller() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let identity = CmuxSocketCallerIdentity(pid: 77, processName: "bash", surfaceId: nil)
        let commands = [
            (
                #"{"id":1,"method":"surface.send_key","params":{"surface_id":"s-1","key":"ctrl-c"}}"#,
                #"{"id":1,"ok":true,"result":{"surface_id":"s-1"}}"#
            ),
            (
                #"{"id":2,"method":"notification.create","params":{"title":"done","body":"secret"}}"#,
                #"{"id":2,"ok":true,"result":{}}"#
            ),
            (
                #"{"id":3,"method":"pane.swap","params":{"pane_id":"p-1"}}"#,
                #"{"id":3,"ok":true,"result":{"pane_id":"p-1"}}"#
            ),
        ]
        for (command, response) in commands {
            CmuxSocketEventMapper.publish(command: command, response: response, caller: { identity })
        }

        let events = CmuxEventBus.shared.retainedSnapshot()
        #expect(events.compactMap { $0["name"] as? String } == [
            "surface.key_sent",
            "notification.requested",
            "pane.swapped",
        ])
        for event in events {
            let caller = try #require(callerObject(of: event))
            #expect((caller["pid"] as? NSNumber)?.int32Value == 77)
            #expect(caller["process_name"] as? String == "bash")
        }
    }

    /// v1 socket commands are attributed the same way as v2.
    @Test
    func v1EventsCarryTheCaller() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let identity = CmuxSocketCallerIdentity(
            pid: 31337,
            processName: "cmux",
            surfaceId: "22222222-2222-2222-2222-222222222222"
        )
        CmuxSocketEventMapper.publish(
            command: "send hello world",
            response: "OK",
            caller: { identity }
        )
        CmuxSocketEventMapper.publish(
            command: "set_progress 0.5",
            response: "OK",
            caller: { identity }
        )

        let events = CmuxEventBus.shared.retainedSnapshot()
        #expect(events.compactMap { $0["name"] as? String } == [
            "surface.input_sent",
            "sidebar.progress.updated",
        ])
        for event in events {
            #expect(event["source"] as? String == "socket.v1")
            let caller = try #require(callerObject(of: event))
            #expect((caller["pid"] as? NSNumber)?.int32Value == 31337)
            #expect(caller["process_name"] as? String == "cmux")
            #expect(caller["surface_id"] as? String == "22222222-2222-2222-2222-222222222222")
        }
    }

    /// Resolving the caller is the expensive part, so it must not run for
    /// commands that map to no event, and must run once for those that do.
    @Test
    func callerIsResolvedOnlyWhenAnEventIsPublished() {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        final class Counter: @unchecked Sendable {
            var count = 0
        }
        let counter = Counter()
        let provider: () -> CmuxSocketCallerIdentity = {
            counter.count += 1
            return CmuxSocketCallerIdentity(pid: 5, processName: "cmux", surfaceId: nil)
        }

        // Unmapped v2 method, unmapped v1 command, and a failed command.
        CmuxSocketEventMapper.publish(
            command: #"{"id":1,"method":"surface.list","params":{}}"#,
            response: #"{"id":1,"ok":true,"result":{}}"#,
            caller: provider
        )
        CmuxSocketEventMapper.publish(command: "list_workspaces", response: "OK", caller: provider)
        CmuxSocketEventMapper.publish(
            command: Self.sendTextCommand,
            response: #"{"id":1,"ok":false,"error":{"message":"nope"}}"#,
            caller: provider
        )
        #expect(counter.count == 0)
        #expect(CmuxEventBus.shared.retainedSnapshot().isEmpty)

        CmuxSocketEventMapper.publish(
            command: Self.sendTextCommand,
            response: Self.sendTextResponse,
            caller: provider
        )
        #expect(counter.count == 1)
        #expect(CmuxEventBus.shared.retainedSnapshot().count == 1)
    }

    /// Redaction policy (https://github.com/manaflow-ai/cmux/issues/9611):
    /// free-form injected text is redacted to a length; the bounded named-key
    /// vocabulary is recorded, and says so with an empty `redacted_fields`.
    @Test
    func sendTextAndSendKeyAgreeOnAnExplicitRedactionPolicy() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        CmuxSocketEventMapper.publish(
            command: Self.sendTextCommand,
            response: Self.sendTextResponse,
            caller: { .unknown }
        )
        CmuxSocketEventMapper.publish(
            command: #"{"id":2,"method":"surface.send_key","params":{"surface_id":"s-1","key":"ctrl-c"}}"#,
            response: #"{"id":2,"ok":true,"result":{"surface_id":"s-1"}}"#,
            caller: { .unknown }
        )

        let events = CmuxEventBus.shared.retainedSnapshot()
        #expect(events.count == 2)

        let textParams = try #require(
            (events[0]["payload"] as? [String: Any])?["params"] as? [String: Any]
        )
        #expect(textParams["text"] is NSNull)
        #expect((textParams["text_length"] as? NSNumber)?.intValue == "deploy prod".count)
        #expect(textParams["redacted_fields"] as? [String] == ["text"])

        let keyParams = try #require(
            (events[1]["payload"] as? [String: Any])?["params"] as? [String: Any]
        )
        #expect(keyParams["key"] as? String == "ctrl-c")
        // Present and empty: redaction was considered and nothing needed it.
        #expect(keyParams["redacted_fields"] as? [String] == [])
    }

    /// Events with no caller concept must not grow a fake one.
    @Test
    func nonSocketEventsOmitTheCallerKey() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        CmuxEventBus.shared.publish(name: "app.launched", category: "app", source: "app")

        let event = try #require(CmuxEventBus.shared.retainedSnapshot().first)
        #expect(event["caller"] == nil)
    }

    /// The pid → name cache is bounded, so a machine with churning callers
    /// cannot grow the socket path's memory without limit.
    @Test
    func processNameCacheIsBounded() {
        CmuxSocketCallerResolver.resetCacheForTesting()
        defer { CmuxSocketCallerResolver.resetCacheForTesting() }
        #expect(CmuxSocketCallerResolver.maxCachedProcessNames > 0)
        #expect(CmuxSocketCallerResolver.cachedProcessNameCountForTesting == 0)
    }
}
