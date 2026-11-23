// l10n-allow-file: simulated chat fixtures, not shipped UI.
// A steer sits where the person sent it. Nothing that came in after the send draws above it, and
// placing it (the pane's own row at the send, acpmux's record of it, the agent reading it) never moves
// a row above it.
//
// Leo, 2026-11-22: "WHAT THE HELL? WHY DID IT FUCKING DISPLAY NOTHING THEN COPY BUTTONS THEN YOU SENT
// SHIT THEN MY STEER WENT UNDER IT THEN FUCKKKK". Earlier: "this is also a crazy situation for the
// folding and whatever the steer and you think and messages and situations come in and subagents come
// in and out".
//
// Two paths. The chat simulator (sim/README.md) replays acpmux's records, where the steer's record is
// its send: (a) a reply streams, (b) a tool runs, (c) a SendMessage call runs, (d) nothing has drawn
// yet in the turn. The live path is the pane's own row at the send and acpmux's record of it seconds
// later, with the agent's records between them: the reducer and the turn view, as the pane runs them.
import { describe, expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { runSimulation } from "../src/agent-session/acpmux/sim/run";
import { sim, type SimBuilder } from "../src/agent-session/acpmux/sim/script";
import { SUPERSEDED, turnView } from "../src/agent-session/acpmux/conversation/turns";

const STEER = "STOP BOTTLENECKING ON HUGE-BLUE";

/// The steer's record, then the agent's records after it, then the agent reading it, then more.
const read = (b: SimBuilder, after = 600) =>
  b.record("mux", "steer_read", { promptId: "steer-1" }, after, "steer_read");

const SCENARIOS: Record<string, () => SimBuilder> = {
  // (a) A reply streams when the person sends: the rest of that reply, the thought and the call after it.
  "a-reply-streams": () => {
    const b = sim("steer-a", "steer sent while a reply streams").prompt("Fix the relay");
    b.say("Looking at the relay first, then the queue it feeds and the retry", { chunks: 3 });
    b.steer(STEER, { after: 100, readAfter: false });
    b.say(" path behind it.", { chunks: 2, after: 80 })
      .think("Checking the lane broker")
      .tool("git status --short", { ms: 400 });
    return read(b).say("Moving the lane off huge-blue.").turnEnd();
  },
  // (b) A tool runs when the person sends: its end, and what comes after it.
  "b-tool-runs": () => {
    const b = sim("steer-b", "steer sent while a tool runs").prompt("Run the tests").say("Running the suite.");
    b.tool("bun test", { open: true }).steer(STEER, { after: 300, readAfter: false });
    b.toolEnd("call-1", { ms: 700 }).say("Tests pass.").tool("git push", { ms: 300 });
    return read(b).say("Off huge-blue now.").turnEnd();
  },
  // (c) A SendMessage call to another agent runs when the person sends.
  "c-send-message-runs": () => {
    const b = sim("steer-c", "steer sent while a SendMessage call runs").prompt("Tell the lanes");
    b.say("Telling interim-coord.").tool("SendMessage", { kind: "other", tool: "SendMessage", open: true });
    b.steer(STEER, { after: 300, readAfter: false });
    b.toolEnd("call-1", { ms: 600, output: "Message sent" }).say("Sent. Now the others.");
    b.tool("SendMessage", { kind: "other", tool: "SendMessage", ms: 400 });
    return read(b).say("Done.").turnEnd();
  },
  // (d) Nothing has drawn yet in the turn when the person sends.
  "d-nothing-yet": () => {
    const b = sim("steer-d", "steer sent before the turn drew anything").prompt("Fix the relay");
    b.steer(STEER, { after: 200, readAfter: false }).think("Reading both").say("On it.").tool("ls", { ms: 300 });
    return read(b).say("Moved.").turnEnd();
  },
};

const isSteer = (row: { kind: string; text?: string }) => row.kind === "user" && row.text === STEER;
/// Rows the steer's place does not decide: the footer of the stretch the steer closed (it comes with
/// the steer), and the turn's own "Working for" header, which heads the prompt's turn from its first
/// work on, whenever that comes (the header's lane, not the steer's).
const ownRow = (row: { id: string; kind: string }) => row.id.startsWith(`${SUPERSEDED}-`) || row.kind === "working";

for (const [name, make] of Object.entries(SCENARIOS)) {
  describe(`steer by send time (sim): ${name}`, () => {
    const result = runSimulation(make().build(), { rowsInTraceUpTo: 10_000 });
    const traces = result.traces.filter((trace) => trace.rows);
    const firstSeen = new Map<string, number>();
    for (const trace of traces)
      for (const row of trace.rows!) if (!firstSeen.has(row.id)) firstSeen.set(row.id, trace.step);
    const sentStep = traces.find((trace) => trace.rows!.some(isSteer))?.step;
    if (process.env.STEER_SIM_DUMP)
      for (const trace of traces)
        console.log(
          name,
          trace.step,
          trace.label,
          trace.rows!.map((row) => `${row.kind}:${row.id}${row.live ? "*" : ""}`).join(" | "),
        );

    test("the steer draws", () => {
      expect(sentStep).toBeDefined();
    });

    test("every row that came in after the send draws under the steer", () => {
      const above: string[] = [];
      for (const trace of traces) {
        if (trace.step <= sentStep! || trace.turnEnded) continue;
        const rows = trace.rows!;
        const at = rows.findIndex(isSteer);
        if (at < 0) continue;
        for (const row of rows.slice(0, at))
          if (firstSeen.get(row.id)! > sentStep! && !ownRow(row)) above.push(`${trace.label}: ${row.kind} ${row.id}`);
      }
      expect(above).toEqual([]);
    });

    test("no row above the steer moves when it lands or is read", () => {
      const moved: string[] = [];
      let before: string[] | undefined;
      for (const trace of traces) {
        if (trace.step < sentStep! || trace.turnEnded) continue;
        const rows = trace.rows!;
        const at = rows.findIndex(isSteer);
        const ids = rows
          .slice(0, at)
          .filter((row) => !ownRow(row))
          .map((row) => row.id);
        if (before && ids.join("|") !== before.join("|"))
          moved.push(`${trace.label}: [${before.join(", ")}] -> [${ids.join(", ")}]`);
        before = ids;
      }
      expect(moved).toEqual([]);
    });
  });
}

// The live path: the pane's own row at the send, the agent's records, then acpmux's record of the steer.
const CHAT = "0190a000-0000-7000-8000-00000000c7e1";
const START = Date.UTC(2026, 10, 22, 22, 0, 0);
const update = (body: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update: body },
});

function fakeDaemon(history: Record<string, unknown>[]) {
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "running",
    steering: true,
    turnCount: 1,
    turn: { turnId: "turn-1", promptId: "p-1", startedAt: START },
    updatedAt: START,
  };
  let socket: any;
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: history.length, events: history, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: history.length };
      default:
        return undefined;
    }
  };
  const connect = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        const result = answer(message.method);
        // The prompt itself is never answered here: the turn goes on.
        if (result === undefined && message.method !== "_acpmux/attach") return;
        queueMicrotask(() => socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }));
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const push = (dir: string, kind: string, msg: Record<string, unknown>) => {
    const event = { sessionId: CHAT, seq: history.length + 1, at: START + (history.length + 1) * 1000, dir, kind, msg };
    history.push(event);
    socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
  };
  return { connect, push };
}

const settle = async () => {
  for (let i = 0; i < 8; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

test("live: the steer the pane drew at the send keeps its place when acpmux records it, under what came after", async () => {
  const history: Record<string, unknown>[] = [];
  const at = (n: number) => START + n * 1000;
  const opening: [string, string, Record<string, unknown>][] = [
    ["mux", "user_message", { text: "Fix the relay", promptId: "p-1", turnId: "turn-1" }],
    ["mux", "turn_started", { turnId: "turn-1", promptId: "p-1" }],
    [
      "in",
      "agent_message_chunk",
      update({
        sessionUpdate: "agent_message_chunk",
        messageId: "m1",
        content: { type: "text", text: "Looking at the relay first." },
      }),
    ],
  ];
  opening.forEach(([dir, kind, msg], index) =>
    history.push({ sessionId: CHAT, seq: index + 1, at: at(index + 1), dir, kind, msg }),
  );
  const daemon = fakeDaemon(history);
  let rows: AcpmuxRow[] = [];
  let snap: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => {
      rows = snapshot.rows;
      snap = snapshot;
    },
    undefined,
    daemon.connect,
  );
  await settle();
  void client.send(STEER, [], "p-steer", undefined, undefined, true).catch(() => {});
  await settle();
  const drawn = () =>
    turnView(rows, new Set(), {
      working: true,
      agentFamily: "claude",
      now: Date.now(),
      clockOffset: snap?.clockOffsetMs ?? 0,
    });
  const steerAt = (list: readonly AcpmuxRow[]) => list.findIndex((row) => row.kind === "user" && row.text === STEER);
  const atSend = drawn();
  expect(steerAt(atSend)).toBeGreaterThan(0);
  const above = (list: readonly AcpmuxRow[]) =>
    list
      .slice(0, steerAt(list))
      .filter((row) => !ownRow(row))
      .map((row) => row.id);
  const aboveAtSend = above(atSend);

  // The agent goes on before acpmux's record of the steer comes (a busy daemon): a new message, a call.
  daemon.push(
    "in",
    "agent_message_chunk",
    update({
      sessionUpdate: "agent_message_chunk",
      messageId: "m2",
      content: { type: "text", text: "Now the queue." },
    }),
  );
  daemon.push(
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: "t1",
      title: "git status",
      kind: "execute",
      status: "in_progress",
      rawInput: { command: "git status" },
    }),
  );
  await settle();
  const beforeRecord = drawn();
  // Nothing that came after the send draws above it, and nothing above it moved.
  expect(above(beforeRecord)).toEqual(aboveAtSend);
  expect(beforeRecord.slice(steerAt(beforeRecord) + 1).some((row) => row.text === "Now the queue.")).toBe(true);

  // acpmux's record of the steer, then the agent reading it.
  daemon.push("mux", "user_message", {
    text: STEER,
    promptId: "p-steer",
    turnId: "turn-1",
    steer: true,
    client: "pane",
  });
  await settle();
  const recorded = drawn();
  expect(above(recorded)).toEqual(above(beforeRecord));
  expect(recorded.slice(steerAt(recorded) + 1).some((row) => row.text === "Now the queue.")).toBe(true);
  daemon.push("mux", "steer_read", { promptId: "p-steer", turnId: "turn-1" });
  daemon.push(
    "in",
    "agent_message_chunk",
    update({
      sessionUpdate: "agent_message_chunk",
      messageId: "m3",
      content: { type: "text", text: "Moving off huge-blue." },
    }),
  );
  await settle();
  const readRows = drawn();
  expect(above(readRows)).toEqual(above(beforeRecord));
  client.close?.();
});

// One harness for the numbers: after each record the pane draws, how many rows that first drew after a
// steer was sent draw above that steer. Two steers, each sent while the agent writes, each recorded by
// acpmux only after the agent wrote more; then the same chat opened again from acpmux's records (a
// reload), which has only the records.
const chunk = (id: string, text: string) =>
  update({ sessionUpdate: "agent_message_chunk", messageId: id, content: { type: "text", text } });
const call = (id: string, command: string) =>
  update({
    sessionUpdate: "tool_call",
    toolCallId: id,
    title: command,
    kind: "execute",
    status: "in_progress",
    rawInput: { command },
  });
const STEER_2 = "and keep the queue on air-blue";

async function openChat(history: Record<string, unknown>[]) {
  const daemon = fakeDaemon(history);
  const state: { rows: AcpmuxRow[]; snap: any } = { rows: [], snap: undefined };
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => {
      state.rows = snapshot.rows;
      state.snap = snapshot;
    },
    undefined,
    daemon.connect,
  );
  await settle();
  const drawn = () =>
    turnView(state.rows, new Set(), {
      working: true,
      agentFamily: "claude",
      now: Date.now(),
      clockOffset: state.snap?.clockOffsetMs ?? 0,
    });
  return { daemon, client, drawn };
}

test("live, two steers: no row that came after a send draws above that steer, at any step", async () => {
  const history: Record<string, unknown>[] = [];
  [
    ["mux", "user_message", { text: "Fix the relay", promptId: "p-1", turnId: "turn-1" }],
    ["mux", "turn_started", { turnId: "turn-1", promptId: "p-1" }],
    ["in", "agent_message_chunk", chunk("m1", "Looking at the relay first.")],
  ].forEach(([dir, kind, msg], index) =>
    history.push({ sessionId: CHAT, seq: index + 1, at: START + (index + 1) * 1000, dir, kind, msg }),
  );
  const { daemon, client, drawn } = await openChat(history);
  const firstSeen = new Map<string, number>();
  const sentAt = new Map<string, number>();
  let step = 0;
  let crossings = 0;
  const crossed: string[] = [];
  const look = () => {
    step += 1;
    const rows = drawn();
    for (const row of rows) if (!firstSeen.has(row.id)) firstSeen.set(row.id, step);
    for (const [text, sent] of sentAt) {
      const at = rows.findIndex((row) => row.kind === "user" && row.text === text);
      if (at < 0) continue;
      for (const row of rows.slice(0, at))
        if (firstSeen.get(row.id)! > sent && !ownRow(row) && row.text !== STEER && row.text !== STEER_2) {
          crossings += 1;
          crossed.push(`step ${step}: ${row.kind} "${row.text ?? row.id}" above "${text}"`);
        }
    }
  };
  look();
  void client.send(STEER, [], "p-steer", undefined, undefined, true).catch(() => {});
  await settle();
  sentAt.set(STEER, step);
  look();
  daemon.push("in", "agent_message_chunk", chunk("m2", "Now the queue."));
  await settle();
  look();
  daemon.push("in", "tool_call", call("t1", "git status"));
  await settle();
  look();
  void client.send(STEER_2, [], "p-steer-2", undefined, undefined, true).catch(() => {});
  await settle();
  sentAt.set(STEER_2, step);
  look();
  daemon.push("in", "agent_message_chunk", chunk("m3", "Checking the broker."));
  await settle();
  look();
  daemon.push("mux", "user_message", {
    text: STEER,
    promptId: "p-steer",
    turnId: "turn-1",
    steer: true,
    client: "pane",
  });
  await settle();
  look();
  daemon.push("in", "tool_call", call("t2", "ls"));
  await settle();
  look();
  daemon.push("mux", "user_message", {
    text: STEER_2,
    promptId: "p-steer-2",
    turnId: "turn-1",
    steer: true,
    client: "pane",
  });
  await settle();
  look();
  daemon.push("mux", "steer_read", { promptId: "p-steer", turnId: "turn-1" });
  daemon.push("mux", "steer_read", { promptId: "p-steer-2", turnId: "turn-1" });
  daemon.push("in", "agent_message_chunk", chunk("m4", "Moving off huge-blue."));
  await settle();
  look();
  const live = drawn().map((row) => row.id);
  console.log(`STEER_ORDER live steps=${step} crossings=${crossings}`);
  for (const line of crossed) console.log(`  ${line}`);
  client.close?.();

  // The same chat opened again from acpmux's records: each steer is where acpmux recorded it, after
  // what the agent wrote between the send and the record. A measurement, not a rule yet: the record
  // carries no place of the send (handoff, see the PR).
  const reopened = await openChat([...history]);
  const reloadRows = reopened.drawn();
  const reload = reloadRows.map((row) => row.id);
  const steerIndex = (rows: AcpmuxRow[], text: string) =>
    rows.findIndex((row) => row.kind === "user" && row.text === text);
  const above = (rows: AcpmuxRow[], text: string) =>
    rows
      .slice(0, steerIndex(rows, text))
      .filter((row) => !ownRow(row) && row.kind !== "user")
      .map((row) => row.text ?? row.id);
  console.log(
    `STEER_ORDER reload sameOrderAsLive=${live.join("|") === reload.join("|")} aboveSteer1=${JSON.stringify(above(reloadRows, STEER))} aboveSteer2=${JSON.stringify(above(reloadRows, STEER_2))}`,
  );
  reopened.client.close?.();
  expect(crossed).toEqual([]);
});
