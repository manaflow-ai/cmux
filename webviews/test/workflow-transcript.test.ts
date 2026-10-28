// l10n-allow-file: synthetic transcript test fixture.
import { expect, test } from "bun:test";
import {
  WorkflowTranscript,
  workflowPaneId,
  workflowPaneRequest,
} from "../src/agent-session/acpmux/summary/workflowTranscript";
import { openSubagentPane, revealedSubagent } from "../src/agent-session/acpmux/subagents/subagentPanes";

const request = { sessionId: "chat", runId: "wf_demo", agentId: "review" };
const text = (text: string) => ({
  sessionUpdate: "agent_message_chunk",
  content: { type: "text", text },
});
const page = (start: number, end: number, lines: number, updates: unknown[]) => ({
  start,
  end,
  lines,
  updates,
  truncated: false,
});
const deferred = <T>() => {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
};

test("workflow identity round-trips through the existing native subagent placement", async () => {
  const id = workflowPaneId(request);
  expect(workflowPaneRequest(revealedSubagent(`subagent:${id}`))).toEqual(request);
  expect(workflowPaneRequest('["node",0]')).toBeUndefined();
  expect(workflowPaneRequest('workflow:["chat",null,"agent"]')).toBeUndefined();
  const calls: unknown[] = [];
  expect(
    await openSubagentPane(
      async (...args) => {
        calls.push(args);
        return { opened: true };
      },
      id,
      true,
    ),
  ).toBe(true);
  expect(calls).toEqual([["chat.subagentPane", { subagent: id, focus: true }]]);
});

test("renders prompt, thinking, tool result and reply using the existing transcript rows", async () => {
  const reader = new WorkflowTranscript(
    request,
    async () =>
      page(0, 4, 4, [
        { sessionUpdate: "user_message_chunk", content: { type: "text", text: "Review it" } },
        { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Checking" } },
        {
          sessionUpdate: "tool_call",
          toolCallId: "read",
          title: "Read file",
          kind: "read",
          status: "in_progress",
        },
        {
          sessionUpdate: "tool_call_update",
          toolCallId: "read",
          status: "completed",
          content: [{ type: "content", content: { type: "text", text: "Contents" } }],
        },
        text("Reviewed"),
      ]),
    () => {},
  );
  await reader.refresh();
  expect(reader.rows.map((row) => row.kind)).toEqual(["user", "activity", "assistant"]);
  expect(reader.rows[0]?.text).toBe("Review it");
  expect(reader.rows[1]?.items?.find((item) => item.tool)?.tool?.status).toBe("completed");
  expect(reader.rows[2]?.text).toBe("Reviewed");
});

test("progress replaces the last page and follows catch-up cursors without duplicates", async () => {
  const calls: unknown[] = [];
  const pages = [page(2, 4, 4, [text("old")]), page(2, 4, 6, [text("new")]), page(4, 6, 6, [text(" tail")])];
  const reader = new WorkflowTranscript(
    request,
    async (params) => {
      calls.push(params);
      return pages.shift();
    },
    () => {},
  );
  await reader.refresh();
  await reader.refresh();
  expect(reader.rows.map((row) => row.text)).toEqual(["new tail"]);
  expect(calls).toEqual([request, { ...request, after: 2 }, { ...request, after: 4 }]);
  expect(reader.canLoadOlder).toBe(true);
});

test("older pages retain current row ids and progress retains older content", async () => {
  const pages = [
    page(2, 4, 4, [text("tail")]),
    page(0, 2, 4, [{ sessionUpdate: "user_message_chunk", content: { type: "text", text: "prompt" } }]),
    page(2, 5, 5, [text("tail!")]),
  ];
  const reader = new WorkflowTranscript(
    request,
    async () => pages.shift(),
    () => {},
  );
  await reader.refresh();
  const id = reader.rows[0]!.id;
  await reader.loadOlder();
  expect(reader.rows[1]!.id).toBe(id);
  expect(reader.canLoadOlder).toBe(false);
  await reader.refresh();
  expect(reader.rows.map((row) => row.text)).toEqual(["prompt", "tail!"]);
});

test("late reads are ignored on close; concurrent progress coalesces to one follow-up", async () => {
  const first = deferred<unknown>();
  const second = deferred<unknown>();
  let calls = 0;
  let notifications = 0;
  const reader = new WorkflowTranscript(
    request,
    () => (++calls === 1 ? first.promise : second.promise),
    () => notifications++,
  );
  const pending = reader.refresh();
  void reader.refresh();
  void reader.refresh();
  expect(calls).toBe(1);
  first.resolve(page(0, 1, 1, [text("first")]));
  await pending;
  expect(calls).toBe(2);
  reader.dispose();
  const before = notifications;
  second.resolve(page(0, 2, 2, [text("late")]));
  await second.promise;
  await Promise.resolve();
  expect(reader.rows[0]?.text).toBe("first");
  expect(notifications).toBe(before);
});

test("failed and non-advancing reads stop until a new progress event or explicit retry", async () => {
  let calls = 0;
  const reader = new WorkflowTranscript(
    request,
    async () => {
      calls++;
      return page(0, 0, 1, []);
    },
    () => {},
  );
  await reader.refresh();
  expect(reader.failed).toBe(true);
  expect(calls).toBe(2);
});

test("the hook refreshes only the selected agent, survives StrictMode, and drops switched reads", async () => {
  const { JSDOM, VirtualConsole } = await import("jsdom");
  const dom = new JSDOM("<div id='root'></div>", { url: "http://localhost/", virtualConsole: new VirtualConsole() });
  const scope = globalThis as Record<string, unknown>;
  const globals = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  const saved = Object.keys(globals).map((key) => [key, scope[key]] as const);
  Object.assign(scope, globals);
  const { act, createElement, StrictMode } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { useWorkflowTranscript } = await import("../src/agent-session/acpmux/summary/useWorkflowTranscript");
  const root = createRoot(dom.window.document.getElementById("root")!);
  const pending = deferred<unknown>();
  let calls = 0;
  const read = async () =>
    ++calls <= 2 ? { ...page(0, 1, 1, [text(`read ${calls}`)]), truncated: calls === 1 } : pending.promise;
  // Keep the component type stable across renders: changing a parent snapshot does not remount it.
  let progress = 1;
  let id = workflowPaneId(request);
  function Probe() {
    const result = useWorkflowTranscript(
      id,
      "chat",
      true,
      { id: "ui-key", name: "Review", state: "running", lastProgressAt: progress },
      "Parent",
      read,
      "connected",
    );
    return createElement("div", null, result.rows?.map((row) => row.text).join("|"));
  }
  const show = () => root.render(createElement(StrictMode, null, createElement(Probe)));
  try {
    await act(async () => show());
    expect(calls).toBe(1);
    expect(dom.window.document.body.textContent).toContain("Only recent transcript history is available.");
    expect(dom.window.document.body.textContent).not.toContain("{count}");
    await act(async () => show());
    expect(calls).toBe(1);
    progress = 2;
    await act(async () => show());
    expect(calls).toBe(2);
    expect(dom.window.document.body.textContent).toContain("read 2");
    progress = 3;
    await act(async () => show());
    id = workflowPaneId({ ...request, sessionId: "other" });
    await act(async () => show());
    await act(async () => pending.resolve(page(0, 1, 1, [text("wrong chat")])));
    expect(dom.window.document.body.textContent).not.toContain("wrong chat");
  } finally {
    await act(async () => root.unmount());
    for (const [key, value] of saved) {
      if (value === undefined) delete scope[key];
      else scope[key] = value;
    }
    dom.window.close();
  }
});
