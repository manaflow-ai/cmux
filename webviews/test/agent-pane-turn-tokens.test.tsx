// l10n-allow-file: test fixture prompts and tool titles, not shipped UI.
// The running turn's line says what the turn has spent so far, as Claude desktop's does: the
// time, then this turn's generated output ("Working for 5m 54s · 2.1M out"). Claude Code reports
// each model call's prompt and output usage as it lands, and acpmux marks those records as one
// call's (`usage_update` with `_meta.acpmux.call`, claude_stdio/inbound.rs), so the turn's line
// adds only output tokens since its `turn_started`. Every other usage record is the context a
// harness holds: Claude Code's result repeats its last call's (for the context ring), and other
// harnesses, whatever their family, report only that. None of those adds up. A chat attached after
// its turn started has not seen every call; it shows the time alone, even once older pages load.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ContextCardBody } from "../src/agent-session/acpmux/ContextCard";
import {
  WorkingCountsContext,
  WorkingFor,
  workingTokens,
  type WorkingCounts,
} from "../src/agent-session/acpmux/conversation/WorkingFor";

const CHAT = "0190a000-0000-7000-8000-0000000000e7";
const START = Date.UTC(2026, 9, 20, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const update = (update: Record<string, unknown>) => ({
  method: "session/update",
  params: { update },
});
/// One model call's usage, as acpmux marks it on Claude Code's streamed message_delta. `used` is
/// the prompt/context side; `output` is the only part the working line adds.
const call = (used: number, size = 200_000, output = used): Step => [
  "in",
  "usage_update",
  update({
    sessionUpdate: "usage_update",
    used,
    size,
    inputTokens: used,
    outputTokens: output,
    _meta: { acpmux: { call: true } },
  }),
];
/// The context a harness holds: Claude Code's result repeating its last call, or another harness.
const held = (used: number, size = 200_000): Step => [
  "in",
  "usage_update",
  update({ sessionUpdate: "usage_update", used, size }),
];
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));
type Recorded = ReturnType<typeof record>[number];

/// Which records a kinds filter passes, as acpmux's paging.rs does for the kinds the pane asks.
const passes = (kinds: string[] | undefined, event: Recorded) =>
  !kinds || kinds.some((kind) => (kind === "transcript" ? event.kind !== "usage_update" : kind === event.kind));

/// A daemon over a fake socket: attach answers with `history` from `attachFrom` on (older records
/// load as pages); `push` sends live events. `liveOnAttach` records go out live as the attach
/// subscribes, before its reply (acpmux subscribes the event stream before it reads the page).
function fakeDaemon(
  history: Recorded[],
  {
    harness = "claude",
    family = "claude",
    attachFrom = 0,
  }: { harness?: string; family?: string; attachFrom?: number } = {},
) {
  let socket: any;
  let liveOnAttach: Recorded[] = [];
  let gapFails = false;
  const session = {
    sessionId: CHAT,
    cwd: "/Users/dev/app",
    title: "x",
    harness,
    family,
    status: "running",
  };
  const lastSeq = () => history.at(-1)?.seq ?? 0;
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
        };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach": {
        const events = history.filter((event) => event.seq >= attachFrom && passes(params?.kinds, event));
        return {
          session,
          lastSeq: lastSeq(),
          events,
          hasMore: history.some((event) => event.seq < attachFrom),
        };
      }
      case "_acpmux/events": {
        // The reconnect's gap read: every kind after the held events.
        if (gapFails && params?.afterSeq !== undefined && params?.kinds === undefined)
          throw new Error("events unavailable");
        const before = params?.beforeSeq ?? Infinity;
        const after = params?.afterSeq ?? 0;
        const events = history.filter(
          (event) => event.seq > after && event.seq < before && passes(params?.kinds, event),
        );
        return { events, hasMore: false, more: false, lastSeq: lastSeq() };
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
        if (message.method === "_acpmux/attach") {
          const live = liveOnAttach;
          liveOnAttach = [];
          push(live);
        }
        if (message.id !== undefined)
          queueMicrotask(() => {
            let reply: Record<string, unknown>;
            try {
              reply = { result: answer(message.method, message.params) };
            } catch (error) {
              reply = { error: { code: -32000, message: (error as Error).message } };
            }
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, ...reply }),
            });
          });
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const push = (events: Recorded[]) => {
    for (const event of events) {
      history.push(event);
      socket.onmessage?.({
        data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }),
      });
    }
  };
  /// A notification from the daemon (`_acpmux/lagged`).
  const notify = (method: string, params: unknown) =>
    socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  /// The connection drops; the client opens a new one and attaches again.
  const drop = () => socket.onclose?.({ code: 1006, reason: "", wasClean: false });
  /// Where the next attach page starts (a long turn outgrows the page).
  const pageFrom = (seq: number) => (attachFrom = seq);
  /// Records the next attach's subscription delivers live before the page.
  const onAttach = (events: Recorded[]) => (liveOnAttach = events);
  /// Whether the reconnect's gap read fails.
  const failGap = (fails: boolean) => (gapFails = fails);
  return { open, push, notify, drop, pageFrom, onAttach, failGap };
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let snapshot: any;
  let snapshots = 0;
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      token: "t",
      sessionId: CHAT,
    },
    (next: any) => {
      snapshot = next;
      snapshots += 1;
    },
    undefined,
    daemon.open,
  );
  await until(() => snapshot?.connection === "connected", "the attach");
  return { client, snapshot: () => snapshot, snapshots: () => snapshots };
}
/// Yields until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}
const prompt = (text: string): Step => ["mux", "user_message", { text }];
const started: Step = ["mux", "turn_started", {}];

test("a Claude turn's output tokens are the sum of its model calls since it started, live", async () => {
  const daemon = fakeDaemon(
    record([
      prompt("fix the build"),
      started,
      // Claude Code's window is 0 until its first result: the call still counts.
      call(41_200, 0),
      call(43_800),
    ]),
  );
  const { client, snapshot, snapshots } = await connect(daemon);
  try {
    expect(snapshot().isWorking).toBe(true);
    expect(snapshot().turnTokens).toBe(85_000);
    daemon.push(record([call(46_000)], 5));
    await until(() => snapshot().turnTokens === 131_000, "the third call");
    expect(snapshot().turnTokens).toBe(131_000);
    // The turn ends: no running line, nothing to count.
    const seen = snapshots();
    daemon.push(record([held(46_000), ["mux", "turn_result", { status: "completed" }]], 6));
    await until(() => snapshots() > seen, "the turn's end to land");
    expect(snapshot().turnTokens).toBeUndefined();
    // The next turn counts from zero.
    daemon.push(record([prompt("again"), started, call(50_000)], 8));
    await until(() => snapshot().turnTokens !== undefined, "the next turn's call");
    expect(snapshot().turnTokens).toBe(50_000);
  } finally {
    client.close();
  }
});

test("a five-step turn counts generated output, not repeated context", async () => {
  const daemon = fakeDaemon(
    record([
      prompt("summarize the five steps"),
      started,
      call(100_000, 400_000, 1_000),
      call(100_000, 400_000, 1_000),
      call(100_000, 400_000, 1_000),
      call(100_000, 400_000, 1_000),
      call(100_000, 400_000, 1_000),
    ]),
  );
  const { client, snapshot } = await connect(daemon);
  try {
    // The old reducer added each 100K context snapshot (505K including output). The line is
    // output-only: five requests × 1K generated tokens = about 5K out.
    expect(snapshot().turnTokens).toBe(5_000);
    expect(snapshot().summary?.usage).toEqual({ used: 100_000, size: 400_000 });
  } finally {
    client.close();
  }
});

test("a result that repeats the last call while a steer waits adds nothing", async () => {
  // Claude Code ends the steered line's first part with a result (it resends the last call's usage
  // for the context ring) and runs the steer as more of the same turn.
  const daemon = fakeDaemon(
    record([
      prompt("fix the build"),
      started,
      call(40_000),
      ["mux", "user_message", { text: "also the tests", steer: true }],
      held(40_000),
      call(45_000),
    ]),
  );
  const { client, snapshot } = await connect(daemon);
  try {
    expect(snapshot().turnTokens).toBe(85_000);
  } finally {
    client.close();
  }
});

test("a Stop's late result does not count toward the next turn", async () => {
  const daemon = fakeDaemon(
    record([
      prompt("fix the build"),
      started,
      call(40_000),
      ["mux", "turn_result", { status: "cancelled" }],
      prompt("try another way"),
      started,
      // The stopped turn's result, answered late, repeats its last call.
      held(40_000),
      call(12_000),
    ]),
  );
  const { client, snapshot } = await connect(daemon);
  try {
    expect(snapshot().turnTokens).toBe(12_000);
  } finally {
    client.close();
  }
});

test("a chat attached mid-turn, without the turn's start, shows no tokens it cannot add up", async () => {
  const daemon = fakeDaemon(record([call(41_200), call(43_800)], 30));
  const { client, snapshot } = await connect(daemon);
  try {
    expect(snapshot().isWorking).toBe(true);
    expect(snapshot().turnTokens).toBeUndefined();
  } finally {
    client.close();
  }
});

test("once older pages bring a mid-turn attach's start, every rebuild keeps its tokens hidden", async () => {
  // The attach page starts after the turn's first calls; an older page brings the start, but
  // pages carry no usage, so a count from it would leave those calls out. Each later rebuild of
  // the held events (a lag resync, a Debug toggle, a reconnect's attach) must not count it either.
  const history = record([prompt("fix the build"), started, call(41_200), call(43_800), call(46_000), call(9_000)]);
  const daemon = fakeDaemon(history, { attachFrom: 5 });
  const { client, snapshot } = await connect(daemon);
  const scope = globalThis as { window?: unknown };
  const hadWindow = "window" in scope;
  // The client schedules its reconnect on `window`; this test has no DOM.
  if (!hadWindow) scope.window = globalThis;
  try {
    expect(snapshot().isWorking).toBe(true);
    expect(snapshot().turnTokens).toBeUndefined();
    await client.loadOlder();
    await until(() => snapshot().rows.some((row: AcpmuxRow) => row.kind === "user"), "the older page");
    expect(snapshot().rows.some((row: AcpmuxRow) => row.kind === "user")).toBe(true);
    expect(snapshot().turnTokens).toBeUndefined();

    daemon.notify("_acpmux/lagged", { dropped: 1 });
    expect(snapshot().connection).toBe("resyncing");
    await until(() => snapshot().connection === "resynced", "the resync");
    expect(snapshot().turnTokens).toBeUndefined();

    // The rebuild and its snapshot are synchronous.
    client.suggestedTasksChanged();
    expect(snapshot().turnTokens).toBeUndefined();

    daemon.drop();
    expect(snapshot().connection).toBe("disconnected");
    await until(() => snapshot().connection === "connected", "the reconnect");
    expect(snapshot().isWorking).toBe(true);
    expect(snapshot().turnTokens).toBeUndefined();

    // A turn that starts while the client watches counts from its start.
    daemon.push(record([["mux", "turn_result", { status: "completed" }], prompt("again"), started, call(7_000)], 7));
    await until(() => snapshot().turnTokens !== undefined, "the new turn's call");
    expect(snapshot().turnTokens).toBe(7_000);
  } finally {
    client.close();
    if (!hadWindow) delete scope.window;
  }
});

test("a reconnect whose page starts after the turn began keeps the count it held", async () => {
  // The chat was read whole; then the turn outgrows the attach page and the socket drops. The new
  // page starts mid-turn, but the client still holds every call before it.
  const daemon = fakeDaemon(record([prompt("fix the build"), started, call(41_200), call(43_800)]));
  const { client, snapshot } = await connect(daemon);
  const scope = globalThis as { window?: unknown };
  const hadWindow = "window" in scope;
  // The client schedules its reconnect on `window`; this test has no DOM.
  if (!hadWindow) scope.window = globalThis;
  try {
    expect(snapshot().turnTokens).toBe(85_000);
    daemon.push(record([call(46_000)], 5));
    await until(() => snapshot().turnTokens === 131_000, "the third call");
    expect(snapshot().turnTokens).toBe(131_000);
    daemon.pageFrom(4);
    daemon.drop();
    expect(snapshot().connection).toBe("disconnected");
    await until(() => snapshot().connection === "connected", "the reconnect");
    expect(snapshot().isWorking).toBe(true);
    expect(snapshot().turnTokens).toBe(131_000);
  } finally {
    client.close();
    if (!hadWindow) delete scope.window;
  }
});

test("a live call that lands before a mid-turn attach's reply does not make it a reconnect", async () => {
  // acpmux subscribes the attach's event stream before it reads the page, so a live call can land
  // before the reply. The client then holds an event, but only from this attach: the turn's first
  // calls are older than the page, and an older page bringing its start must not count from it.
  const history = record([prompt("fix the build"), started, call(41_200), call(43_800), call(46_000)]);
  const daemon = fakeDaemon(history, { attachFrom: 4 });
  daemon.onAttach(record([call(9_000)], 6));
  const { client, snapshot } = await connect(daemon);
  try {
    expect(snapshot().isWorking).toBe(true);
    expect(snapshot().turnTokens).toBeUndefined();
    await client.loadOlder();
    await until(() => snapshot().rows.some((row: AcpmuxRow) => row.kind === "user"), "the older page");
    expect(snapshot().rows.some((row: AcpmuxRow) => row.kind === "user")).toBe(true);
    expect(snapshot().turnTokens).toBeUndefined();
  } finally {
    client.close();
  }
});

test("a reconnect whose gap read fails hides the count it can no longer add up", async () => {
  // The chat was read whole; while the socket is down the turn makes calls past the next page's
  // start, and reading the gap fails. The calls in the gap are missing, so the count hides.
  const history = record([prompt("fix the build"), started, call(41_200), call(43_800)]);
  const daemon = fakeDaemon(history);
  const { client, snapshot } = await connect(daemon);
  const scope = globalThis as { window?: unknown };
  const hadWindow = "window" in scope;
  // The client schedules its reconnect on `window`; this test has no DOM.
  if (!hadWindow) scope.window = globalThis;
  try {
    expect(snapshot().turnTokens).toBe(85_000);
    history.push(...record([call(46_000), call(1_000), call(2_000), call(3_000)], 5));
    daemon.pageFrom(7);
    daemon.failGap(true);
    daemon.drop();
    await until(() => snapshot().turnTokens === undefined, "the gap read to fail");
    expect(snapshot().isWorking).toBe(true);
    expect(snapshot().turnTokens).toBeUndefined();
  } finally {
    client.close();
    if (!hadWindow) delete scope.window;
  }
});

for (const [harness, family] of [
  ["codex", "codex"],
  // A Claude ACP adapter or opencode on a Claude model: family "claude", but its usage is the
  // context it holds, never marked as one call's.
  ["claude-acp", "claude"],
  ["opencode", "claude"],
] as const)
  test(`a ${harness} chat (family ${family}) shows the time alone`, async () => {
    const daemon = fakeDaemon(record([prompt("fix the build"), started, held(41_200), held(43_800)]), {
      harness,
      family,
    });
    const { client, snapshot } = await connect(daemon);
    try {
      expect(snapshot().isWorking).toBe(true);
      expect(snapshot().turnTokens).toBeUndefined();
    } finally {
      client.close();
    }
  });

// The composer tooltip stays compact for harnesses without a category breakdown. The usage record
// still carries the setup value for the context summary, but it is intentionally not guessed into
// the small Codex-style hover surface.
const compactCard = (usage: { used: number; size: number; setup?: number }) =>
  renderToStaticMarkup(<ContextCardBody {...usage} working={false} />).includes("acpmux-context-card-line");

test("a usage record's reported setup reaches the context summary while the tooltip stays compact", async () => {
  const withSetup: Step = [
    "in",
    "usage_update",
    update({
      sessionUpdate: "usage_update",
      used: 111_000,
      size: 475_000,
      _meta: { acpmux: { setup: 20_000 } },
    }),
  ];
  const daemon = fakeDaemon(record([prompt("fix the build"), started, withSetup]));
  const { client, snapshot } = await connect(daemon);
  try {
    await until(() => snapshot().summary?.usage !== undefined, "the usage");
    expect(snapshot().summary.usage).toEqual({ used: 111_000, size: 475_000, setup: 20_000 });
    expect(compactCard(snapshot().summary.usage)).toBe(true);
    // A later record with no setup keeps the same compact tooltip.
    daemon.push(record([held(120_000, 475_000)], 4));
    await until(() => snapshot().summary.usage.used === 120_000, "the next usage");
    expect(snapshot().summary.usage).toEqual({ used: 120_000, size: 475_000 });
    expect(compactCard(snapshot().summary.usage)).toBe(true);
    daemon.push(
      record(
        [
          [
            "in",
            "usage_update",
            update({
              sessionUpdate: "usage_update",
              used: 10_000,
              size: 475_000,
              _meta: { acpmux: { setup: 30_000 } },
            }),
          ],
        ],
        5,
      ),
    );
    await until(() => snapshot().summary.usage.used === 10_000, "the odd usage");
    expect(snapshot().summary.usage.setup).toBeUndefined();
  } finally {
    client.close();
  }
});

const status: AcpmuxRow = { id: "working", kind: "working", version: 1, at: START };
const counts = (extra: Partial<WorkingCounts> = {}): WorkingCounts => ({
  agents: 0,
  commands: 0,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
  ...extra,
});
const drawn = (row: AcpmuxRow, value: WorkingCounts) =>
  renderToStaticMarkup(
    <WorkingCountsContext.Provider value={value}>
      <WorkingFor row={row} now={() => START + 354_000} />
    </WorkingCountsContext.Provider>,
  )
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

test("the line reads the time, then the turn's output, after the working dots", () => {
  expect(drawn(status, counts({ tokens: 2_140_000 }))).toBe("Working for 5m 54s · 2.1M out");
  expect(drawn({ ...status, doing: "bun test" }, counts({ tokens: 840_000 }))).toBe("bun test 5m 54s · 840K out");
  // Before the first call reports, or with no token data, the time stands alone.
  expect(drawn(status, counts())).toBe("Working for 5m 54s");
  expect(drawn(status, counts({ tokens: 0 }))).toBe("Working for 5m 54s");
  // The background counts follow the tokens.
  expect(drawn(status, counts({ tokens: 2_140_000, agents: 2 }))).toBe("Working for 5m 54s · 2.1M out · 2 subagents");
});

test("tokens are compact in the pane's language", () => {
  expect(workingTokens(translatorFor("en"), "en", 2_140_000)).toBe("2.1M out");
  expect(workingTokens(translatorFor("en"), "en", 1)).toBe("1 out");
  const german = new Intl.NumberFormat("de", {
    notation: "compact",
    maximumFractionDigits: 1,
  }).format(2_140_000);
  expect(workingTokens(translatorFor("de"), "de", 2_140_000)).toContain(german);
});
