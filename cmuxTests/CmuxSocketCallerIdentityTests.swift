import CmuxControlSocket
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
    func processSnapshotForADeadPidReturnsNil() {
        let resolver = CmuxSocketCallerResolver()

        // Above the default `kern.maxproc` pid ceiling, so no live process owns it.
        #expect(resolver.processSnapshot(pid: 9_999_999) == nil)
        #expect(resolver.processSnapshot(pid: 0) == nil)
        #expect(resolver.processSnapshot(pid: -1) == nil)
        // A failed lookup must not be cached as a fabricated entry.
        #expect(resolver.cachedProcessNameCount == 0)
    }

    /// A name cached for one process must never be served for a recycled pid
    /// that reuses the same number.
    @Test
    func processNameCacheIsKeyedByGenerationNotPid() throws {
        let resolver = CmuxSocketCallerResolver()
        let live = try #require(resolver.processSnapshot(pid: getpid()))
        #expect(resolver.processName(for: live.generation) != nil)
        #expect(resolver.generationIsCurrent(live.generation))

        // Same pid, different start time: a recycled pid. It must miss the
        // cache, and because that generation is not live, resolve to nothing.
        let recycled = CmuxSocketCallerGeneration(
            pid: live.generation.pid,
            startSeconds: live.generation.startSeconds &+ 1,
            startMicroseconds: live.generation.startMicroseconds
        )
        #expect(!resolver.generationIsCurrent(recycled))
    }

    /// End to end through the real resolver: this test process is a live pid, so
    /// the name comes from `proc_pidpath` and is stable across repeat lookups.
    @Test
    func processNameResolvesLivePidAndCachesIt() throws {
        let resolver = CmuxSocketCallerResolver()
        let snapshot = try #require(resolver.processSnapshot(pid: getpid()))
        let name = try #require(resolver.processName(for: snapshot.generation))
        #expect(!name.isEmpty)
        #expect(!name.contains("/"))
        #expect(resolver.cachedProcessNameCount == 1)
        #expect(resolver.processName(for: snapshot.generation) == name)
        #expect(resolver.cachedProcessNameCount == 1)
    }

    /// A dead pid mixed into an otherwise resolvable identity must null exactly
    /// that field and still emit the event.
    @Test
    func partiallyResolvedIdentityNullsOnlyTheMissingField() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let resolver = CmuxSocketCallerResolver()
        let identity = CmuxSocketCallerIdentity(
            pid: 9_999_999,
            processName: resolver.processSnapshot(pid: 9_999_999)
                .flatMap { resolver.processName(for: $0.generation) },
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

        // `publish` takes a non-escaping provider and invokes it synchronously
        // on this thread, so a plain box needs no Sendable conformance.
        final class Counter {
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

    /// The redaction marker documented in `docs/events.md` must be present on
    /// v1 input events too, not only v2.
    @Test
    func v1InputEventsCarryRedactionMarkers() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        CmuxSocketEventMapper.publish(command: "send secret text", response: "OK", caller: { .unknown })
        CmuxSocketEventMapper.publish(command: "send_key ctrl-c", response: "OK", caller: { .unknown })

        let events = CmuxEventBus.shared.retainedSnapshot()
        let textPayload = try #require(events[0]["payload"] as? [String: Any])
        #expect(textPayload["args"] as? String == "<redacted>")
        #expect(textPayload["redacted_fields"] as? [String] == ["args"])

        let keyPayload = try #require(events[1]["payload"] as? [String: Any])
        #expect(keyPayload["args"] as? String == "ctrl-c")
        #expect(keyPayload["redacted_fields"] as? [String] == [])
    }

    /// `mapsToEvent` decides whether the socket loop resolves attribution before
    /// running a command. If it disagreed with what `publishV1` actually
    /// publishes, those events would silently lose their caller.
    @Test
    func v1PublishingCommandsMatchPublishV1() {
        let allV1Commands: Set<String> = CmuxSocketEventMapper.v1PublishingCommands.union([
            "new_window", "focus_window", "close_window",
            "new_workspace", "select_workspace", "close_workspace",
            "new_split", "new_pane", "new_surface", "open_browser",
            "focus_surface", "focus_surface_by_panel", "focus_pane",
            "close_surface", "list_workspaces", "read_screen",
        ])

        for command in allV1Commands.sorted() {
            CmuxEventBus.shared.resetForTesting()
            CmuxSocketEventMapper.publish(command: "\(command) arg", response: "OK", caller: { .unknown })
            let didPublish = !CmuxEventBus.shared.retainedSnapshot().isEmpty
            #expect(
                didPublish == CmuxSocketEventMapper.mapsToEvent(command: "\(command) arg"),
                "mapsToEvent disagrees with publishV1 for \(command)"
            )
        }
        CmuxEventBus.shared.resetForTesting()
    }

    /// The v2 side of the same predicate.
    @Test
    func mapsToEventMatchesV2Mapping() {
        #expect(CmuxSocketEventMapper.mapsToEvent(command: Self.sendTextCommand))
        #expect(CmuxSocketEventMapper.mapsToEvent(
            command: #"{"id":1,"method":"surface.send_key","params":{}}"#
        ))
        // Read-only methods and the stream itself publish nothing.
        #expect(!CmuxSocketEventMapper.mapsToEvent(
            command: #"{"id":1,"method":"surface.list","params":{}}"#
        ))
        #expect(!CmuxSocketEventMapper.mapsToEvent(
            command: #"{"id":1,"method":"events.stream","params":{}}"#
        ))
        #expect(!CmuxSocketEventMapper.mapsToEvent(command: "not json at all"))
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
    func processNameCacheIsBounded() throws {
        let resolver = CmuxSocketCallerResolver(maxCachedProcessNames: 2)
        let snapshot = try #require(resolver.processSnapshot(pid: getpid()))
        // Three distinct generations through a cache bounded at two.
        for offset in 0..<3 {
            let generation = CmuxSocketCallerGeneration(
                pid: snapshot.generation.pid,
                startSeconds: snapshot.generation.startSeconds &+ UInt64(offset),
                startMicroseconds: snapshot.generation.startMicroseconds
            )
            _ = resolver.processName(for: generation)
        }
        #expect(resolver.cachedProcessNameCount <= 2)
    }
}
