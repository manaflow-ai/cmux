// l10n-allow-file: test fixtures.
// Calls to the cmux-subsessions tools as the transcript's sub-session cards (subsessionCalls.ts),
// read from either result a harness hands the pane: Claude Code's text, or Codex's whole MCP result.
import { expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { subsessionCall } from "./subsessionCalls";
import { toolGroups } from "./toolGroups";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

let ids = 0;
/// Claude Code's shape: `mcp__<server>__<tool>`, the arguments as the input, the result's text as
/// the output.
function claude(name: string, args: unknown, output?: string, status = "completed"): Tool {
  return {
    id: `call-${(ids += 1)}`,
    title: `mcp__cmux-subsessions__${name}`,
    status,
    inputSummary: JSON.stringify(args),
    ...(output !== undefined && { output }),
  };
}

/// Codex's shape: `{server, tool, arguments}`, the whole MCP result as the output.
function codex(name: string, args: unknown, structured: unknown, text = ""): Tool {
  return {
    id: `call-${(ids += 1)}`,
    title: `cmux-subsessions.${name} call`,
    kind: "execute",
    status: "completed",
    inputSummary: JSON.stringify({ server: "cmux-subsessions", tool: name, arguments: args }),
    output: JSON.stringify({ content: [{ type: "text", text }], structuredContent: structured, isError: false }),
  };
}

const item = (tool: Tool): AcpmuxActivity => ({ kind: "tool", text: tool.title, tool });

test("start_session names the sub-session it started, from its text or its structured result", () => {
  const said =
    "Started sub-session tests (sessionId 0199a-child, depth 1). The user sees it under your chat in the sidebar.";
  expect(subsessionCall(claude("start_session", { prompt: "Run the tests", name: "tests" }, said))).toEqual({
    tool: "start",
    running: false,
    sessionId: "0199a-child",
    name: "tests",
    prompt: "Run the tests",
  });
  const structured = { sessionId: "0199b-child", name: "claude-sr2/lint", shortName: "lint", depth: 1 };
  expect(subsessionCall(codex("start_session", { prompt: "Lint" }, structured, said))).toEqual({
    tool: "start",
    running: false,
    sessionId: "0199b-child",
    name: "lint",
    prompt: "Lint",
  });
  // Queued for a run slot, the text alone.
  const queued =
    "Created sub-session docs (sessionId 0199c-child, depth 1). It is queued: you already run as many sub-sessions as your maxRunning limit allows.";
  expect(subsessionCall(claude("start_session", { prompt: "Docs" }, queued))).toMatchObject({
    tool: "start",
    sessionId: "0199c-child",
    name: "docs",
  });
  // Still running: the name it asked for, if any.
  expect(subsessionCall(claude("start_session", { prompt: "x", name: "docs" }, undefined, "in_progress"))).toEqual({
    tool: "start",
    running: true,
    name: "docs",
    prompt: "x",
  });
});

// As the cmux server serves the tools as its own (cli/mcp/upstream.rs), with the result as Claude
// Code hands it over: the structured result's JSON (a recorded call, its prompt shortened).
test("the cmux server's subsessions_* tools read as the server's own", () => {
  const structured = {
    depth: 1,
    harness: "claude",
    mode: "bypassPermissions",
    name: "claude-sr2/update-toggle",
    session: { children: 0, depth: 1, doing: "Working on: You are update-toggle…", harness: "claude", state: "idle" },
    sessionId: "01a16f99-6033",
    shortName: "update-toggle",
    turnId: "01a16f99-634c",
    waitsForSlot: false,
  };
  const args = {
    name: "update-toggle",
    harness: "claude",
    model: "opus",
    prompt: 'You are "update-toggle".\n\nStep 1',
  };
  const viaCmux = (name: string, input: unknown, output?: string, status = "completed"): Tool => ({
    id: `call-${(ids += 1)}`,
    title: `mcp__cmux__subsessions_${name}`,
    status,
    inputSummary: JSON.stringify(input),
    ...(output !== undefined && { output }),
  });
  expect(subsessionCall(viaCmux("start_session", args, JSON.stringify(structured)))).toEqual({
    tool: "start",
    running: false,
    sessionId: "01a16f99-6033",
    name: "update-toggle",
    prompt: args.prompt,
    model: "opus",
    harness: "claude",
  });
  // Other cmux tools keep the generic row.
  expect(subsessionCall(viaCmux("workspace_list", {}, "{}"))).toBeUndefined();
  const listed = { sessions: [{ sessionId: "s-1", shortName: "lint", state: "working", harness: "codex" }], self: {} };
  expect(subsessionCall(viaCmux("list_sessions", {}, JSON.stringify(listed)))).toEqual({
    tool: "list",
    running: false,
    timedOut: false,
    sessions: [{ sessionId: "s-1", name: "lint", state: "working", harness: "codex" }],
  });
  expect(subsessionCall(viaCmux("list_sessions", {}, undefined, "in_progress"))).toEqual({
    tool: "list",
    running: true,
    timedOut: false,
    sessions: [],
  });
});

test("send_message says how the message was delivered", () => {
  const args = { sessionId: "child-1", text: "Also check the retries.\nThen report." };
  const cases: [string, unknown][] = [
    ["Delivered into its running turn: it reads it at its next tool step.", { kind: "next_step" }],
    [
      "Queued behind its running turn (position 2, 2 queued): it reads it when that turn ends. To reach it sooner …",
      { kind: "queued", position: 2 },
    ],
    ["Sent: it started a turn with it.", { kind: "started" }],
    [
      "Queued: it starts a turn with it once a run slot frees (its parent already runs as many sub-sessions as maxRunning allows).",
      { kind: "slot" },
    ],
  ];
  for (const [said, delivery] of cases)
    expect(subsessionCall(claude("send_message", args, said))).toEqual({
      tool: "send",
      running: false,
      sessionId: "child-1",
      text: args.text,
      delivery,
    } as never);
  const structured = { sessionId: "child-1", delivery: "queued", position: 3, queueLength: 3 };
  expect(subsessionCall(codex("send_message", args, structured))).toMatchObject({
    delivery: { kind: "queued", position: 3 },
  });
  expect(
    subsessionCall(codex("send_message", args, { sessionId: "child-1", delivery: "waiting_for_slot" })),
  ).toMatchObject({ delivery: { kind: "slot" } });
  expect(subsessionCall(claude("send_message", args, undefined, "pending"))).toMatchObject({
    tool: "send",
    running: true,
  });
});

test("wait_for_sessions lists each sub-session's state and reply, and what one waiting on the person waits for", () => {
  const rows = {
    timedOut: true,
    sessions: [
      { sessionId: "child-1", shortName: "tests", state: "idle", lastReply: "  All 41 tests pass.  " },
      { sessionId: "child-2", shortName: "lint", state: "working", doing: "Run oxlint" },
      {
        sessionId: "child-3",
        name: "claude-sr2/docs",
        state: "input",
        waitingOn: "question",
        doing: "Waiting for the user to answer, in the app: Which branch?",
      },
      { sessionId: "child-4", shortName: "deps", state: "input", waitingOn: "permission" },
      { sessionId: "child-5", shortName: "bench", state: "lost" },
    ],
  };
  const expected = {
    tool: "wait",
    running: false,
    timedOut: true,
    sessions: [
      { sessionId: "child-1", name: "tests", state: "done", reply: "All 41 tests pass." },
      { sessionId: "child-2", name: "lint", state: "working" },
      {
        sessionId: "child-3",
        name: "claude-sr2/docs",
        state: "input",
        waiting: { on: "question", prompt: "Which branch?" },
      },
      { sessionId: "child-4", name: "deps", state: "input", waiting: { on: "permission" } },
      { sessionId: "child-5", name: "bench", state: "failed" },
    ],
  };
  // Claude Code's text: a line when it timed out, then the JSON.
  const said = `Still running after 45 s; call wait_for_sessions again to keep waiting.\n${JSON.stringify(rows, null, 2)}`;
  expect(subsessionCall(claude("wait_for_sessions", {}, said))).toEqual(expected as never);
  expect(subsessionCall(codex("wait_for_sessions", {}, rows))).toEqual(expected as never);
  expect(subsessionCall(claude("wait_for_sessions", {}, "None of your sub-sessions is running."))).toEqual({
    tool: "wait",
    running: false,
    timedOut: false,
    sessions: [],
  });
});

test("a failed or refused call, another tool or another server keeps the generic MCP row", () => {
  expect(subsessionCall(claude("start_session", { prompt: "x" }, "too many sub-sessions", "failed"))).toBeUndefined();
  // A refusal the harness reports as completed: no session started, no delivery.
  expect(
    subsessionCall(claude("start_session", { prompt: "x" }, "start_session refused: no worktree")),
  ).toBeUndefined();
  expect(subsessionCall(claude("send_message", { sessionId: "c", text: "hi" }, "not one of yours"))).toBeUndefined();
  expect(subsessionCall(claude("list_sessions", {}, "{}"))).toBeUndefined();
  expect(
    subsessionCall({ id: "x", title: "mcp__gmail__send_message", status: "completed", inputSummary: "{}" }),
  ).toBeUndefined();
});

test("each sub-session call is its own card, between the calls around it", () => {
  const read: AcpmuxActivity = {
    kind: "tool",
    text: "Read",
    tool: { id: "read", title: "Read", kind: "read", status: "completed" },
  };
  const start = claude("start_session", { prompt: "x" }, "Started sub-session a (sessionId s-a, depth 1).");
  const send = claude("send_message", { sessionId: "s-a", text: "hi" }, "Sent: it started a turn with it.");
  const list = claude("list_sessions", {}, "{}");
  const groups = toolGroups([read, item(start), item(send), item(list), item(claude("list_sessions", {}, "{}"))]);
  expect(groups.map((group) => group.type)).toEqual(["item", "subsession", "subsession", "mcp"]);
  expect(groups[1]).toMatchObject({ type: "subsession", call: { tool: "start", sessionId: "s-a" } });
  // The two list_sessions calls still fold into one MCP line.
  expect(groups[3]).toMatchObject({ type: "mcp", items: [{ tool: list }, {}] });
});

test("a row with no lane yet reads its state from its status dot", () => {
  const rows = { sessions: [{ sessionId: "s-new", shortName: "new", state: null, indicator: "working" }] };
  expect(subsessionCall(codex("list_sessions", {}, rows))).toMatchObject({
    sessions: [{ sessionId: "s-new", state: "working" }],
  });
});

test("a list whose rows cannot be read keeps the generic row", () => {
  expect(subsessionCall(codex("list_sessions", {}, { sessions: [{ name: "no id" }] }))).toBeUndefined();
});

test("a row that says no state, or one unreadable row among good ones, keeps the generic row", () => {
  expect(subsessionCall(codex("list_sessions", {}, { sessions: [{ sessionId: "s-1" }] }))).toBeUndefined();
  const mixed = { sessions: [{ sessionId: "s-1", state: "working" }, { name: "no id" }] };
  expect(subsessionCall(codex("list_sessions", {}, mixed))).toBeUndefined();
  const byStatus = { sessions: [{ sessionId: "s-2", state: null, status: "running" }] };
  expect(subsessionCall(codex("list_sessions", {}, byStatus))).toMatchObject({
    sessions: [{ sessionId: "s-2", state: "working" }],
  });
});

test("a row waiting for a run slot says so", () => {
  const rows = { sessions: [{ sessionId: "s-q", shortName: "queued", state: "idle", waitsForSlot: true }] };
  expect(subsessionCall(codex("list_sessions", {}, rows))).toMatchObject({
    sessions: [{ sessionId: "s-q", state: "done", slot: true }],
  });
});
