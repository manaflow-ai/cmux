import CMUXAgentLaunch
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct FeedWaiterRegistryTests {
    private func event(input: String = "{}") -> WorkstreamEvent {
        WorkstreamEvent(sessionId: "session", hookEventName: .permissionRequest,
            source: "claude", toolName: "Tool", toolInputJSON: input, requestId: "request")
    }
    private func item(status: WorkstreamStatus = .pending) -> WorkstreamItem {
        WorkstreamItem(workstreamId: "session", source: .claude, kind: .permissionRequest,
            status: status, payload: .permissionRequest(requestId: "request", toolName: "Tool", toolInputJSON: "{}", pattern: nil))
    }

    @Test func duplicateWaitersShareOneReplyIncludingTheStoreCommitGap() throws {
        let registry = FeedWaiterRegistry()
        let first = try #require(registry.register(requestID: "request", event: event()))
        let second = try #require(registry.register(requestID: "request", event: event()))
        #expect(first.isOwner)
        #expect(!second.isOwner)
        registry.accepted(first, event: event(), item: item())
        let reply = try #require(registry.resolve(requestID: "request", decision: .permission(.once)))
        #expect(first.semaphore.wait(timeout: .now()) == .success)
        #expect(second.semaphore.wait(timeout: .now()) == .success)
        guard case .resolved = registry.finish(first).outcome.result else { Issue.record("First waiter lost its reply"); return }
        guard case .resolved = registry.finish(second).outcome.result else { Issue.record("Duplicate waiter lost its reply"); return }
        let duringCommit = try #require(registry.register(requestID: "request", event: event()))
        #expect(!duringCommit.isOwner)
        #expect(duringCommit.semaphore.wait(timeout: .now()) == .success)
        guard case .resolved = registry.finish(duringCommit).outcome.result else { Issue.record("Commit-gap retry lost its reply"); return }
        registry.replyStored(reply)
        #expect(registry.subscriberCount("request") == 0)
    }

    @Test func oneTimeoutCannotCancelAnotherSubscriber() throws {
        let registry = FeedWaiterRegistry()
        let first = try #require(registry.register(requestID: "request", event: event()))
        let second = try #require(registry.register(requestID: "request", event: event()))
        registry.accepted(first, event: event(), item: item())
        #expect(!registry.finish(first).shouldCancel)
        #expect(registry.isAwaiting("request"))
        _ = registry.resolve(requestID: "request", decision: .permission(.once))
        #expect(second.semaphore.wait(timeout: .now()) == .success)
        guard case .resolved = registry.finish(second).outcome.result else { Issue.record("Remaining waiter was cancelled"); return }
    }

    @Test func conflictingPayloadCannotJoinAndInvalidationSignalsAllWaiters() throws {
        let registry = FeedWaiterRegistry()
        let registration = try #require(registry.register(requestID: "request", event: event()))
        registry.accepted(registration, event: event(), item: item())
        #expect(registry.register(requestID: "request", event: event(input: #"{"different":true}"#)) == nil)
        #expect(registry.invalidate(requestID: "request", source: "codex", sessionID: "session") == nil)
        let (reply, _) = try #require(registry.invalidate(requestID: "request", source: "claude", sessionID: "session"))
        #expect(registration.semaphore.wait(timeout: .now()) == .success)
        let finished = registry.finish(registration)
        #expect(!finished.shouldCancel)
        guard case .unavailable = finished.outcome.result else { Issue.record("Invalidated request remained actionable"); return }
        registry.cleanupStored(requestID: reply.requestID, groupID: reply.groupID)
    }

    @Test func onlyALaterHookFromTheSameAgentSupersedesARequest() throws {
        func stamped(_ hook: WorkstreamEvent.HookEventName, sentAt: Int?, agentID: String? = nil,
                     source: String = "claude", session: String = "session") -> WorkstreamEvent {
            var extra: [String] = []
            if let sentAt { extra.append(#""_hook_sent_at_ms":\#(sentAt)"#) }
            if let agentID { extra.append(#""agent_id":"\#(agentID)""#) }
            return WorkstreamEvent(sessionId: session, hookEventName: hook, source: source,
                toolName: "Tool", toolInputJSON: "{}", requestId: hook == .permissionRequest ? "request" : nil,
                extraFieldsJSON: extra.isEmpty ? nil : "{\(extra.joined(separator: ","))}")
        }
        let registry = FeedWaiterRegistry()
        let request = stamped(.permissionRequest, sentAt: 2_000)
        let registration = try #require(registry.register(requestID: "request", event: request))
        registry.accepted(registration, event: request, item: item())

        // The tool's own PreToolUse precedes its request; unstamped hooks and
        // other sessions, sources, or subagents prove nothing.
        #expect(registry.supersede(by: stamped(.preToolUse, sentAt: 1_990)).isEmpty)
        #expect(registry.supersede(by: stamped(.preToolUse, sentAt: 2_000)).isEmpty)
        #expect(registry.supersede(by: stamped(.preToolUse, sentAt: nil)).isEmpty)
        #expect(registry.supersede(by: stamped(.preToolUse, sentAt: 3_000, session: "other")).isEmpty)
        #expect(registry.supersede(by: stamped(.preToolUse, sentAt: 3_000, source: "codex")).isEmpty)
        #expect(registry.supersede(by: stamped(.preToolUse, sentAt: 3_000, agentID: "subagent")).isEmpty)
        #expect(registry.isAwaiting("request"))

        let superseded = registry.supersede(by: stamped(.preToolUse, sentAt: 3_000))
        #expect(superseded.map { $0.0.requestID } == ["request"])
        #expect(registration.semaphore.wait(timeout: .now()) == .success)
        #expect(registry.supersede(by: stamped(.stop, sentAt: 4_000)).isEmpty)
        let finished = registry.finish(registration)
        #expect(!finished.shouldCancel)
        guard case .unavailable = finished.outcome.result else {
            Issue.record("A superseded request must return no decision")
            return
        }
    }

    @Test func unstampedRequestIsNeverSuperseded() throws {
        let registry = FeedWaiterRegistry()
        let registration = try #require(registry.register(requestID: "request", event: event()))
        registry.accepted(registration, event: event(), item: item())
        let later = WorkstreamEvent(sessionId: "session", hookEventName: .preToolUse, source: "claude",
            toolName: "Bash", extraFieldsJSON: #"{"_hook_sent_at_ms":9000}"#)
        #expect(registry.supersede(by: later).isEmpty)
        #expect(registry.isAwaiting("request"))
    }

    @Test func lateFailureCannotReplaceDecisionBeforeStoreCommit() throws {
        let registry = FeedWaiterRegistry()
        let registration = try #require(registry.register(requestID: "request", event: event()))
        let reply = try #require(registry.resolve(requestID: "request", decision: .permission(.once)))
        registry.fail(registration, result: .unavailable)
        registry.accepted(registration, event: event(), item: item())
        #expect(registration.semaphore.wait(timeout: .now()) == .success)
        guard case .resolved = registry.finish(registration).outcome.result else {
            Issue.record("A late failure replaced the resolved decision")
            return
        }
        registry.replyStored(reply)
    }

    @Test func blockingWaiterIsDismissedWhenAgentProcessExits() throws {
        let registry = FeedWaiterRegistry()
        let request = WorkstreamEvent(
            sessionId: "session",
            hookEventName: .permissionRequest,
            source: "claude",
            requestId: "request",
            ppid: 4242
        )
        let registration = try #require(registry.register(
            requestID: "request",
            event: request,
            waitUntilResolved: true
        ))
        registry.accepted(registration, event: request, item: item())

        let dismissed = registry.invalidateOptInWaiters(forPpid: 4242)
        #expect(dismissed.count == 1)
        #expect(registration.semaphore.wait(timeout: .now()) == .success)
        guard case .unavailable = registry.finish(registration).outcome.result else {
            Issue.record("agent exit must dismiss an opted-in blocking waiter")
            return
        }
    }
}
