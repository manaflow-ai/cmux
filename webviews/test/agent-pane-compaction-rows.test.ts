// l10n-allow-file: test fixture prompts and harness names, not shipped UI.
// A compaction and a failover are noted in the transcript where they happened. Before, acpmux's
// Claude translator dropped `compact_boundary` (only the context ring reset) and no client drew
// acpmux's `failover` record, so a chat that compacted, or moved to another harness after a usage
// limit, went on with nothing in the transcript saying so.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { compactTokens } from "../src/agent-session/acpmux/conversation/CompactionNote";

const CHAT = "0190a000-0000-7000-8000-0000000000c7";
const START = Date.UTC(2026, 9, 18, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));

/// A daemon over a fake socket: attach answers with `history`'s newest `page` events; `push` sends live ones.
function fakeDaemon(history: ReturnType<typeof record>, page = history.length) {
  let socket: any;
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
  return { open, push };
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let rows: AcpmuxRow[] = [];
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      token: "t",
      sessionId: CHAT,
    },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, rows: () => rows };
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

test("a restricted chat that stayed on its harness notes why", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "keep going" }],
      ["mux", "turn_started", {}],
      ["mux", "failover_refused", { from: "claude", to: "codex", reason: "restricted", turnId: "t1" }],
    ]),
  );
  const { rows } = await connect(daemon);
  expect(
    rows()
      .filter((row) => row.kind === "failover")
      .map((row) => row.failover),
  ).toEqual([{ from: "claude", to: "codex", refused: "restricted" }]);
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
