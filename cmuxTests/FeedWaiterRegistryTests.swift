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
}
