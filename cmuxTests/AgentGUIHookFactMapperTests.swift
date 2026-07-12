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
    @Test func processKindRequiresStructuredLaunchMetadata() {
        #expect(AgentProcessObservationSource.agentKind(
            arguments: ["codex_report.py"],
            environment: [:],
            processName: "python"
        ) == .unknown("unknown"))
        #expect(AgentProcessObservationSource.agentKind(
            arguments: ["claude.log"],
            environment: [:],
            processName: "cat"
        ) == .unknown("unknown"))
        #expect(AgentProcessObservationSource.agentKind(
            arguments: [],
            environment: ["CMUX_AGENT_LAUNCH_KIND": "codex"],
            processName: "node"
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
