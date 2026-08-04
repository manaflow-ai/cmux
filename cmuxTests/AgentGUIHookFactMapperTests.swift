import CMUXAgentLaunch
import CmuxAgentReplica
import CmuxAgentTruthKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct AgentGUIHookFactMapperTests {
    @Test @MainActor
    func processObservationCoalescesInflightRequestsIntoOneFollowUp() async {
        let capturer = ControlledAgentProcessObservationCapturer()
        var deliveredGenerations: [UInt64] = []
        let source = AgentProcessObservationSource(
            captureObservations: { bypassCache in
                await capturer.capture(bypassingCache: bypassCache)
            },
            onObservations: { _, generation in deliveredGenerations.append(generation) }
        )

        let firstGeneration = source.scanNow()
        await capturer.waitForCallCount(1)
        let postLaunchGeneration = source.scanNow(bypassingCache: true)
        source.scanNow()
        source.scanNow()
        #expect(await capturer.callCount() == 1)
        #expect(postLaunchGeneration == firstGeneration + 1)

        await capturer.release(call: 1)
        await capturer.waitForCallCount(2)
        #expect(await capturer.callCount() == 2)
        await capturer.release(call: 2)
        await source.waitForIdleForTesting()

        #expect(await capturer.callCount() == 2)
        #expect(await capturer.bypassRequests() == [false, true])
        #expect(deliveredGenerations == [firstGeneration, postLaunchGeneration])
    }

    @Test @MainActor
    func stoppingAnInflightObservationAllowsImmediateReplacementScan() async {
        let capturer = ControlledAgentProcessObservationCapturer()
        var deliveryCount = 0
        let source = AgentProcessObservationSource(
            captureObservations: { bypassCache in
                await capturer.capture(bypassingCache: bypassCache)
            },
            onObservations: { _, _ in deliveryCount += 1 }
        )

        source.scanNow()
        await capturer.waitForCallCount(1)
        source.setRunning(false)
        source.scanNow()
        await capturer.waitForCallCount(2)

        await capturer.release(call: 2)
        await source.waitForIdleForTesting()
        #expect(deliveryCount == 1)

        await capturer.release(call: 1)
        await Task.yield()
        #expect(deliveryCount == 1)
    }

    @Test func processKindUsesPreciseExecutableNamesWithoutRequiringLaunchMetadata() {
        #expect(AgentProcessObservationSource.agentKind(
            arguments: ["/usr/local/bin/claude"],
            environment: [:],
            processName: "claude"
        ) == .claude)
        #expect(AgentProcessObservationSource.agentKind(
            arguments: ["/usr/local/bin/node", "/x/claude"],
            environment: [:],
            processName: "node"
        ) == .claude)
        #expect(AgentProcessObservationSource.agentKind(
            arguments: ["/usr/bin/grep", "claude"],
            environment: [:],
            processName: "grep"
        ) == .unknown("unknown"))
        #expect(AgentProcessObservationSource.agentKind(
            arguments: ["/usr/local/bin/claude-notes"],
            environment: [:],
            processName: "claude-notes"
        ) == .unknown("unknown"))
        #expect(AgentProcessObservationSource.agentKind(
            arguments: ["/usr/local/bin/my-codex-tool"],
            environment: [:],
            processName: "my-codex-tool"
        ) == .unknown("unknown"))
        #expect(AgentProcessObservationSource.agentKind(
            arguments: ["/usr/local/bin/codex"],
            environment: ["CMUX_AGENT_LAUNCH_KIND": "claude"],
            processName: "codex"
        ) == .claude)
        #expect(AgentProcessObservationSource.agentKind(
            arguments: ["/opt/homebrew/bin/codex"],
            environment: [:],
            processName: "codex"
        ) == .codex)
    }

    @Test func mapsKnownHookNamesAndUnknowns() {
        let mapper = AgentGUIHookFactMapper()

        let start = mapper.hookFact(
            sessionID: "session-1",
            rawHookName: "SessionStart",
            surfaceID: "surface-1",
            transcriptPath: "/tmp/session.jsonl",
            cwd: "/repo",
            pid: 123,
            source: "codex",
            toolInputJSON: nil,
            extraFieldsJSON: nil
        )
        #expect(start.eventName == .sessionStart)
        #expect(start.sessionID == AgentSessionID(rawValue: "session-1"))
        #expect(start.surfaceID == "surface-1")
        #expect(start.transcriptPath == "/tmp/session.jsonl")
        #expect(start.cwd == "/repo")
        #expect(start.pid == 123)

        let permission = mapper.hookFact(
            sessionID: "session-1",
            rawHookName: "PermissionRequest",
            surfaceID: nil,
            transcriptPath: nil,
            cwd: nil,
            pid: nil,
            source: "claude",
            toolInputJSON: nil,
            extraFieldsJSON: nil
        )
        #expect(permission.eventName == .permissionRequest)
        #expect(permission.notificationRequiresInput)

        let unknown = mapper.hookFact(
            sessionID: "session-1",
            rawHookName: "FutureHook",
            surfaceID: nil,
            transcriptPath: nil,
            cwd: nil,
            pid: nil,
            source: "codex",
            toolInputJSON: nil,
            extraFieldsJSON: "{\"requires_input\":true}"
        )
        #expect(unknown.eventName == .unknown("FutureHook"))
        #expect(unknown.notificationRequiresInput)
    }

    @Test func wrapperLaunchFactRequiresExplicitWrapperOrigin() {
        let mapper = AgentGUIHookFactMapper()
        let plain = WorkstreamEvent(
            sessionId: "session-1",
            hookEventName: .sessionStart,
            source: "codex",
            surfaceId: "surface-1",
            cwd: "/repo",
            ppid: 123
        )
        #expect(mapper.wrapperLaunchFact(from: plain) == nil)

        let wrapped = WorkstreamEvent(
            sessionId: "session-1",
            hookEventName: .sessionStart,
            source: "codex",
            surfaceId: "surface-1",
            cwd: "/repo",
            ppid: 123,
            extraFieldsJSON: "{\"wrapper_origin\":\"cmux-wrapper\",\"launch_argv_kind\":\"resume\"}"
        )
        let fact = mapper.wrapperLaunchFact(from: wrapped)
        #expect(fact?.surfaceID == "surface-1")
        #expect(fact?.agentKind == .codex)
        #expect(fact?.launchArgvKind == .resume)
    }
}
