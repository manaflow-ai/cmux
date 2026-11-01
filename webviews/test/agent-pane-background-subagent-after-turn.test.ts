// l10n-allow-file: test fixture prompts and commands, not shipped UI.
// A background subagent's work after its parent turn ended never reads as that finished turn's
// (Leo, 2026-11-01, on a "Running grep …" row under a finished turn's reply and its footer: "why
// does it say you're still running grep", then "yes let's do that"). A Claude subagent's lines
// stream under its own session, `<chat>/<Agent call>`, which acpmux also tags them with
// (`_meta.acpmux.subagent`). Right after the hub adopted its host it lost its subagent tree until
// the subagent's next progress event, and the lines between came untagged: the pane folded the
// helper's grep as the chat's own call, after the turn's summary, and its end (tagged again)
// never reached that row. The step belongs to the helper: its own view and the running tray, by name.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";
import { subagentsIn } from "../src/agent-session/acpmux/subagents/subagentRows";
import { trayItems } from "../src/agent-session/acpmux/subagents/runningTray";

const CHAT = "0190a000-0000-7000-8000-0000000000c4";
const START = Date.UTC(2026, 10, 1, 9, 0, 0);
const HELPER_CALL = "toolu_helper";
const HELPER = `${CHAT}/${HELPER_CALL}`;
const HELPER_NAME = "Gallery: add a background axis";
const GREP = 'grep -nE "\\(fail\\)|error:|Expected|Received" /tmp/ux-gallery-bg/ci.log | head -40';

type Step = [dir: string, kind: string, msg: Record<string, unknown>];
type Params = { sessionId?: string; tag?: string; subagents?: unknown[] };
const update = (update: Record<string, unknown>, { sessionId = CHAT, tag, subagents }: Params = {}) => ({
  method: "session/update",
  params: {
    sessionId,
    update,
    ...((tag || subagents) && {
      _meta: { acpmux: { ...(tag && { subagent: tag }), ...(subagents && { subagents }) } },
    }),
  },
});
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));

const shell = (id: string, command: string, params: Params): Step => [
  "in",
  "tool_call",
  update(
    {
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: command,
      kind: "execute",
      status: "in_progress",
      rawInput: { command },
    },
    params,
  ),
];
const done = (id: string, params: Params): Step => [
  "in",
  "tool_call_update",
  update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" }, params),
];

/// A turn that started a background helper, which ran one step, then answered and ended.
const finishedTurn = (spawn: boolean): Step[] => [
  ["mux", "user_message", { text: "Add a background axis to the gallery" }],
  ["mux", "turn_started", {}],
  ...(spawn
    ? ([
        [
          "in",
          "subagent_spawned",
          update(
            { sessionUpdate: "subagent_spawned", name: HELPER_NAME, background: true },
            {
              subagents: [
                {
                  id: HELPER,
                  parent: null,
                  name: HELPER_NAME,
                  kind: "general-purpose",
                  state: "running",
                  background: true,
                },
              ],
            },
          ),
        ],
        [
          "in",
          "tool_call",
          update({
            sessionUpdate: "tool_call",
            toolCallId: HELPER_CALL,
            title: `Agent: ${HELPER_NAME}`,
            kind: "think",
            status: "in_progress",
            rawInput: { description: HELPER_NAME, prompt: "Add the axis", run_in_background: true },
          }),
        ],
        done(HELPER_CALL, {}),
        shell("ls1", "ls /tmp/ux-gallery-bg", { sessionId: HELPER, tag: HELPER }),
        done("ls1", { sessionId: HELPER, tag: HELPER }),
      ] satisfies Step[])
    : []),
  [
    "in",
    "agent_message_chunk",
    update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "I saved the note." } }),
  ],
  ["mux", "turn_result", { status: "completed" }],
];

function fakeDaemon(history: ReturnType<typeof record>) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: history.at(-1)?.seq ?? 0, events: history };
      case "_acpmux/events": {
        const after = params?.afterSeq ?? 0;
        const before = params?.beforeSeq ?? Infinity;
        const events = history.filter((event) => event.seq > after && event.seq < before);
        return { events, hasMore: false, more: false, lastSeq: history.at(-1)?.seq ?? 0 };
      }
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const push = (events: ReturnType<typeof record>) => {
    for (const event of events) {
      history.push(event);
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
    }
  };
  return { open, push };
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, snapshot: () => snapshot as { rows: AcpmuxRow[]; subagentViews: Record<string, AcpmuxRow[]> } };
}

const holdsCall = (rows: readonly AcpmuxRow[], id: string) =>
  rows.some((row) => row.items?.some((item) => item.tool?.id === id));

/// What the finished turn draws after its footer (its summary row): nothing of the helper's.
function afterFooter(rows: readonly AcpmuxRow[]): AcpmuxRow[] {
  const drawn = turnViewFrom(rows, new Set(), { now: START + 600_000, working: false, lineBelow: true }).rows;
  const footer = drawn.map((row) => row.kind).lastIndexOf("turnSummary");
  expect(footer).toBeGreaterThanOrEqual(0);
  return drawn.slice(footer + 1);
}

test("a background helper's untagged step after the turn ended is the helper's, in the tray by name", async () => {
  const daemon = fakeDaemon(record(finishedTurn(true)));
  const { client, snapshot } = await connect(daemon);
  try {
    expect(afterFooter(snapshot().rows)).toEqual([]);
    // The hub adopted its host: the helper's next lines come under its session, untagged.
    daemon.push(record([done("ls1", { sessionId: HELPER }), shell("grep1", GREP, { sessionId: HELPER })], 20));

    const { rows, subagentViews } = snapshot();
    // Not a row of the finished turn, nor anywhere in the chat's own transcript.
    expect(holdsCall(rows, "grep1")).toBe(false);
    expect(afterFooter(rows)).toEqual([]);
    // The helper's own view has it, running.
    const view = subagentViews[HELPER] ?? [];
    const step = view.flatMap((row) => row.items ?? []).find((item) => item.tool?.id === "grep1")?.tool;
    expect(step?.status).toBe("in_progress");
    // The running tray, the one separate place for background work, lists the helper by its name, with
    // the step it runs now (its tooltip), between turns.
    const agents = [...subagentsIn(rows, subagentViews).values()];
    const helper = agents.find((agent) => agent.id === HELPER);
    expect(helper?.name).toBe(HELPER_NAME);
    expect(helper?.state).toBe("running");
    expect(helper?.action).toBe(GREP);
    const tray = trayItems(agents, [], [], false);
    expect(tray.map((item) => (item.kind === "agent" ? item.agent.name : item.id))).toEqual([HELPER_NAME]);

    // Its end, tagged again, ends the step in the helper's view.
    daemon.push(record([done("grep1", { sessionId: HELPER, tag: HELPER })], 30));
    const ended = (snapshot().subagentViews[HELPER] ?? [])
      .flatMap((row) => row.items ?? [])
      .find((item) => item.tool?.id === "grep1")?.tool;
    expect(ended?.status).toBe("completed");
    expect(holdsCall(snapshot().rows, "grep1")).toBe(false);
  } finally {
    client.close();
  }
});

test("a page that starts after the helper's spawn still keeps its untagged step off the finished turn", async () => {
  // A reopened chat whose newest page holds the turn's end but not the spawn: the step's session is
  // the chat's own with a subagent part, so it is a subagent's, never the chat's.
  const daemon = fakeDaemon(record(finishedTurn(false)));
  const { client, snapshot } = await connect(daemon);
  try {
    daemon.push(record([shell("grep1", GREP, { sessionId: HELPER })], 20));
    expect(holdsCall(snapshot().rows, "grep1")).toBe(false);
    expect(afterFooter(snapshot().rows)).toEqual([]);
  } finally {
    client.close();
  }
});

test("the chat's own late call after its turn still draws as it came", async () => {
  // Only a subagent's session moves a call: the chat's own late tool update keeps its place.
  const daemon = fakeDaemon(record(finishedTurn(true)));
  const { client, snapshot } = await connect(daemon);
  try {
    daemon.push(record([shell("own1", "git status", {})], 20));
    expect(holdsCall(snapshot().rows, "own1")).toBe(true);
  } finally {
    client.close();
  }
});
