// l10n-allow-file: test fixture prompts and harness names, not shipped UI.
// A compaction and a failover are noted in the transcript where they happened. Before, acpmux's
// Claude translator dropped `compact_boundary` (only the context ring reset) and no client drew
// acpmux's `failover` record, so a chat that compacted, or moved to another harness after a usage
// limit, went on with nothing in the transcript saying so.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxCompaction, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { CompactionNote, compactTokens } from "../src/agent-session/acpmux/conversation/CompactionNote";
import { translate } from "../src/agent-session/acpmux/i18n";

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
  return { open, push, sent };
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
