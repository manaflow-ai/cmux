import CmuxiOSComposerCore
import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
import CmuxMobileWire
import Testing

@Suite("task mirror and encoder")
struct MirrorTests {
    @Test func snapshotThenContiguousStateEvents() {
        var mirror = TaskStreamMirror(hostID: HostID("h_studio"))
        #expect(mirror.apply(event: TaskFrames.state(seq: 1, task: "task_k1", state: "running")) == .needsSnapshot)
        #expect(mirror.apply(snapshot: TaskFrames.snapshot(seq: 10, tasks: [TaskFrames.task("task_k1")])) == .changed)
        #expect(mirror.agents.map(\.id) == ["claude", "codex"])
        #expect(mirror.agents[1].unavailableReason == "Not signed in")
        #expect(mirror.agents[0].model("opus")?.defaultEffort == "medium")
        #expect(mirror.tasks.first?.state == .queued)
        #expect(mirror.apply(event: TaskFrames.state(seq: 11, task: "task_k1", state: "needs_input")) == .changed)
        #expect(mirror.tasks.first?.state == .needsInput)
        #expect(mirror.apply(event: TaskFrames.state(seq: 11, task: "task_k1", state: "done")) == .unchanged)
        #expect(mirror.apply(event: TaskFrames.state(seq: 13, task: "task_k1", state: "done")) == .needsSnapshot)
        #expect(mirror.isResyncing)
        #expect(mirror.apply(event: TaskFrames.state(seq: 14, task: "task_k1", state: "done")) == .needsSnapshot)
        #expect(mirror.apply(snapshot: TaskFrames.snapshot(seq: 14, tasks: [TaskFrames.task("task_k1", state: "done")])) == .changed)
        #expect(!mirror.isResyncing)
    }

    @Test func anotherEpochOrAnUnknownTaskNeedsASnapshot() {
        var mirror = TaskStreamMirror(hostID: HostID("h_studio"))
        _ = mirror.apply(snapshot: TaskFrames.snapshot(seq: 10, tasks: [TaskFrames.task("task_k1")]))
        #expect(mirror.apply(event: TaskFrames.state(seq: 11, task: "task_k1", state: "done", epoch: "ep_2")) == .needsSnapshot)
        var other = TaskStreamMirror(hostID: HostID("h_studio"))
        _ = other.apply(snapshot: TaskFrames.snapshot(seq: 10))
        #expect(other.apply(event: TaskFrames.state(seq: 11, task: "task_zz", state: "done")) == .needsSnapshot)
    }

    @Test func encoderSendsThePromptAsAValueAndOnlySetFields() {
        let key = IntentKey(rawValue: "01JB7Q2W8M0000TASK0001")
        let draft = TaskDraft(hostID: HostID("h_studio"), workspaceID: "ws_studio1", agentID: "claude", model: "opus",
                              effort: "high", prompt: "echo $(id)", uploads: ["up_7Hq2"], templateID: "fix-tests")
        let frame = TaskDispatchEncoder(draft: draft, key: key).frame
        #expect(frame.op == "task.dispatch")
        #expect(frame.idempotencyKey == key.rawValue)
        #expect(frame.origin == .user)
        #expect(frame.stream == "task:h_studio")
        #expect(frame.params == .object([
            "host": "h_studio", "workspace": "ws_studio1", "agent": "claude", "model": "opus", "effort": "high",
            "prompt": "echo $(id)", "attachments": .array(["up_7Hq2"]), "template": "fix-tests",
        ]))
        let bare = TaskDispatchEncoder(draft: TaskDraft(hostID: HostID("h_studio"), agentID: "claude", prompt: "go"), key: key).frame
        #expect(bare.params.objectValue?.keys.sorted() == ["agent", "host", "prompt"])
    }

    @Test func receiptsMapResultAndReject() {
        let key = IntentKey(rawValue: "key-0001")
        let encoder = TaskDispatchEncoder(draft: TaskDraft(hostID: HostID("h_studio"), agentID: "claude", prompt: "go"), key: key)
        let started = encoder.receipt(for: .applied(ResultFrame(
            tx: "tx_1", idempotencyKey: key.rawValue,
            value: .object(["task": "task_k1", "workspace": "ws_new1", "tab": "tab_a1"]), revision: "9", replayed: false)))
        #expect(started == .started(key: key, workspaceID: "ws_new1", taskID: "task_k1", tabID: "tab_a1"))
        let refused = encoder.receipt(for: .rejected(RejectFrame(
            tx: "tx_2", idempotencyKey: key.rawValue, code: "task.agent_unavailable", message: "codex is not installed",
            retryable: false, replayed: false)))
        #expect(refused == .refused(key: key, reason: "codex is not installed"))
    }
}
