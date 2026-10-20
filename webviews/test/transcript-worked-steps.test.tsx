// An open "Worked for" lists every step of its turn (Leo 2026-10-13): each thought, each tool
// call or group of them, each message, in order, with nothing folded again under a "Read files, ran
// commands" line and nothing cut off at the end. Text the agent writes between tool calls is prose
// (Claude Code's ● lines, Codex's commentary), never a "Thought"; only a thinking block is one.
// Before, each run of calls inside the open turn closed again under one summary line whose list
// scrolled after nine rows, so a long turn's last steps looked cut off.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
  // The app turns the thought fold on (Debug toggle agentPane.debug.foldLongThoughts).
  window.document.documentElement.dataset.foldLongThoughts = "on";
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const update = (sessionUpdate: string, fields: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update: { sessionUpdate, ...fields } },
});
const text = (kind: string, value: string) => update(kind, { content: { type: "text", text: value } });
const run = (id: string, command: string) => [
  update("tool_call", { toolCallId: id, title: "Run", kind: "execute", status: "in_progress", rawInput: { command } }),
  update("tool_call_update", { toolCallId: id, status: "completed" }),
];

// A Claude Code turn as acpmux records it: a thinking block, two commands, a line of text, a
// thinking block, eleven reads, a message to the coordinator, then the answer.
function turn() {
  const steps: [string, string, Record<string, unknown>][] = [
    ["mux", "user_message", { text: "Is feat-cmux-next green?" }],
    ["mux", "turn_started", {}],
    ["in", "agent_thought_chunk", text("agent_thought_chunk", "Check the branch first.")],
    ...run("c1", "git status").map((msg) => ["in", msg.params.update.sessionUpdate, msg] as [string, string, any]),
    ...run("c2", "git log -1").map((msg) => ["in", msg.params.update.sessionUpdate, msg] as [string, string, any]),
    ["in", "agent_message_chunk", text("agent_message_chunk", "The branch is current; now the checks.")],
    ["in", "agent_thought_chunk", text("agent_thought_chunk", "Read every workflow file.")],
  ];
  for (let index = 1; index <= 11; index += 1)
    for (const msg of [
      update("tool_call", {
        toolCallId: `r${index}`,
        title: `Read w${index}.yml`,
        kind: "read",
        status: "in_progress",
        locations: [{ path: `w${index}.yml` }],
      }),
      update("tool_call_update", { toolCallId: `r${index}`, status: "completed" }),
    ])
      steps.push(["in", msg.params.update.sessionUpdate as string, msg]);
  steps.push(
    ...run("m1", 'tell-coordinator "op-next-replay: feat is green"').map(
      (msg) => ["in", msg.params.update.sessionUpdate, msg] as [string, string, any],
    ),
    ["in", "agent_message_chunk", text("agent_message_chunk", "Yes: every check is green.")],
    ["mux", "turn_result", { status: "completed" }],
  );
  const start = Date.UTC(2026, 9, 13, 16, 0, 0);
  return steps.map(([dir, kind, msg], index) => ({
    sessionId: "s",
    seq: index + 1,
    at: start + index * 1000,
    dir,
    kind,
    msg,
  }));
}

/// The open "Worked for" of the turn, drawn: each step line's words, in order.
async function openWorkedFor(): Promise<(string | null | undefined)[]> {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { turnView, WORKED } = await import("../src/agent-session/acpmux/conversation/turns");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  const { createRoot } = await import("react-dom/client");
  let rows: any[] = [];
  const events = turn();
  const client = AcpmuxDirectClient.replay("s", events as never, (snapshot: any) => (rows = snapshot.rows));
  client.seekReplay(events.length);

  // Text between calls is an assistant row, not a thought inside the activity.
  const thoughts = rows.flatMap((row) => (row.items ?? []).filter((item: any) => item.kind === "thought"));
  expect(thoughts.map((item: any) => item.text)).toEqual(["Check the branch first.", "Read every workflow file."]);
  expect(rows.some((row) => row.kind === "assistant" && row.text === "The branch is current; now the checks.")).toBe(
    true,
  );

  const closed = turnView(rows, new Set());
  const worked = closed.find((row) => row.kind === WORKED)!;
  const open = turnView(rows, new Set([worked.id]));
  const work = open.slice(open.indexOf(open.find((row) => row.id === worked.id)!) + 1);
  const activity = work.filter((row) => row.kind === "activity");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <>
        {activity.map((row) => (
          <ToolRows key={row.id} row={row} />
        ))}
      </>,
    ),
  );
  return [...host.querySelectorAll(".cv-tools > .cv-tool, .cv-tools > .cv-message")].map(
    (node) => node.querySelector(".cv-tool__text, .cv-thought__label, .cv-message__party.is-to")?.textContent,
  );
}

test("an open 'Worked for' lists every step, and text between calls is prose", async () => {
  expect(await openWorkedFor()).toEqual([
    "Thought for 1s",
    "Ran 2 commands",
    "Thought for 1s",
    "Read 11 files",
    "coordinator",
  ]);
  // Nothing scrolls inside the open turn: the whole list is the transcript's.
  expect(host.querySelector(".cv-tool-run")).toBeNull();
});

test("with the Debug toggle workedForFoldsRuns, an open 'Worked for' folds a run under its summary again", async () => {
  host.ownerDocument.documentElement.dataset.workedForRuns = "fold";
  try {
    // The first run folds under its summary; the second holds a message card, which never hides there.
    expect(await openWorkedFor()).toEqual(["Ran commands", "Thought for 1s", "Read 11 files", "coordinator"]);
  } finally {
    delete host.ownerDocument.documentElement.dataset.workedForRuns;
  }
});
