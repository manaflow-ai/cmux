// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A steer is one continuous turn. Leo sent a message while a turn ran (⌘Return) to a session whose
// agent cannot steer: acpmux puts the prompt next (`queue_order` `next`), cancels the running turn
// (`turn_result` `cancelled`) and runs the prompt as a new turn. The transcript drew that as a Stop:
// "You stopped after 55s" over the work, "Sent now · stopped the turn" under his message, and a
// fresh "Working for 18s". He never pressed Stop; with Claude a steer does not stop the turn.
//
// - The steer draws inline in the running turn, which reads "Working for" from the first prompt.
// - The cancel the steer caused is not drawn as "You stopped after"; the steer reads "Steered".
// - Once the turn ends, its fold times the whole chain from the first prompt.
// - A real Stop still reads "You stopped after", also when a prompt is sent now after it.
// - Everything else that finds a turn by its prompt walks past a steer too (review of #22691): the
//   edited-files checkpoint spans the whole chain, Find and a shell's row open the fold the turn
//   draws, the hover footer is the chain's, running subagent groups and the minimap's turns count
//   the chain as one. "You stopped after" neither flashes between the cancel and the steer's
//   record nor comes back when an older history page ends at the steer.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { translate } from "../src/agent-session/acpmux/i18n";
import { SteerMark } from "../src/agent-session/acpmux/conversation/SteerMark";
import {
  turnFoldFor,
  turnFooterFrom,
  turnView,
  WORKED,
  WORKING,
  workedLabel,
} from "../src/agent-session/acpmux/conversation/turns";
import { turnRows } from "../src/agent-session/acpmux/diff";
import { readTurnFromRows } from "../src/agent-session/acpmux/changes/turnCheckpointSource";
import { runningGroups } from "../src/agent-session/acpmux/subagents/subagentRows";
import { SUBAGENTS } from "../src/agent-session/acpmux/subagents/subagentFold";
import { minimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";

const CHAT = "0190a000-0000-7000-8000-0000000000d3";
const START = Date.UTC(2026, 9, 20, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>, atSeconds?: number];
const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const say = (text: string, messageId: string) =>
  update({ sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } });
const call = (id: string, title: string) =>
  update({ sessionUpdate: "tool_call", toolCallId: id, title, kind: "execute", status: "completed" });

/// Records `steps`, each at its own second after START unless it names one.
const record = (steps: Step[]) => {
  let last = 0;
  return steps.map(([dir, kind, msg, atSeconds], index) => {
    last = atSeconds ?? last + 1;
    return { sessionId: CHAT, seq: index + 1, at: START + last * 1000, dir, kind, msg };
  });
};

async function rowsOf(history: ReturnType<typeof record>): Promise<AcpmuxRow[]> {
  return (await clientOf(history)).rows();
}

/// A client attached to `history`, its attach page the newest `page` events; `loadOlder` reads the rest.
async function clientOf(history: ReturnType<typeof record>, page = history.length) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "running",
    steering: false,
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
        return {
          session,
          lastSeq: history.at(-1)?.seq ?? 0,
          events: history.slice(-page),
          hasMore: page < history.length,
        };
      case "_acpmux/events": {
        const before = params?.beforeSeq ?? Infinity;
        const events = params?.kinds?.includes("transcript") ? history.filter((event) => event.seq < before) : [];
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
  let rows: AcpmuxRow[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, rows: () => rows };
}

/// Leo's prompt runs 55s; he sends a message now; acpmux stops that turn and runs his message next.
const steerChain: Step[] = [
  ["mux", "user_message", { text: "Fix the flaky login test", promptId: "p-1", turnId: "turn-1" }, 0],
  ["mux", "turn_started", { promptId: "p-1", turnId: "turn-1" }, 0],
  ["in", "tool_call", call("t-1", "bun test login"), 20],
  ["in", "agent_message_chunk", say("The retry races the session refresh.", "m-1"), 40],
  ["mux", "queued", { text: "also check the logout path", promptId: "p-2", turnId: "turn-2" }, 54],
  ["mux", "queue_order", { promptId: "p-2", order: ["p-2"], next: true }, 54],
  ["mux", "turn_result", { status: "cancelled", turnId: "turn-1" }, 55],
  ["mux", "dequeued", { promptId: "p-2" }, 55],
  ["mux", "user_message", { text: "also check the logout path", promptId: "p-2", turnId: "turn-2" }, 55],
  ["mux", "turn_started", { promptId: "p-2", turnId: "turn-2" }, 55],
  ["in", "tool_call", call("t-2", "bun test logout"), 70],
];

const steerText = (row: AcpmuxRow) => renderToStaticMarkup(<SteerMark steer={row.steer!} />);

test("a steer draws inline in the running turn, whose line counts from the first prompt", async () => {
  const rows = await rowsOf(record(steerChain));
  const view = turnView(rows, new Set(), { working: true });
  const first = view.find((row) => row.kind === "user" && row.text === "Fix the flaky login test")!;
  const steer = view.find((row) => row.kind === "user" && row.text === "also check the logout path")!;
  // One running turn: one Working line, timed from the first prompt.
  const working = view.filter((row) => row.kind === WORKING);
  expect(working).toHaveLength(1);
  expect(working[0]!.at).toBe(first.at);
  expect(view.indexOf(working[0]!)).toBeLessThan(view.indexOf(steer));
  // Nothing says the turn was stopped.
  expect(view.some((row) => row.kind === "turnSummary" && row.status === "cancelled")).toBe(false);
  expect(view.some((row) => row.kind === WORKED && row.status === "cancelled")).toBe(false);
  expect(steer.steer).toBe("landed");
  expect(steerText(steer)).toContain(translate("steer.landed"));
});

test("once the chain ends, its fold reads Worked for, timed from the first prompt", async () => {
  const rows = await rowsOf(
    record([
      ...steerChain,
      ["in", "agent_message_chunk", say("Both paths are fixed.", "m-2"), 80],
      ["mux", "turn_result", { status: "completed", turnId: "turn-2" }, 80],
    ]),
  );
  const view = turnView(rows, new Set());
  const worked = view.filter((row) => row.kind === WORKED);
  expect(worked).toHaveLength(1);
  expect(worked[0]!.status).not.toBe("cancelled");
  expect(worked[0]!.durationMs).toBe(80_000);
  expect(workedLabel(translate, worked[0]!)).toBe(translate("turn.worked", { time: "1m 20s" }));
  // The steer still shows, between the fold and the answer.
  const steer = view.findIndex((row) => row.kind === "user" && row.text === "also check the logout path");
  const answer = view.findIndex((row) => row.kind === "assistant" && row.text === "Both paths are fixed.");
  expect(steer).toBeGreaterThan(view.indexOf(worked[0]!));
  expect(steer).toBeLessThan(answer);
  expect(view.filter((row) => row.kind === "turnSummary")).toHaveLength(1);
});

test("a real Stop still reads You stopped after", async () => {
  const rows = await rowsOf(
    record([
      ["mux", "user_message", { text: "Fix the flaky login test", promptId: "p-1", turnId: "turn-1" }, 0],
      ["mux", "turn_started", { promptId: "p-1", turnId: "turn-1" }, 0],
      ["in", "tool_call", call("t-1", "bun test login"), 20],
      ["mux", "turn_result", { status: "cancelled", turnId: "turn-1" }, 40],
      ["mux", "user_message", { text: "try again", promptId: "p-2", turnId: "turn-2" }, 60],
      ["mux", "turn_started", { promptId: "p-2", turnId: "turn-2" }, 60],
      ["in", "tool_call", call("t-2", "bun test login --retry"), 70],
    ]),
  );
  const view = turnView(rows, new Set(), { working: true });
  const stopped = view.find((row) => row.kind === WORKED)!;
  expect(stopped.status).toBe("cancelled");
  expect(workedLabel(translate, stopped)).toBe(translate("turn.stopped", { time: "40s" }));
  const working = view.find((row) => row.kind === WORKING);
  expect(working?.at).toBe(START + 60_000);
});

test("a prompt sent now after a real Stop leaves the Stop as it was", async () => {
  // Stop ended the turn; then Send now on a queued prompt with no turn running (acpmux `next`).
  const rows = await rowsOf(
    record([
      ["mux", "user_message", { text: "Fix the flaky login test", promptId: "p-1", turnId: "turn-1" }, 0],
      ["mux", "turn_started", { promptId: "p-1", turnId: "turn-1" }, 0],
      ["in", "tool_call", call("t-1", "bun test login"), 20],
      ["mux", "queued", { text: "then the logout path", promptId: "p-2", turnId: "turn-2" }, 30],
      ["mux", "turn_result", { status: "cancelled", turnId: "turn-1" }, 40],
      ["mux", "queue_order", { promptId: "p-2", order: ["p-2"], next: true }, 50],
      ["mux", "dequeued", { promptId: "p-2" }, 50],
      ["mux", "user_message", { text: "then the logout path", promptId: "p-2", turnId: "turn-2" }, 50],
      ["mux", "turn_started", { promptId: "p-2", turnId: "turn-2" }, 50],
      ["in", "tool_call", call("t-2", "bun test logout"), 60],
    ]),
  );
  const view = turnView(rows, new Set(), { working: true });
  expect(view.find((row) => row.kind === WORKED)?.status).toBe("cancelled");
  const next = view.find((row) => row.kind === "user" && row.text === "then the logout path")!;
  expect(next.steer).toBeUndefined();
  expect(view.find((row) => row.kind === WORKING)?.at).toBe(START + 50_000);
});

/// The chain ended: the steer's work, then the answer and the turn's own end. Each summary carries
/// the checkpoints acpmux took (`checkpointId` before the prompt, `endCheckpointId` at the end).
const endedChain: Step[] = [
  ...steerChain.map((step): Step =>
    step[1] === "turn_result"
      ? [step[0], step[1], { ...step[2], checkpointId: "cp-a", endCheckpointId: "cp-b" }, step[3]]
      : step,
  ),
  ["in", "agent_message_chunk", say("Both paths are fixed.", "m-2"), 80],
  ["mux", "turn_result", { status: "completed", turnId: "turn-2", checkpointId: "cp-c", endCheckpointId: "cp-d" }, 80],
];
const rowWith = (rows: AcpmuxRow[], toolId: string) =>
  rows.find((row) => row.items?.some((item) => item.tool?.id === toolId))!;

test("the edited files after a steer belong to the chain, and its checkpoint spans the chain", async () => {
  const rows = await rowsOf(record(endedChain));
  const after = rowWith(rows, "t-2");
  const turn = turnRows(rows, after.id);
  expect(turn[0]?.text).toBe("Fix the flaky login test");
  expect(turn.some((row) => row.items?.some((item) => item.tool?.id === "t-1"))).toBe(true);
  expect(turn.filter((row) => row.kind === "turnSummary")).toHaveLength(2);
  const asked: string[][] = [];
  const read = await readTurnFromRows(rows, after.id, async (from, to) => {
    asked.push([from, to]);
    return { complete: true };
  });
  expect(asked).toEqual([["cp-a", "cp-d"]]);
  expect(read && "checkpoint_id" in read ? read.checkpoint_id : undefined).toBe("cp-a..cp-d");
});

test("a native steer's turn has ended once its one summary comes, and its edits span the steer", async () => {
  let at = START;
  const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    kind,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const rows = [
    row("u", "user", { text: "Refactor the parser" }),
    row("a1", "activity", {
      items: [{ kind: "tool", text: "", tool: { id: "e1", title: "Edit a.ts", kind: "edit", status: "completed" } }],
    }),
    row("s", "user", { text: "use the cache dir", steer: "landed" }),
    row("a2", "activity", {
      items: [{ kind: "tool", text: "", tool: { id: "e2", title: "Edit b.ts", kind: "edit", status: "completed" } }],
    }),
    row("sum", "turnSummary", { status: "completed", checkpoint: { from: "cp-1", to: "cp-2" } }),
  ];
  expect(turnRows(rows, "a1").map((each) => each.id)).toEqual(["u", "a1", "s", "a2", "sum"]);
  const read = await readTurnFromRows(rows, "a1", async () => ({ complete: true }));
  expect(read && "checkpoint_id" in read ? read.checkpoint_id : undefined).toBe("cp-1..cp-2");
  // Running groups of the turn, and the minimap's one turn.
  const group = row("g", SUBAGENTS, { subagents: [{ id: "x", name: "x", state: "running" } as any] });
  expect(runningGroups([rows[0]!, group, rows[2]!, rows[3]!])).toEqual(["g"]);
  expect(minimapTurns(rows).turns).toHaveLength(1);
});

test("Find and a shell's row open the fold the turn draws, and the hover footer is the chain's", async () => {
  const rows = await rowsOf(record(endedChain));
  const first = rows.find((row) => row.kind === "user")!;
  const index = rows.indexOf(rowWith(rows, "t-2"));
  expect(turnFoldFor(rows, index)).toBe(`${WORKED}-${first.id}`);
  const view = turnView(rows, new Set());
  expect(view.some((row) => row.id === turnFoldFor(rows, index))).toBe(true);
  let footer = view[view.length - 1]!;
  for (let at = view.length - 1; at >= 0; at -= 1)
    if (view[at]!.kind === "turnSummary") {
      footer = view[at]!;
      break;
    }
  expect(turnFooterFrom(view, view.indexOf(first))).toBe(footer.id);
});

test("between the cancel and the steer's record, the turn does not read as stopped", async () => {
  const cut = record(steerChain.slice(0, 7));
  const rows = await rowsOf(cut);
  for (const working of [true, false]) {
    const view = turnView(rows, new Set(), { working });
    expect(view.some((row) => row.kind === WORKED && row.status === "cancelled")).toBe(false);
    expect(view.some((row) => row.kind === "turnSummary" && row.status === "cancelled")).toBe(false);
  }
});

test("an older history page that ends at the steer leaves it a steer", async () => {
  const history = record(endedChain);
  // The open page starts at the sent-now prompt; the cancel it caused is in the older page.
  const from = history.findIndex((event) => event.kind === "user_message" && event.msg.promptId === "p-2");
  const { client, rows } = await clientOf(history, history.length - from);
  await client.loadOlder();
  const steer = rows().find((row) => row.kind === "user" && row.text === "also check the logout path")!;
  expect(steer.steer).toBe("landed");
  const view = turnView(rows(), new Set());
  expect(view.some((row) => row.kind === WORKED && row.status === "cancelled")).toBe(false);
  expect(view.filter((row) => row.kind === WORKED)).toHaveLength(1);
});
