// l10n-allow-file: test fixture prompts and harness names, not shipped UI.
// A compaction and a failover are noted in the transcript where they happened. Before, acpmux's
// Claude translator dropped `compact_boundary` (only the context ring reset) and no client drew
// acpmux's `failover` record, so a chat that compacted, or moved to another harness after a usage
// limit, went on with nothing in the transcript saying so.
import { expect, jest, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxCompaction, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { CompactionNote, compactTokens } from "../src/agent-session/acpmux/conversation/CompactionNote";
import { translate } from "../src/agent-session/acpmux/i18n";

const CHAT = "0190a000-0000-7000-8000-0000000000c7";
const START = Date.UTC(2026, 9, 18, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>, hostSeq?: number];
const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg, hostSeq], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
    hostSeq,
  }));

/// A daemon over a fake socket: attach answers with `history`'s newest `page` events; `push` sends live ones.
/// An older read answers with at most `older` events, newest first, and says whether more are left.
function fakeDaemon(history: ReturnType<typeof record>, page = history.length, older = Infinity) {
  let socket: any;
  const sent: string[] = [];
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "running",
    turnCount: 1,
    updatedAt: START,
  };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
        };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: history.at(-1)?.seq ?? 0, events: history.slice(-page) };
      case "_acpmux/events": {
        const before = params?.beforeSeq ?? Infinity;
        const after = params?.afterSeq ?? 0;
        const found = history.filter((event) => event.seq > after && event.seq < before);
        const events = before === Infinity ? found : found.slice(-older);
        const more = events.length < found.length;
        return { events, hasMore: more, more, lastSeq: history.at(-1)?.seq ?? 0 };
      }
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        sent.push(raw);
        const message = JSON.parse(raw);
        if (message.id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({
                jsonrpc: "2.0",
                id: message.id,
                result: answer(message.method, message.params),
              }),
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
      socket.onmessage?.({
        data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }),
      });
    }
  };
  const lag = () =>
    socket.onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { sessionIds: [CHAT] } }),
    });
  return { open, push, sent, lag };
}

async function connect(daemon: ReturnType<typeof fakeDaemon>, onConnection?: (connection: string) => void) {
  let rows: AcpmuxRow[] = [];
  let working = false;
  let stopping = false;
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      token: "t",
      sessionId: CHAT,
    },
    (snapshot: any) => {
      rows = snapshot.rows;
      working = snapshot.isWorking === true;
      stopping = snapshot.stopping === true;
      onConnection?.(snapshot.connection);
    },
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, rows: () => rows, working: () => working, stopping: () => stopping };
}
test("a compaction is one row: running, then how it ended", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "go on" }],
      ["mux", "turn_started", {}],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running", reason: "account_switch" })],
    ]),
  );
  const { rows } = await connect(daemon);
  const compactions = () => rows().filter((row) => row.kind === "compaction");
  expect(compactions().map((row) => row.compaction)).toEqual([{ state: "running", reason: "account_switch" }]);
  const id = compactions()[0]!.id;
  daemon.push(
    record(
      [
        [
          "in",
          "compaction",
          update({
            sessionUpdate: "compaction",
            state: "completed",
            trigger: "manual",
            reason: "account_switch",
            preTokens: 27183,
            postTokens: 2047,
          }),
        ],
        // The summary is context for a handoff, not a row.
        ["in", "compaction_summary", update({ sessionUpdate: "compaction_summary", text: "Summary: PLUM-42" })],
      ],
      4,
    ),
  );
  expect(compactions().map((row) => [row.id, row.compaction])).toEqual([
    [id, { state: "completed", reason: "account_switch", preTokens: 27183, postTokens: 2047 }],
  ]);
  expect(rows().some((row) => (row.text ?? "").includes("PLUM-42"))).toBe(false);

  // The next compaction gets its own row.
  daemon.push(record([["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })]], 6));
  expect(compactions().map((row) => row.compaction?.state)).toEqual(["completed", "running"]);
});

test("a failover to the fallback harness is noted", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "keep going" }],
      ["mux", "turn_started", {}],
      ["mux", "failover", { from: "claude-sr2", to: "codex", reason: "Claude AI usage limit reached", turnId: "t1" }],
    ]),
  );
  const { rows } = await connect(daemon);
  expect(
    rows()
      .filter((row) => row.kind === "failover")
      .map((row) => row.failover),
  ).toEqual([{ from: "claude-sr2", to: "codex" }]);
});

test("token counts read as thousands", () => {
  expect([27183, 2047, 999, 1000, 412000].map(compactTokens)).toEqual(["27k", "2k", "999", "1k", "412k"]);
});

test("a compaction its turn ended without finishing settles as failed; the next one gets its own", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "/compact" }],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
      ["mux", "turn_result", { status: "cancelled" }],
      ["mux", "user_message", { text: "go on" }],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running", reason: "account_switch" })],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "completed", reason: "account_switch" })],
    ]),
  );
  const { rows } = await connect(daemon);
  expect(
    rows()
      .filter((row) => row.kind === "compaction")
      .map((row) => [row.seq, row.compaction?.state]),
  ).toEqual([
    [2, "failed"],
    [5, "completed"],
  ]);
});

test("a live compaction stops running when its turn ends or the next turn starts", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "/compact" }],
      ["mux", "turn_started", {}],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running", reason: "account_switch" })],
    ]),
  );
  const { rows } = await connect(daemon);
  const states = () =>
    rows()
      .filter((row) => row.kind === "compaction")
      .map((row) => row.compaction);
  expect(states()).toEqual([{ state: "running", reason: "account_switch" }]);
  // The agent process exits mid-compaction: acpmux ends the turn.
  daemon.push(record([["mux", "turn_result", { status: "failed" }]], 4));
  expect(states()).toEqual([{ state: "failed", inferred: true, reason: "account_switch" }]);

  // A harness that starts the next turn without ending this one's compaction.
  daemon.push(
    record(
      [
        ["mux", "user_message", { text: "go on" }],
        ["mux", "turn_started", {}],
        ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
        ["mux", "user_message", { text: "and on", steer: true }],
        ["mux", "turn_started", {}],
      ],
      5,
    ),
  );
  expect(states()?.map((compaction) => compaction?.state)).toEqual(["failed", "failed"]);
});

test("a compaction that ends after a forced Stop ended its turn stays one row", async () => {
  const steps: Step[] = [
    ["mux", "user_message", { text: "/compact" }],
    ["mux", "turn_started", {}],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    // Claude did not answer Stop in time: acpmux ended the turn itself.
    ["mux", "turn_result", { status: "cancelled", cancelForced: true }],
  ];
  const late: Step = [
    "in",
    "compaction",
    update({ sessionUpdate: "compaction", state: "completed", preTokens: 27183, postTokens: 2047 }),
  ];
  const compactions = (rows: AcpmuxRow[]) =>
    rows.filter((row) => row.kind === "compaction").map((row) => [row.seq, row.compaction?.state]);

  // Live: the row reads as failed at the forced end, then the late boundary replaces it.
  const daemon = fakeDaemon(record(steps));
  const live = await connect(daemon);
  expect(compactions(live.rows())).toEqual([[3, "failed"]]);
  daemon.push(record([late], 5));
  expect(compactions(live.rows())).toEqual([[3, "completed"]]);

  // Reload: the same history gives the same one row.
  const reloaded = await connect(fakeDaemon(record([...steps, late])));
  expect(compactions(reloaded.rows())).toEqual([[3, "completed"]]);
});

test("a compacting forced Stop is one notice and exposes Continue after the matching result", async () => {
  const forced = {
    status: "cancelled",
    stopReason: "cancelled",
    cancelForced: true,
    turnId: "turn-1",
    turnSeq: 2,
    promptId: "prompt-1",
  };
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "continue the migration", promptId: "prompt-1", turnId: "turn-1" }],
      ["mux", "turn_started", { turnId: "turn-1", turnSeq: 2, promptId: "prompt-1" }],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    ]),
  );
  const { client, rows } = await connect(daemon);
  await client.cancel();
  await client.cancel();
  expect(daemon.sent.filter((raw) => JSON.parse(raw).method === "session/cancel")).toHaveLength(1);
  // A compacting Stop settles only when acpmux publishes its terminal result; the GUI must not
  // manufacture a forced-end notice or Continue while that result is still in flight.
  expect(rows().filter((row) => row.kind === "notice" && row.text === translate("stop.forced"))).toHaveLength(0);
  expect(turnView(rows(), new Set(), { now: START + 30_000 }).some((row) => row.resumable)).toBe(false);
  daemon.push(
    record(
      [
        ["mux", "turn_result", forced],
        // A replay from the peer journal has a new seq but the same daemon turn identity.
        ["mux", "turn_result", forced],
      ],
      4,
    ),
  );
  const notices = () => rows().filter((row) => row.kind === "notice" && row.text === translate("stop.forced"));
  expect(notices()).toHaveLength(1);
  const summaries = turnView(rows(), new Set(), { now: START + 30_000 }).filter((row) => row.kind === "turnSummary");
  expect(summaries).toHaveLength(1);
  expect(summaries[0]?.resumable).toBe(true);

  // A newer turn may already be compacting when a journal replay of the old forced result lands.
  // The old result must not settle or close that newer turn.
  daemon.push(
    record(
      [
        ["mux", "user_message", { text: "new turn", promptId: "prompt-2", turnId: "turn-2" }],
        ["mux", "turn_started", { turnId: "turn-2", turnSeq: 3, promptId: "prompt-2" }],
        ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
      ],
      6,
    ),
  );
  const compactions = () => rows().filter((row) => row.kind === "compaction");
  expect(compactions().at(-1)?.compaction?.state).toBe("running");
  daemon.push(record([["mux", "turn_result", forced]], 9));
  expect(compactions().at(-1)?.compaction?.state).toBe("running");
  client.close();
});

test("compaction fences rebuild chronologically when replay seeks backward and forward", async () => {
  const history = record([
    ["mux", "user_message", { text: "legacy history" }],
    ["mux", "turn_started", {}],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "completed" })],
    ["mux", "turn_result", { status: "completed" }],
    ["mux", "user_message", { text: "stop this", turnId: "turn-old" }],
    ["mux", "turn_started", { turnId: "turn-old" }],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    ["mux", "turn_result", { turnId: "turn-old", status: "cancelled", cancelForced: true }],
    ["mux", "user_message", { text: "new prompt", turnId: "turn-new" }],
    ["mux", "turn_started", { turnId: "turn-new" }],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
  ]);
  let rows: AcpmuxRow[] = [];
  const replay = AcpmuxDirectClient.replay(CHAT, history, (snapshot) => {
    rows = snapshot.rows;
  });
  const visible = (items: AcpmuxRow[]) =>
    items
      .filter((row) => row.kind === "compaction" || row.kind === "turnSummary")
      .map((row) => [row.id, row.turnId, row.compaction, row.status]);
  replay.seekReplay(12);
  const forward = visible(rows);
  replay.seekReplay(5);
  expect(visible(rows)).toEqual([
    ["compaction-3", undefined, { state: "completed" }, undefined],
    ["summary-5", undefined, undefined, "completed"],
  ]);
  replay.seekReplay(12);
  expect(visible(rows)).toEqual(forward);
  const live = await connect(fakeDaemon(history));
  try {
    expect(visible(live.rows())).toEqual(forward);
  } finally {
    live.client.close();
  }
});

test("loading a retired compaction above a new turn matches whole-history reduction", async () => {
  const history = record([
    ["mux", "user_message", { text: "old prompt", turnId: "turn-old" }],
    ["mux", "turn_started", { turnId: "turn-old" }],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    ["mux", "turn_result", { turnId: "turn-old", status: "cancelled", cancelForced: true }],
    ["mux", "user_message", { text: "new prompt", turnId: "turn-new" }],
    ["mux", "turn_started", { turnId: "turn-new" }],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
  ]);
  const wholeDaemon = fakeDaemon([...history]);
  const pagedDaemon = fakeDaemon([...history], 3);
  const whole = await connect(wholeDaemon);
  const paged = await connect(pagedDaemon);
  const compactions = (rows: AcpmuxRow[]) =>
    rows.filter((row) => row.kind === "compaction").map((row) => [row.id, row.turnId, row.compaction]);
  try {
    await paged.client.loadOlder();
    expect(compactions(paged.rows())).toEqual(compactions(whole.rows()));
    expect(compactions(paged.rows())).toEqual([
      ["compaction-3", "turn-old", { state: "failed", inferred: true }],
      ["compaction-7", "turn-new", { state: "running" }],
    ]);
    const late = record(
      [
        ["in", "compaction", update({ sessionUpdate: "compaction", state: "completed" })],
        ["mux", "turn_end", {}],
        ["mux", "turn_result", { turnId: "turn-new", status: "completed" }],
      ],
      8,
    );
    wholeDaemon.push(late);
    pagedDaemon.push(late);
    expect(compactions(paged.rows())).toEqual(compactions(whole.rows()));
  } finally {
    whole.client.close();
    paged.client.close();
  }
});

test("a stale cancelled result cannot cancel the newer turn's foreground subagent", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "old prompt", turnId: "turn-old" }],
      ["mux", "turn_started", { turnId: "turn-old" }],
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    await client.cancel();
    daemon.push(
      record(
        [
          ["mux", "user_message", { text: "new prompt", turnId: "turn-new" }],
          ["mux", "turn_started", { turnId: "turn-new" }],
          [
            "in",
            "subagent_spawned",
            {
              method: "session/update",
              params: {
                update: { sessionUpdate: "subagent_spawned" },
                _meta: {
                  acpmux: {
                    subagents: [
                      {
                        id: "new-reviewer",
                        parent: null,
                        name: "Reviewer",
                        state: "running",
                        toolCallId: "review-call",
                      },
                    ],
                  },
                },
              },
            },
          ],
        ],
        3,
      ),
    );
    const agents = () =>
      rows()
        .filter((row) => row.kind === "subagents")
        .flatMap((row) => row.subagents ?? []);
    expect(agents().map((agent) => [agent.id, agent.state])).toEqual([["new-reviewer", "running"]]);
    const before = agents();
    daemon.push(record([["mux", "turn_result", { turnId: "turn-old", status: "cancelled" }]], 6));
    expect(agents()).toEqual(before);
    daemon.push(record([["mux", "turn_result", { turnId: "turn-new", status: "cancelled" }]], 7));
    expect(agents().map((agent) => [agent.id, agent.state])).toEqual([["new-reviewer", "cancelled"]]);
  } finally {
    client.close();
  }
});

test("an old Stop result clears its cancel without settling the newer turn or blocking send-now", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "old prompt", turnId: "turn-old" }],
      ["mux", "turn_started", { turnId: "turn-old" }],
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    await client.cancel();
    daemon.push(
      record(
        [
          ["mux", "user_message", { text: "new prompt", turnId: "turn-new" }],
          ["mux", "turn_started", { turnId: "turn-new" }],
          ["in", "agent_message_chunk", update({ content: { type: "text", text: "New work" } })],
        ],
        3,
      ),
    );
    const before = rows();
    daemon.push(record([["mux", "turn_result", { turnId: "turn-old", status: "cancelled" }]], 6));
    expect(rows()).toEqual(before);
    daemon.push(
      record(
        [
          ["mux", "queued", { promptId: "queued-next", text: "send this now" }],
          ["mux", "queue_order", { promptId: "queued-next", next: true, order: ["queued-next"] }],
          ["mux", "turn_result", { turnId: "turn-new", status: "cancelled" }],
        ],
        7,
      ),
    );
    expect(rows().find((row) => row.id === "summary-turn-new")?.continued).toBe(true);
    // An unscoped subsequent turn must also accept its own Stop after the old Stop was answered.
    daemon.push(
      record(
        [
          ["mux", "user_message", { text: "legacy next" }],
          ["mux", "turn_started", {}],
        ],
        10,
      ),
    );
    await client.cancel();
    expect(daemon.sent.map((raw) => JSON.parse(raw)).filter((msg) => msg.method === "session/cancel")).toHaveLength(2);
  } finally {
    client.close();
  }
});

test("a prompt without a turn ID still fences a retired compaction", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "old prompt", turnId: "turn-old" }],
      ["mux", "turn_started", { turnId: "turn-old" }],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
      ["mux", "turn_result", { turnId: "turn-old", status: "cancelled", cancelForced: true }],
      ["mux", "user_message", { text: "next prompt without identity" }],
      ["mux", "turn_started", {}],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const before = rows();
    daemon.push(
      record(
        [
          ["in", "compaction", update({ sessionUpdate: "compaction", state: "completed" })],
          ["mux", "turn_end", {}],
          ["mux", "turn_result", { status: "completed" }],
        ],
        8,
      ),
    );
    expect(rows()).toEqual(before);
    expect(
      rows()
        .filter((row) => row.kind === "compaction")
        .map((row) => row.compaction?.state),
    ).toEqual(["failed", "running"]);
  } finally {
    client.close();
  }
});

for (const terminal of ["turn_end", "turn_result"])
  test(`a forced Stop without compaction preserves the next legacy ${terminal}`, async () => {
    const daemon = fakeDaemon(
      record([
        // An older inferred compaction must not make this ordinary Stop look like compaction.
        ["mux", "user_message", { text: "older prompt", turnId: "turn-older" }],
        ["mux", "turn_started", { turnId: "turn-older" }],
        ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
        ["mux", "turn_result", { turnId: "turn-older", status: "completed" }],
        ["mux", "user_message", { text: "ordinary prompt", turnId: "turn-old" }],
        ["mux", "turn_started", { turnId: "turn-old" }],
        ["mux", "turn_result", { turnId: "turn-old", status: "cancelled", cancelForced: true }],
        ["mux", "user_message", { text: "new prompt", turnId: "turn-new" }],
        ["mux", "turn_started", { turnId: "turn-new" }],
        ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
      ]),
    );
    const { client, rows } = await connect(daemon);
    try {
      daemon.push(record([["mux", terminal, { status: "completed" }]], 11));
      expect(rows().some((row) => row.kind === "typing")).toBe(false);
      expect(
        rows()
          .filter((row) => row.kind === "compaction")
          .at(-1)?.compaction?.state,
      ).toBe("failed");
    } finally {
      client.close();
    }
  });

test("a legacy turn_end answers an unidentified Stop, so the next turn's Stop is sent", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "legacy prompt" }],
      ["mux", "turn_started", {}],
    ]),
  );
  const { client } = await connect(daemon);
  const cancels = () => daemon.sent.filter((raw) => JSON.parse(raw).method === "session/cancel").length;
  try {
    await client.cancel();
    expect(cancels()).toBe(1);
    daemon.push(record([["mux", "turn_end", { status: "cancelled" }]], 3));
    daemon.push(
      record(
        [
          ["mux", "user_message", { text: "next legacy prompt" }],
          ["mux", "turn_started", {}],
        ],
        4,
      ),
    );
    await client.cancel();
    expect(cancels()).toBe(2);
  } finally {
    client.close();
  }
});

for (const action of ["stop", "send-now"])
  test(`Stop before its late opener keeps the same turn identity (${action})`, async () => {
    const daemon = fakeDaemon([]);
    const { client, rows, working, stopping } = await connect(daemon);
    try {
      expect(working()).toBe(true);
      await client.cancel();
      daemon.push(
        record([
          ["mux", "user_message", { text: "late prompt", turnId: "turn-late" }],
          ["mux", "turn_started", { turnId: "turn-late" }],
        ]),
      );
      if (action === "stop") {
        await client.cancel();
        expect(daemon.sent.filter((raw) => JSON.parse(raw).method === "session/cancel")).toHaveLength(1);
      } else {
        daemon.push(
          record(
            [
              ["mux", "queued", { promptId: "p-now", text: "send now" }],
              ["mux", "queue_order", { promptId: "p-now", next: true, order: ["p-now"] }],
            ],
            3,
          ),
        );
      }
      expect(stopping()).toBe(true);
      daemon.push(record([["mux", "turn_result", { status: "cancelled", turnId: "turn-late" }]], 5));
      expect(rows().find((row) => row.id === "summary-turn-late")?.continued).toBeUndefined();
      // The fake daemon's summary keeps saying running (it sends no session change), so the Stop
      // settling is what this turn's result shows here, not isWorking.
      expect(stopping()).toBe(false);
    } finally {
      client.close();
    }
  });

for (const mode of ["loadOlder", "lag"])
  for (const expired of [false, true])
    test(`historical turn starts preserve Stop ${expired ? "after" : "before"} the old grace during ${mode}`, async () => {
      const history = record([
        ["mux", "user_message", { text: "historical prompt", turnId: "turn-history" }],
        ["mux", "turn_started", { turnId: "turn-history" }],
        ["mux", "turn_result", { status: "completed", turnId: "turn-history" }],
        ["mux", "user_message", { text: "current prompt", turnId: "turn-current" }],
        ["mux", "turn_started", { turnId: "turn-current" }],
      ]);
      const daemon = fakeDaemon(history, mode === "loadOlder" ? 2 : history.length);
      let resynced: (() => void) | undefined;
      const { client, rows, working } = await connect(daemon, (connection) => {
        if (connection === "resynced") resynced?.();
      });
      const notices = () => rows().filter((row) => row.id === "notice-stop-turn-current");
      jest.useFakeTimers();
      try {
        await client.cancel();
        if (expired) jest.advanceTimersByTime(5_001);
        expect(working()).toBe(true);
        if (mode === "loadOlder") await client.loadOlder();
        else {
          const settled = new Promise<void>((resolve) => {
            resynced = resolve;
          });
          daemon.lag();
          await settled;
        }
        expect(working()).toBe(true);
        // The folded history must restore the current identity: a second Stop is still deduped.
        await client.cancel();
        expect(daemon.sent.filter((raw) => JSON.parse(raw).method === "session/cancel")).toHaveLength(1);
        if (!expired) {
          jest.advanceTimersByTime(5_001);
          expect(notices()).toHaveLength(0);
        }
        expect(working()).toBe(true);
        daemon.push(
          record([["mux", "turn_result", { status: "cancelled", turnId: "turn-current", cancelForced: true }]], 6),
        );
        expect(notices()).toHaveLength(1);
      } finally {
        client.close();
        jest.useRealTimers();
      }
    });

for (const oldTurnId of ["turn-old", undefined])
  for (const action of ["stop", "send-now"])
    test(`a pending Stop leaves a new known turn usable (${oldTurnId ?? "unknown"}, ${action})`, async () => {
      const daemon = fakeDaemon(
        record([
          ["mux", "user_message", { text: "old prompt", turnId: oldTurnId }],
          ["mux", "turn_started", { turnId: oldTurnId }],
        ]),
      );
      const { client, working, rows } = await connect(daemon);
      jest.useFakeTimers();
      try {
        await client.cancel();
        jest.advanceTimersByTime(5_001);
        expect(working()).toBe(true);
        daemon.push(
          record(
            [
              ["mux", "user_message", { text: "new prompt", turnId: "turn-new" }],
              ["mux", "turn_started", { turnId: "turn-new" }],
            ],
            3,
          ),
        );
        expect(working()).toBe(true);
        if (action === "stop") {
          await client.cancel();
          expect(daemon.sent.filter((raw) => JSON.parse(raw).method === "session/cancel")).toHaveLength(2);
        } else {
          daemon.push(
            record(
              [
                ["mux", "queued", { promptId: "p-now", text: "send now" }],
                ["mux", "queue_order", { promptId: "p-now", next: true, order: ["p-now"] }],
                ["mux", "turn_result", { status: "cancelled", turnId: "turn-new" }],
              ],
              5,
            ),
          );
          expect(rows().find((row) => row.id === "summary-turn-new")?.continued).toBe(true);
        }
      } finally {
        client.close();
        jest.useRealTimers();
      }
    });

for (const turnId of ["turn-grace", undefined])
  test(`only the authoritative Stop result draws one notice (${turnId ?? "unknown identity"})`, async () => {
    const daemon = fakeDaemon(
      record([
        ["mux", "user_message", { text: "work", turnId }],
        ["mux", "turn_started", { turnId }],
      ]),
    );
    const { client, rows } = await connect(daemon);
    const notices = () => rows().filter((row) => row.kind === "notice" && row.text === translate("stop.forced"));
    jest.useFakeTimers();
    try {
      await client.cancel();
      jest.advanceTimersByTime(5_001);
      expect(notices()).toHaveLength(0);
      const result = { turnId: "turn-grace", status: "cancelled", cancelForced: true };
      daemon.push(record([["mux", "turn_result", result]], 3));
      daemon.push(record([["mux", "turn_result", result]], 4));
      expect(notices()).toHaveLength(1);
      expect(notices()[0]?.id).toBe("notice-stop-turn-grace");
    } finally {
      client.close();
      jest.useRealTimers();
    }
  });

// Review at e0eaed50 (P2): a Stop bound to a known turn does not cover a later turn that names none;
// that turn's Stop is sent.
test("a Stop of a known turn does not swallow the next unnamed turn's Stop", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "first", turnId: "turn-old" }],
      ["mux", "turn_started", { turnId: "turn-old" }],
    ]),
  );
  const { client } = await connect(daemon);
  const cancels = () => daemon.sent.filter((raw) => JSON.parse(raw).method === "session/cancel").length;
  try {
    await client.cancel();
    expect(cancels()).toBe(1);
    daemon.push(
      record(
        [
          ["mux", "user_message", { text: "legacy next" }],
          ["mux", "turn_started", {}],
        ],
        3,
      ),
    );
    await client.cancel();
    expect(cancels()).toBe(2);
  } finally {
    client.close();
  }
});

// Review at 141de3a4 (P2): behind the compaction fence, a turn whose opener named no turn ends on its
// own named result.
test("a fenced turn opened without an id ends on its own named result", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "old prompt", turnId: "turn-old" }],
      ["mux", "turn_started", { turnId: "turn-old" }],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
      ["mux", "turn_result", { turnId: "turn-old", status: "cancelled", cancelForced: true }],
      ["mux", "user_message", { text: "next prompt" }],
      ["mux", "turn_started", {}],
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    daemon.push(record([["mux", "turn_result", { turnId: "turn-b", status: "completed" }]], 7));
    expect(rows().some((row) => row.kind === "typing")).toBe(false);
    expect(rows().some((row) => row.id === "summary-turn-b")).toBe(true);
  } finally {
    client.close();
  }
});

// Review at 141de3a4 (P2): a replayed result of an ended turn keeps that turn's fork boundary.
test("a replayed result of an ended turn keeps its summary's sequence", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "a", turnId: "turn-a" }],
      ["mux", "turn_started", { turnId: "turn-a" }],
      ["mux", "turn_result", { turnId: "turn-a", status: "completed" }],
      ["mux", "user_message", { text: "b", turnId: "turn-b" }],
      ["mux", "turn_started", { turnId: "turn-b" }],
      ["mux", "turn_result", { turnId: "turn-b", status: "completed" }],
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    daemon.push(record([["mux", "turn_result", { turnId: "turn-a", status: "completed" }]], 7));
    expect(rows().find((row) => row.id === "summary-turn-a")?.seq).toBe(3);
  } finally {
    client.close();
  }
});

// Review at 3b26be74 (P2): after a named turn ends, a turn the agent starts on its own that names none
// is a new turn; its result (naming it) settles it.
test("an agent-started unnamed turn after a named one takes its own result", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "first", turnId: "turn-a" }],
      ["mux", "turn_started", { turnId: "turn-a" }],
      ["mux", "turn_end", { turnId: "turn-a" }],
      ["mux", "turn_started", {}],
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    expect(rows().some((row) => row.kind === "typing")).toBe(true);
    daemon.push(record([["mux", "turn_result", { turnId: "turn-b", status: "completed" }]], 5));
    expect(rows().some((row) => row.kind === "typing")).toBe(false);
    expect(rows().some((row) => row.id === "summary-turn-b")).toBe(true);
  } finally {
    client.close();
  }
});

// Review at 3b26be74 (P2): a Stop of a turn that names none does not cover a later, distinct prompt.
test("a Stop of an unnamed turn does not swallow a later prompt's Stop", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "first" }],
      ["mux", "turn_started", {}],
    ]),
  );
  const { client } = await connect(daemon);
  const cancels = () => daemon.sent.filter((raw) => JSON.parse(raw).method === "session/cancel").length;
  try {
    await client.cancel();
    daemon.push(
      record(
        [
          ["mux", "user_message", { text: "second" }],
          ["mux", "turn_started", {}],
        ],
        3,
      ),
    );
    await client.cancel();
    expect(cancels()).toBe(2);
  } finally {
    client.close();
  }
});

// Review at f024ce96 (P1): the stopped turn's late result, naming that turn, must not end a newer
// turn that names none; it only settles its own Stop.
for (const kind of ["turn_result", "turn_end"] as const)
  test(`a stopped turn's late ${kind} does not end a newer unnamed turn`, async () => {
    const daemon = fakeDaemon(
      record([
        ["mux", "user_message", { text: "first", turnId: "turn-old" }],
        ["mux", "turn_started", { turnId: "turn-old" }],
      ]),
    );
    const { client, rows } = await connect(daemon);
    const cancels = () => daemon.sent.filter((raw) => JSON.parse(raw).method === "session/cancel").length;
    try {
      await client.cancel();
      daemon.push(
        record(
          [
            ["mux", "user_message", { text: "legacy next" }],
            ["mux", "turn_started", {}],
            ["mux", kind, { turnId: "turn-old", status: "cancelled" }],
          ],
          3,
        ),
      );
      expect(rows().some((row) => row.kind === "typing")).toBe(true);
      // Review at 6a5caff3 (P2): its paired end (turn_end then turn_result) is late too.
      daemon.push(
        record(
          [["mux", kind === "turn_end" ? "turn_result" : "turn_end", { turnId: "turn-old", status: "cancelled" }]],
          6,
        ),
      );
      expect(rows().some((row) => row.kind === "typing")).toBe(true);
      await client.cancel();
      expect(cancels()).toBe(2);
    } finally {
      client.close();
    }
  });

// Review at f3f7ad83 (P2): turn_error is the legacy pair of turn_result, as turn_end is; it answers
// an unidentified Stop the same way.
test("a legacy turn_error answers an unidentified Stop, so the next turn's Stop is sent", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "legacy prompt" }],
      ["mux", "turn_started", {}],
    ]),
  );
  const { client } = await connect(daemon);
  const cancels = () => daemon.sent.filter((raw) => JSON.parse(raw).method === "session/cancel").length;
  try {
    await client.cancel();
    daemon.push(record([["mux", "turn_error", { error: "stream disconnected" }]], 3));
    daemon.push(
      record(
        [
          ["mux", "user_message", { text: "next legacy prompt" }],
          ["mux", "turn_started", {}],
        ],
        4,
      ),
    );
    await client.cancel();
    expect(cancels()).toBe(2);
  } finally {
    client.close();
  }
});

// Review at f3f7ad83 (P2): the stopped turn's own late turn_end, arriving while a newer turn runs,
// still answers its Stop, so a later turn with no identity is not taken for the stopped one.
test("a stopped turn's late turn_end answers its Stop while a newer turn runs", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "first", turnId: "turn-a" }],
      ["mux", "turn_started", { turnId: "turn-a" }],
    ]),
  );
  const { client } = await connect(daemon);
  const cancels = () => daemon.sent.filter((raw) => JSON.parse(raw).method === "session/cancel").length;
  try {
    await client.cancel();
    daemon.push(
      record(
        [
          ["mux", "user_message", { text: "second", turnId: "turn-b" }],
          ["mux", "turn_started", { turnId: "turn-b" }],
          ["mux", "turn_end", { turnId: "turn-a" }],
          ["mux", "turn_result", { turnId: "turn-b", status: "completed" }],
          ["mux", "user_message", { text: "legacy third" }],
          ["mux", "turn_started", {}],
        ],
        3,
      ),
    );
    await client.cancel();
    expect(cancels()).toBe(2);
  } finally {
    client.close();
  }
});

// Review at d99da5ca (P2): a daemon that ends the fenced turn with turn_end naming that turn must
// still end it; only an end that names no turn, or another one, is ambiguous behind the fence.
test("a fenced live turn ends on a turn_end that names it", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "old prompt", turnId: "turn-old" }],
      ["mux", "turn_started", { turnId: "turn-old" }],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
      ["mux", "turn_result", { turnId: "turn-old", status: "cancelled", cancelForced: true }],
      ["mux", "user_message", { text: "next prompt", turnId: "turn-new" }],
      ["mux", "turn_started", { turnId: "turn-new" }],
    ]),
  );
  const { client, rows } = await connect(daemon);
  expect(rows().some((row) => row.kind === "typing")).toBe(true);
  daemon.push(record([["mux", "turn_end", { turnId: "turn-new" }]], 7));
  expect(rows().some((row) => row.kind === "typing")).toBe(false);
  client.close();
});

for (const [kind, msg] of [
  ["turn_end", {}],
  ["turn_end", { turnId: "turn-old" }],
  ["turn_result", {}],
] as const)
  test(`a fenced live turn ignores ambiguous ${kind} ${JSON.stringify(msg)}`, async () => {
    const daemon = fakeDaemon(
      record([
        ["mux", "user_message", { text: "old prompt", turnId: "turn-old" }],
        ["mux", "turn_started", { turnId: "turn-old" }],
        ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
        ["mux", "turn_result", { turnId: "turn-old", status: "cancelled", cancelForced: true }],
        ["mux", "user_message", { text: "next prompt", turnId: "turn-new" }],
        ["mux", "turn_started", { turnId: "turn-new" }],
        ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
      ]),
    );
    const { client, rows } = await connect(daemon);
    const before = rows();
    daemon.push(record([["mux", kind, msg]], 8));
    expect(rows()).toEqual(before);
    expect(
      rows()
        .filter((row) => row.kind === "compaction")
        .at(-1)?.compaction?.state,
    ).toBe("running");
    daemon.push(record([["mux", "turn_result", { turnId: "turn-new", status: "completed" }]], 9));
    expect(
      rows()
        .filter((row) => row.kind === "compaction")
        .at(-1)?.compaction?.state,
    ).toBe("failed");
    client.close();
  });

test("fenced metadata receipts neither draw rows nor settle a running turn", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "compact this", promptId: "prompt-old", turnId: "turn-old" }],
      ["mux", "turn_started", { turnId: "turn-old" }],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    ]),
  );
  const { client, rows } = await connect(daemon);
  await client.cancel();
  const before = rows();
  daemon.push(record([["mux", "compaction_metadata_fenced", { sourceKind: "compaction" }, 40]], 4));
  expect(rows()).toEqual(before);
  const forced = {
    turnId: "turn-old",
    turnSeq: 2,
    promptId: "prompt-old",
    status: "cancelled",
    cancelForced: true,
  };
  daemon.push(
    record(
      [
        ["mux", "turn_result", forced],
        ["mux", "user_message", { text: "next prompt", promptId: "prompt-new", turnId: "turn-new" }],
        ["mux", "turn_started", { turnId: "turn-new" }],
        ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
      ],
      5,
    ),
  );
  const running = rows();
  daemon.push(
    record(
      [
        ["mux", "compaction_metadata_fenced", { sourceKind: "compaction_summary" }, 41],
        ["mux", "compaction_metadata_fenced", { sourceKind: "compaction" }, 42],
        ["mux", "turn_result", forced],
      ],
      9,
    ),
  );
  expect(rows()).toEqual(running);
  expect(
    rows()
      .filter((row) => row.kind === "compaction")
      .map((row) => row.compaction?.state),
  ).toEqual(["failed", "running"]);
  daemon.push(record([["mux", "turn_result", { turnId: "turn-new", status: "completed" }]], 12));
  expect(
    rows()
      .filter((row) => row.kind === "compaction")
      .map((row) => row.compaction?.state),
  ).toEqual(["failed", "failed"]);
  const settled = rows();
  daemon.push(record([["mux", "compaction_metadata_fenced", { sourceKind: "compaction" }, 43]], 13));
  expect(rows()).toEqual(settled);
  client.close();
});

test("an interrupted continuation drops its turn-id summary when its queued prompt is withdrawn", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "first", promptId: "prompt-1", turnId: "turn-1" }],
      ["mux", "turn_started", { turnId: "turn-1", promptId: "prompt-1" }],
      ["mux", "queued", { text: "follow up", promptId: "prompt-2" }],
      ["mux", "queue_order", { promptId: "prompt-2", next: true, order: ["prompt-2"] }],
      ["mux", "turn_result", { status: "cancelled", turnId: "turn-1" }],
    ]),
  );
  const { client, rows } = await connect(daemon);
  const summary = () => rows().find((row) => row.id === "summary-turn-1");
  expect(summary()?.continued).toBe(true);
  daemon.push(record([["mux", "queue_removed", { promptId: "prompt-2", _meta: { acpmux: { withdrawn: true } } }]], 6));
  expect(summary()?.continued).toBeUndefined();
  client.close();
});

test("a late cancelled compaction boundary is fenced after the next explicit prompt", async () => {
  const forced = {
    status: "cancelled",
    stopReason: "cancelled",
    cancelForced: true,
    turnId: "turn-old",
    turnSeq: 2,
    promptId: "prompt-old",
  };
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "compact this", promptId: "prompt-old", turnId: "turn-old" }],
      ["mux", "turn_started", { turnId: "turn-old", promptId: "prompt-old" }],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
      ["mux", "turn_result", forced],
      ["mux", "user_message", { text: "continue", promptId: "prompt-new", turnId: "turn-new" }],
      ["mux", "turn_started", { turnId: "turn-new", promptId: "prompt-new" }],
    ]),
  );
  const { client, rows } = await connect(daemon);
  const compactions = () => rows().filter((row) => row.kind === "compaction");
  expect(compactions().map((row) => row.compaction?.state)).toEqual(["failed"]);

  // The old cancelled compaction reports its boundary after the new prompt. It must not revive
  // the old row or create a row that looks like the new turn's compaction.
  daemon.push(
    record(
      [["in", "compaction", update({ sessionUpdate: "compaction", state: "completed", preTokens: 12, postTokens: 4 })]],
      7,
    ),
  );
  expect(compactions().map((row) => row.compaction?.state)).toEqual(["failed"]);

  // A post-prompt running update gets its own row, but it cannot identify a later unscoped
  // boundary. That boundary could still belong to the cancelled compaction.
  daemon.push(record([["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })]], 8));
  const fresh = compactions()[1];
  daemon.push(
    record(
      [["in", "compaction", update({ sessionUpdate: "compaction", state: "completed", preTokens: 12, postTokens: 4 })]],
      9,
    ),
  );
  expect(compactions().map((row) => row.compaction?.state)).toEqual(["failed", "running"]);
  expect(compactions()[1]).toBe(fresh);
  daemon.push(record([["mux", "turn_result", { status: "completed", turnId: "turn-new" }]], 10));
  expect(compactions().map((row) => row.compaction)).toEqual([
    { state: "failed", inferred: true },
    { state: "failed", inferred: true },
  ]);
  const settled = compactions()[1];
  daemon.push(record([["in", "compaction", update({ sessionUpdate: "compaction", state: "completed" })]], 11));
  expect(compactions()[1]).toBe(settled);
  client.close();
});

test("a compaction fence lifts at the next explicit prompt, so a later turn's compaction completes", async () => {
  const forced = { status: "cancelled", stopReason: "cancelled", cancelForced: true, turnId: "turn-old" };
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "compact this", promptId: "prompt-old", turnId: "turn-old" }],
      ["mux", "turn_started", { turnId: "turn-old", promptId: "prompt-old" }],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
      ["mux", "turn_result", forced],
      ["mux", "user_message", { text: "continue", promptId: "prompt-new", turnId: "turn-new" }],
      ["mux", "turn_started", { turnId: "turn-new", promptId: "prompt-new" }],
      ["mux", "turn_result", { status: "completed", turnId: "turn-new" }],
    ]),
  );
  const { client, rows } = await connect(daemon);
  const compactions = () => rows().filter((row) => row.kind === "compaction");
  expect(compactions().map((row) => row.compaction?.state)).toEqual(["failed"]);

  daemon.push(
    record(
      [
        ["mux", "user_message", { text: "later", promptId: "prompt-later", turnId: "turn-later" }],
        ["mux", "turn_started", { turnId: "turn-later", promptId: "prompt-later" }],
        ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
        ["in", "compaction", update({ sessionUpdate: "compaction", state: "completed", preTokens: 12, postTokens: 4 })],
        ["mux", "turn_end", {}],
        ["mux", "turn_result", { status: "completed", turnId: "turn-later" }],
      ],
      8,
    ),
  );
  expect(compactions().map((row) => row.compaction?.state)).toEqual(["failed", "completed"]);
  expect(compactions()[1]!.compaction?.inferred).toBeUndefined();
  client.close();
});

// Recorded from a claude-sr2 chat (2026-10-20): Claude Code repeats `status: compacting` every 30s
// while a compaction runs, so one compaction sends several running updates. Each used to start its
// own row, and the turn's end noted every one the completion did not replace as failed: three
// "Compaction failed" rows above "Conversation compacted · context 352k → 24k".
test("a compaction's repeated running updates stay its one row", async () => {
  const running = update({ sessionUpdate: "compaction", state: "running" });
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "steer-default: standing down" }],
      ["mux", "turn_started", {}],
      ["in", "compaction", running],
      ["in", "compaction", running],
      ["in", "compaction", running],
      ["in", "compaction", running],
    ]),
  );
  const { rows } = await connect(daemon);
  const compactions = () =>
    rows()
      .filter((row) => row.kind === "compaction")
      .map((row) => [row.seq, row.compaction]);
  expect(compactions()).toEqual([[3, { state: "running" }]]);
  daemon.push(
    record(
      [
        [
          "in",
          "compaction",
          update({
            sessionUpdate: "compaction",
            state: "completed",
            trigger: "auto",
            preTokens: 352235,
            postTokens: 24315,
          }),
        ],
        ["mux", "turn_result", { status: "completed" }],
      ],
      7,
    ),
  );
  expect(compactions()).toEqual([[3, { state: "completed", preTokens: 352235, postTokens: 24315 }]]);
});

// The same chat later: sr2 started an account-switch compaction between turns, the next prompt's
// turn started while it ran (which settles it), and its next running update and its end came after.
test("a compaction still running when the next turn starts is taken back by its next running update", async () => {
  const steps: Step[] = [
    ["mux", "user_message", { text: "newtab-minimal: PR open" }],
    ["mux", "turn_started", {}],
    ["mux", "turn_result", { status: "completed" }],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    ["mux", "user_message", { text: "prompt-queue-edit: taken" }],
    ["mux", "turn_started", {}],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    [
      "in",
      "compaction",
      update({
        sessionUpdate: "compaction",
        state: "completed",
        trigger: "manual",
        reason: "account_switch",
        preTokens: 58163,
        postTokens: 20129,
      }),
    ],
  ];
  const compactions = (rows: AcpmuxRow[]) =>
    rows.filter((row) => row.kind === "compaction").map((row) => [row.seq, row.compaction?.state]);
  const { rows } = await connect(fakeDaemon(record(steps)));
  expect(compactions(rows())).toEqual([[4, "completed"]]);
});

test("a compaction that says it failed keeps its reason", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "/compact" }],
      ["mux", "turn_started", {}],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "failed", error: "Prompt is too long" })],
      ["mux", "turn_result", { status: "completed" }],
    ]),
  );
  const { rows } = await connect(daemon);
  expect(
    rows()
      .filter((row) => row.kind === "compaction")
      .map((row) => [row.seq, row.compaction]),
  ).toEqual([[3, { state: "failed", error: "Prompt is too long" }]]);
});

// Leo's chat, 2026-10-20: two "Compacting the conversation…" rows stacked, both spinning. A row
// the next turn's start noted as failed is taken back only by a running note that comes on time
// (Claude Code repeats it every 30s); a compaction long after is a new one, below the turns since.
test("a compaction that went quiet is not taken back by a later compaction", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "go on" }],
      ["mux", "turn_started", {}],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
      ["mux", "user_message", { text: "and on", steer: true }],
      ["mux", "turn_started", {}],
    ]),
  );
  const { rows } = await connect(daemon);
  const compactions = () =>
    rows()
      .filter((row) => row.kind === "compaction")
      .map((row) => [row.seq, row.compaction?.state]);
  expect(compactions()).toEqual([[3, "failed"]]);
  // Five minutes later (seq 300 is 300s after the start): the next turn compacts.
  daemon.push(
    record(
      [
        ["mux", "user_message", { text: "next" }],
        ["mux", "turn_started", {}],
        ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
        ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
        [
          "in",
          "compaction",
          update({ sessionUpdate: "compaction", state: "completed", preTokens: 300_000, postTokens: 20_000 }),
        ],
      ],
      300,
    ),
  );
  expect(compactions()).toEqual([
    [3, "failed"],
    [302, "completed"],
  ]);
});

// Review of #22727: a page boundary at the next prompt left an account switch's compaction, which
// runs between turns, spinning above the row the newer page drew for it once the older page loaded.
test("a compaction an older page leaves running is the newer page's row of it", async () => {
  const steps: Step[] = [
    ["mux", "user_message", { text: "newtab-minimal: PR open" }],
    ["mux", "turn_started", {}],
    ["mux", "turn_result", { status: "completed" }],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    ["mux", "user_message", { text: "prompt-queue-edit: taken" }],
    ["mux", "turn_started", {}],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    [
      "in",
      "compaction",
      update({ sessionUpdate: "compaction", state: "completed", preTokens: 58163, postTokens: 20129 }),
    ],
  ];
  const compactions = (rows: AcpmuxRow[]) =>
    rows.filter((row) => row.kind === "compaction").map((row) => row.compaction?.state);
  const { client, rows } = await connect(fakeDaemon(record(steps), 4));
  expect(compactions(rows())).toEqual(["completed"]);
  await client.loadOlder();
  expect(compactions(rows())).toEqual(["completed"]);
});

test("a compaction an older page leaves running long before the newer page's stops running", async () => {
  const steps: Step[] = [
    ["mux", "user_message", { text: "go on" }],
    ["mux", "turn_started", {}],
    ["mux", "turn_result", { status: "completed" }],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
  ];
  const later: Step[] = [
    ["mux", "user_message", { text: "next" }],
    ["mux", "turn_started", {}],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
  ];
  const compactions = (rows: AcpmuxRow[]) =>
    rows.filter((row) => row.kind === "compaction").map((row) => [row.seq, row.compaction?.state]);
  const { client, rows } = await connect(fakeDaemon([...record(steps), ...record(later, 300)], 3));
  await client.loadOlder();
  expect(compactions(rows())).toEqual([
    [4, "failed"],
    [302, "running"],
  ]);
});

// Review of #22791: a compaction a forced Stop noted as failed on the older page ended on the newer one.
test("a compaction an older page noted as failed after a forced Stop is the newer page's row of it", async () => {
  const steps: Step[] = [
    ["mux", "user_message", { text: "go on" }],
    ["mux", "turn_started", {}],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    ["mux", "turn_result", { status: "cancelled", cancelForced: true }],
    ["mux", "user_message", { text: "next" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "compaction",
      update({ sessionUpdate: "compaction", state: "completed", preTokens: 58163, postTokens: 20129 }),
    ],
  ];
  const compactions = (rows: AcpmuxRow[]) =>
    rows.filter((row) => row.kind === "compaction").map((row) => row.compaction?.state);
  const { client, rows } = await connect(fakeDaemon(record(steps), 3));
  await client.loadOlder();
  expect(compactions(rows())).toEqual(["completed"]);
});

// Leo, 2026-10-21: "And why the hell does it show that it's supposedly compacting multiple times?"
// His chat's 15 compactions, replayed from its acpmux log through the client before #22727, drew 51
// rows with up to 5 spinning at once; since #22727 and #22791 they draw 15, never more than one
// spinning. These pin that against the ways the same events reach the pane again.
const spinners = (rows: AcpmuxRow[]) =>
  rows
    .filter((row) => row.kind === "compaction" && row.compaction)
    .map((row) => renderToStaticMarkup(createElement(CompactionNote, { compaction: row.compaction! })))
    .join("")
    .split('class="cv-spinner"').length - 1;
const compactionSteps = (prompt: string, preTokens: number): Step[] => [
  ["mux", "user_message", { text: prompt }],
  ["mux", "turn_started", {}],
  ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
  ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
  ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
  [
    "in",
    "compaction",
    update({ sessionUpdate: "compaction", state: "completed", trigger: "auto", preTokens, postTokens: 25_000 }),
  ],
  ["mux", "turn_result", { status: "completed" }],
];

test("one compaction is one row after its events reach the pane again", async () => {
  const events = record(compactionSteps("go on", 352_000));
  const daemon = fakeDaemon(events.slice(0, 3));
  const { rows } = await connect(daemon);
  const compactions = () =>
    rows()
      .filter((row) => row.kind === "compaction")
      .map((row) => [row.seq, row.compaction?.state]);
  expect(compactions()).toEqual([[3, "running"]]);
  expect(spinners(rows())).toBe(1);
  daemon.push(events.slice(3));
  expect(compactions()).toEqual([[3, "completed"]]);
  // The same events delivered live again keep their seqs.
  daemon.push(events);
  expect(compactions()).toEqual([[3, "completed"]]);
  expect(spinners(rows())).toBe(0);
  // A fresh client attaches: the whole record, or a page that starts among the running notes.
  const again = await connect(fakeDaemon(events));
  expect(
    again
      .rows()
      .filter((row) => row.kind === "compaction")
      .map((row) => row.compaction?.state),
  ).toEqual(["completed"]);
  const paged = await connect(fakeDaemon(events, 3));
  await paged.client.loadOlder();
  expect(
    paged
      .rows()
      .filter((row) => row.kind === "compaction")
      .map((row) => row.compaction?.state),
  ).toEqual(["completed"]);
});

test("two compactions are two rows, and only one spins at a time", async () => {
  const events = [...record(compactionSteps("go on", 352_000)), ...record(compactionSteps("next", 353_000), 300)];
  const daemon = fakeDaemon(events.slice(0, 1));
  const { rows } = await connect(daemon);
  let most = 0;
  for (const event of events.slice(1)) {
    daemon.push([event]);
    most = Math.max(most, spinners(rows()));
  }
  expect(most).toBe(1);
  expect(
    rows()
      .filter((row) => row.kind === "compaction")
      .map((row) => [row.seq, row.compaction?.state]),
  ).toEqual([
    [3, "completed"],
    [302, "completed"],
  ]);
  expect(spinners(rows())).toBe(0);
});

// Review of #24296 (Codex): an account switch's compaction runs between turns and can say how it
// ended more than 90s after its one running note. Read whole it is one row; read a page at a time,
// the older page's running row stayed beside the newer page's end as a second row.
test("a compaction whose end alone is on the newer page is one row, however late it came", async () => {
  const steps: Step[] = [
    ["mux", "user_message", { text: "go on" }],
    ["mux", "turn_started", {}],
    ["mux", "turn_result", { status: "completed" }],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running", reason: "account_switch" })],
    ["mux", "user_message", { text: "next" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "compaction",
      update({
        sessionUpdate: "compaction",
        state: "completed",
        reason: "account_switch",
        preTokens: 58163,
        postTokens: 20129,
      }),
    ],
  ];
  const events = record(steps);
  events[6]!.at = events[3]!.at + 91_000;
  const compactions = (rows: AcpmuxRow[]) =>
    rows.filter((row) => row.kind === "compaction").map((row) => row.compaction?.state);
  const whole = await connect(fakeDaemon(events));
  expect(compactions(whole.rows())).toEqual(["completed"]);
  const { client, rows } = await connect(fakeDaemon(events, 3));
  await client.loadOlder();
  expect(compactions(rows())).toEqual(["completed"]);
});

// Review of #24296 (Claude): the end the newer page held kept its own row, so the next older page
// let it take a second compaction, one that never said how it ended. Paged reads draw what the
// whole record draws.
test("a compaction's end on a newer page takes only its own compaction from the pages further back", async () => {
  const steps: Step[] = [
    ["mux", "user_message", { text: "a" }],
    ["mux", "turn_started", {}],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    ["mux", "turn_result", { status: "completed" }],
    ["mux", "user_message", { text: "b" }],
    ["mux", "turn_started", {}],
    ["mux", "turn_result", { status: "completed" }],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running", reason: "account_switch" })],
    ["mux", "user_message", { text: "c" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "compaction",
      update({
        sessionUpdate: "compaction",
        state: "completed",
        reason: "account_switch",
        preTokens: 58163,
        postTokens: 20129,
      }),
    ],
  ];
  const events = record(steps);
  events[10]!.at = events[7]!.at + 91_000;
  const compactions = (rows: AcpmuxRow[]) =>
    rows.filter((row) => row.kind === "compaction").map((row) => [row.seq, row.compaction?.state]);
  const whole = await connect(fakeDaemon(events));
  expect(compactions(whole.rows())).toEqual([
    [3, "failed"],
    [8, "completed"],
  ]);
  const { client, rows } = await connect(fakeDaemon(events, 3, 4));
  await client.loadOlder();
  await client.loadOlder();
  expect(compactions(rows())).toEqual(compactions(whole.rows()));
});

// Review of #24296 (Codex): a newer page that holds two ends, neither with its running note, took
// only one older compaction; reading the whole record, each end takes the next one back.
const secondEnds: AcpmuxCompaction[] = [
  { state: "completed", preTokens: 222, postTokens: 22 },
  { state: "failed", error: "Prompt is too long" },
];
for (const second of secondEnds)
  test(`two ends on a newer page each take their own older compaction (${second.state})`, async () => {
    const turn = (text: string): Step[] => [
      ["mux", "user_message", { text }],
      ["mux", "turn_started", {}],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
      ["mux", "turn_result", { status: "completed" }],
    ];
    const events = record([
      ...turn("x"),
      ...turn("y"),
      ["mux", "user_message", { text: "z" }],
      ["mux", "turn_started", {}],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "completed", preTokens: 111, postTokens: 11 })],
      ["in", "compaction", update({ sessionUpdate: "compaction", ...second })],
    ]);
    const compactions = (rows: AcpmuxRow[]) =>
      rows.filter((row) => row.kind === "compaction").map((row) => [row.seq, row.compaction]);
    const whole = await connect(fakeDaemon(events));
    expect(compactions(whole.rows())).toEqual([
      [3, second],
      [7, { state: "completed", preTokens: 111, postTokens: 11 }],
    ]);
    const { client, rows } = await connect(fakeDaemon(events, 4));
    await client.loadOlder();
    expect(compactions(rows())).toEqual(compactions(whole.rows()));
  });

// Review of #24296 (Claude): a held compaction that starts with a running note on time continues
// the one the older page left open before a later end-only record can take it.
test("a compaction the newer page goes on with keeps its end; a later end-only record gets its own row", async () => {
  const events = record([
    ["mux", "user_message", { text: "a" }],
    ["mux", "turn_started", {}],
    ["mux", "turn_result", { status: "completed" }],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running", reason: "account_switch" })],
    ["mux", "user_message", { text: "b" }],
    ["mux", "turn_started", {}],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    [
      "in",
      "compaction",
      update({ sessionUpdate: "compaction", state: "completed", preTokens: 58163, postTokens: 20129 }),
    ],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "failed", error: "Prompt is too long" })],
  ]);
  const compactions = (rows: AcpmuxRow[]) =>
    rows.filter((row) => row.kind === "compaction").map((row) => row.compaction);
  const whole = await connect(fakeDaemon(events));
  expect(compactions(whole.rows())).toEqual([
    { state: "completed", preTokens: 58163, postTokens: 20129 },
    { state: "failed", error: "Prompt is too long" },
  ]);
  const { client, rows } = await connect(fakeDaemon(events, 5));
  await client.loadOlder();
  expect(compactions(rows())).toEqual(compactions(whole.rows()));
});

// Review of #24296 (Codex): a compaction still running across three pages drew its oldest page's
// row as failed beside the newer one: each page's fold kept the newer row, so the next page back
// compared its notes with a start that was not the compaction's. Its live end then left both.
test("a compaction running across three pages stays one row, and its live end ends that row", async () => {
  const events = record([
    ["mux", "user_message", { text: "a" }],
    ["mux", "turn_started", {}],
    ["mux", "turn_result", { status: "completed" }],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running", reason: "account_switch" })],
    ["mux", "user_message", { text: "b" }],
    ["mux", "turn_started", {}],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
    ["mux", "user_message", { text: "c" }],
    ["mux", "turn_started", {}],
    ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
  ]);
  // Claude Code's note every 30 seconds: at 0, 30, 60, 90 and 120.
  const t0 = events[3]!.at;
  for (const [index, at] of [
    [3, 0],
    [4, 10],
    [5, 20],
    [6, 30],
    [7, 60],
    [8, 90],
    [9, 100],
    [10, 110],
    [11, 120],
  ] as const)
    events[index]!.at = t0 + at * 1000;
  const end = record(
    [
      [
        "in",
        "compaction",
        update({ sessionUpdate: "compaction", state: "completed", preTokens: 352235, postTokens: 24315 }),
      ],
    ],
    13,
  );
  end[0]!.at = t0 + 130_000;
  const compactions = (rows: AcpmuxRow[]) =>
    rows.filter((row) => row.kind === "compaction").map((row) => [row.seq, row.compaction?.state]);
  const whole = await connect(fakeDaemon([...events]));
  expect(compactions(whole.rows())).toEqual([[4, "running"]]);
  const daemon = fakeDaemon([...events], 3, 5);
  const { client, rows } = await connect(daemon);
  await client.loadOlder();
  await client.loadOlder();
  expect(compactions(rows())).toEqual([[4, "running"]]);
  expect(spinners(rows())).toBe(1);
  daemon.push(end);
  expect(compactions(rows())).toEqual([[4, "completed"]]);
  expect(spinners(rows())).toBe(0);
});
