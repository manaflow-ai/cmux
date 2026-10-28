// l10n-allow-file: synthetic transcript test fixture.
import { expect, test } from "bun:test";
import { WorkflowTranscript, workflowPaneId, workflowPaneRequest } from "../src/agent-session/acpmux/summary/workflowTranscript";
import { openSubagentPane, revealedSubagent } from "../src/agent-session/acpmux/subagents/subagentPanes";

const request = { sessionId: "chat", runId: "wf_demo", agentId: "review" };
const text = (text: string) => ({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
const page = (start: number, end: number, lines: number, updates: unknown[]) => ({ start, end, lines, updates, truncated: false });
const deferred = <T>() => { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done; }); return { promise, resolve }; };

test("workflow identity round-trips through the existing native subagent placement", async () => {
  const id = workflowPaneId(request);
  expect(workflowPaneRequest(revealedSubagent(`subagent:${id}`))).toEqual(request);
  expect(workflowPaneRequest('["node",0]')).toBeUndefined();
  expect(workflowPaneRequest('workflow:["chat",null,"agent"]')).toBeUndefined();
  const calls: unknown[] = [];
  expect(await openSubagentPane(async (...args) => { calls.push(args); return { opened: true }; }, id, true)).toBe(true);
  expect(calls).toEqual([["chat.subagentPane", { subagent: id, focus: true }]]);
});

test("renders prompt, thinking, tool result and reply using the existing transcript rows", async () => {
  const reader = new WorkflowTranscript(request, async () => page(0, 4, 4, [
    { sessionUpdate: "user_message_chunk", content: { type: "text", text: "Review it" } },
    { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Checking" } },
    { sessionUpdate: "tool_call", toolCallId: "read", title: "Read file", kind: "read", status: "in_progress" },
    { sessionUpdate: "tool_call_update", toolCallId: "read", status: "completed", content: [{ type: "content", content: { type: "text", text: "Contents" } }] },
    text("Reviewed"),
  ]), () => {});
  await reader.refresh();
  expect(reader.rows.map((row) => row.kind)).toEqual(["user", "activity", "assistant"]);
  expect(reader.rows[0]?.text).toBe("Review it");
  expect(reader.rows[1]?.items?.find((item) => item.tool)?.tool?.status).toBe("completed");
  expect(reader.rows[2]?.text).toBe("Reviewed");
});

test("progress replaces the last page and follows catch-up cursors without duplicates", async () => {
  const calls: unknown[] = [];
  const pages = [page(2, 4, 4, [text("old")]), page(2, 4, 6, [text("new")]), page(4, 6, 6, [text(" tail")])];
  const reader = new WorkflowTranscript(request, async (params) => { calls.push(params); return pages.shift(); }, () => {});
  await reader.refresh();
  await reader.refresh();
  expect(reader.rows.map((row) => row.text)).toEqual(["new tail"]);
  expect(calls).toEqual([request, { ...request, after: 2 }, { ...request, after: 4 }]);
  expect(reader.canLoadOlder).toBe(true);
});

test("older pages retain current row ids and progress retains older content", async () => {
  const pages = [page(2, 4, 4, [text("tail")]), page(0, 2, 4, [{ sessionUpdate: "user_message_chunk", content: { type: "text", text: "prompt" } }]), page(2, 5, 5, [text("tail!")])];
  const reader = new WorkflowTranscript(request, async () => pages.shift(), () => {});
  await reader.refresh(); const id = reader.rows[0]!.id;
  await reader.loadOlder();
  expect(reader.rows[1]!.id).toBe(id);
  expect(reader.canLoadOlder).toBe(false);
  await reader.refresh();
  expect(reader.rows.map((row) => row.text)).toEqual(["prompt", "tail!"]);
});

test("late reads are ignored on close; concurrent progress coalesces to one follow-up", async () => {
  const first = deferred<unknown>(); const second = deferred<unknown>();
  let calls = 0; let notifications = 0;
  const reader = new WorkflowTranscript(request, () => ++calls === 1 ? first.promise : second.promise, () => notifications++);
  const pending = reader.refresh(); void reader.refresh(); void reader.refresh();
  expect(calls).toBe(1);
  first.resolve(page(0, 1, 1, [text("first")])); await pending;
  expect(calls).toBe(2);
  reader.dispose(); const before = notifications;
  second.resolve(page(0, 2, 2, [text("late")])); await second.promise; await Promise.resolve();
  expect(reader.rows[0]?.text).toBe("first");
  expect(notifications).toBe(before);
});

test("failed and non-advancing reads stop until a new progress event or explicit retry", async () => {
  let calls = 0;
  const reader = new WorkflowTranscript(request, async () => { calls++; return page(0, 0, 1, []); }, () => {});
  await reader.refresh();
  expect(reader.failed).toBe(true);
  expect(calls).toBe(2);
});
