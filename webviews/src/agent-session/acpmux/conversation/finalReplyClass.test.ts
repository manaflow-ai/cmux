// l10n-allow-file: generated chat records, not shipped UI.
// The class "a settled final reply goes missing" (finalReplyDrawn.test.ts holds the recorded
// stretches): a Claude Code turn's last reply was held by the daemon but never drew; the pane showed
// the prompt, "Worked for 18s", no reply, then the next turn. That session's agent ends each turn
// with the acpmux `wrap_up` tool AFTER its reply (text, wrap_up call, turn_result), and the next
// turn was opened by an agent message or a "[notice from acpmux] Background command finished"
// notice within a second. This sweeps the endings, the next-turn openers, Claude Code's own turns
// (`background_turn` brackets, acpmux hub/background_turn.rs) and steers in every combination,
// in the orders a live daemon can log them, through the pane's own reducer (direct.ts) and fold
// (turns.ts).
//
// The oracle is the generator's own: it knows which text each turn ended with. Every turn a person,
// an inbox notice, an agent message or a finished acpmux background command opened, that ended
// `completed` with a multi-paragraph reply, draws that reply as an assistant row of its own (not in
// a closed fold), for agentFamily "claude" and none, under every fold arm, on the full replay and
// at every prefix that ends on a turn_result, turn_started, user_message or background_turn record.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../../test/support/domTeardown";
import { AcpmuxDirectClient, type EventRecord } from "../direct";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";

const SESSION = "01a18a35-b1e8-7951-ba2f-703bf916b9a6";
const BOOT = "1a1e7bb955e";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document, had: "window" in scope };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  if (saved.had) Object.assign(scope, { window: saved.window, document: saved.document });
  else {
    delete scope.window;
    delete scope.document;
  }
});

/// The rows the pane's reducer folds `events` into, as a reopen reads them (finalReplyDrawn.test.ts).
function replay(events: readonly EventRecord[]): AcpmuxRow[] {
  let rows: readonly AcpmuxRow[] = [];
  const client = AcpmuxDirectClient.replay(SESSION, events.slice(), (snapshot) => {
    rows = snapshot.rows;
  });
  try {
    client.seekReplay(events.at(-1)!.seq);
  } finally {
    client.close();
  }
  return rows.slice();
}

/// The fold arms finalReplyDrawn.test.ts runs, and the background-turn look's other arm (its default
/// is inline), since background turns are half of this class.
const ARMS: Record<string, string>[] = [
  {},
  { "claude-turn-fold": "runs" },
  ...["nested-open", "nested", "header", "split"].map((arm) => ({ "turn-fold-steered": arm })),
  ...["groups", "runs", "replies"].map((arm) => ({ "turn-fold-replies": arm })),
  { "background-turn-look": "line" },
];
const FAMILIES = ["claude", undefined] as const;

function withArms<T>(arms: Record<string, string>, run: () => T): T {
  globalThis.cmuxExperiments = arms;
  try {
    return run();
  } finally {
    delete (globalThis as { cmuxExperiments?: unknown }).cmuxExperiments;
  }
}

// ---- The generator ---------------------------------------------------------------------------

type Opener = "person" | "inbox" | "agent" | "bgdone";
type Ending = "plain" | "wrapUp" | "wrapUpLate";
/// Where Claude Code's own turn opens a `background_turn` bracket around turn A's end: before its
/// reply, between the reply's first and later chunks, after the reply but before turn_result (its
/// `system/init` and first word came while finish_turn ran: take_turn cleared `session.turn` before
/// turn_result was written), or right after turn_result.
type BgAt = "none" | "beforeReply" | "betweenChunks" | "afterReply" | "afterResult";
type BgEnd = "quiet" | "loud" | "never";
export type Case = {
  opener: Exclude<Opener, "bgdone">;
  ending: Ending;
  bgAt: BgAt;
  bgEnd: BgEnd;
  steer: boolean;
  next: Opener;
  delay: number;
};
type Expected = { turnId: string; segment: string; text: string; endSeq: number };
type Chat = { events: EventRecord[]; replies: Expected[] };

const caseName = (c: Case) =>
  `${c.opener}/${c.ending}/bg:${c.bgAt}${c.bgAt === "none" ? "" : `:${c.bgEnd}`}/${c.steer ? "steer" : "nosteer"}/next:${c.next}+${c.delay}ms`;

const reply = (label: string) => [
  `${label} found the cause.\n\n`,
  `The reply's second paragraph says what changed.\n\n`,
  `Its third paragraph says what is left.`,
];

export function chat(c: Case): Chat {
  let seq = 2414200;
  let now = 1794519714000;
  const events: EventRecord[] = [];
  const replies: Expected[] = [];
  const push = (kind: string, dir: "mux" | "in", msg: EventRecord["msg"], gap = 1) => {
    now += gap;
    seq += 1;
    events.push({ seq, kind, dir, msg, sessionId: SESSION, at: now });
    return seq;
  };
  const update = (kind: string, data: Record<string, unknown>, meta?: Record<string, unknown>, gap = 1) =>
    push(
      kind,
      "in",
      {
        jsonrpc: "2.0",
        method: "session/update",
        params: { sessionId: SESSION, ...(meta && { _meta: meta }), update: { sessionUpdate: kind, ...data } },
      },
      gap,
    );
  const chunk = (segment: string, messageId: string, text: string, gap = 1) =>
    update("agent_message_chunk", { content: { type: "text", text }, messageId }, { acpmux: { segment } }, gap);

  const opener = (kind: Opener, turnId: string, promptId: string, gap: number) => {
    const at = gap;
    if (kind === "person")
      push(
        "user_message",
        "mux",
        {
          text: "Why does the chat drop replies?",
          promptId,
          turnId,
          client: "cmux-react-agent-pane#01a1e7",
          _meta: { origin: { actor: "person", verified: true } },
        },
        at,
      );
    else if (kind === "inbox")
      push(
        "user_message",
        "mux",
        {
          text: "[inbox] 1 new message from lane-4",
          promptId,
          turnId,
          client: "acpmux",
          _meta: {
            provenance: {
              kind: "inbox_notice",
              noticeId: promptId,
              threads: [
                {
                  threadId: "from:lane-4",
                  label: "lane-4",
                  new: 1,
                  from: ["lane-4"],
                  promptIds: ["x"],
                  blocker: false,
                  preview: "Pushed.",
                },
              ],
            },
          },
        },
        at,
      );
    else if (kind === "agent")
      push(
        "user_message",
        "mux",
        {
          text: "lane-4/helper: pushed the fix, review it",
          promptId,
          turnId,
          client: "acpmux-peer#01a1e7",
          control: "peer",
          _meta: {
            provenance: {
              forwardedBy: { actor: "peer" },
              from: "lane-4",
              fromHarness: "claude",
              fromName: "lane-4/helper",
              kind: "agent_message",
              transport: "peer",
              verified: false,
            },
          },
        },
        at,
      );
    else
      push(
        "user_message",
        "mux",
        {
          text: "[notice from acpmux] Background command finished: bun test (exit 0)",
          promptId,
          turnId,
          client: "acpmux",
          _meta: {
            provenance: {
              bgTaskId: promptId.slice("bg-done-".length),
              from: "acpmux",
              fromName: "acpmux",
              kind: "notice",
              notice: { sender: "acpmux", severity: "info", title: "Background command finished: bun test (exit 0)" },
            },
          },
        },
        at,
      );
    push(
      "turn_started",
      "mux",
      {
        promptId,
        turnId,
        client: kind === "person" ? "cmux-react-agent-pane#01a1e7" : kind === "agent" ? "acpmux-peer#01a1e7" : "acpmux",
        trigger: false,
      },
      0,
    );
  };
  const work = (id: string) => {
    update(
      "tool_call",
      { toolCallId: id, title: "Bash", kind: "execute", status: "pending", _meta: { claude: { tool: "Bash" } } },
      undefined,
      300,
    );
    update(
      "tool_call_update",
      {
        toolCallId: id,
        title: `git status ${id}`,
        kind: "execute",
        status: "in_progress",
        rawInput: { command: `git status ${id}` },
      },
      undefined,
      20,
    );
    update(
      "tool_call_update",
      { toolCallId: id, status: "completed", content: [{ type: "content", content: { type: "text", text: "clean" } }] },
      undefined,
      400,
    );
  };
  const wrapStart = (id: string) => {
    update(
      "tool_call",
      {
        toolCallId: id,
        title: "mcp__acpmux__wrap_up",
        kind: "other",
        status: "pending",
        _meta: { claude: { tool: "mcp__acpmux__wrap_up" } },
      },
      undefined,
      200,
    );
    update(
      "tool_call_update",
      {
        toolCallId: id,
        title: "mcp__acpmux__wrap_up",
        kind: "other",
        status: "in_progress",
        rawInput: { recap: "Found why replies vanished and wrote the test. Not fixed yet." },
        _meta: { claude: { tool: "mcp__acpmux__wrap_up" } },
      },
      undefined,
      30,
    );
  };
  const wrapDone = (id: string, gap = 40) =>
    update(
      "tool_call_update",
      {
        toolCallId: id,
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: '{"ok":true}' } }],
      },
      undefined,
      gap,
    );
  const bg = { id: "", started: false, ended: false };
  const bgStart = () => {
    bg.id = `bg-${seq + 1}`;
    bg.started = true;
    push("background_turn", "mux", { state: "started", id: bg.id, trigger: "task_notification" }, 2);
  };
  const bgWords = () => {
    // Claude Code's own turn's reply: with no acpmux turn its segment is "-" (hub/stream.rs).
    const text =
      c.bgEnd === "quiet" ? "Nothing new." : "The watcher finished.\n\nCI is green on the head; nothing waits on you.";
    chunk(`-.${BOOT}.1`, "msg_bg_own", text, 30);
  };
  const bgEndRecord = () => {
    if (!bg.started || bg.ended || c.bgEnd === "never") return;
    bg.ended = true;
    push(
      "background_turn",
      "mux",
      { state: "ended", id: bg.id, trigger: "task_notification", quiet: c.bgEnd === "quiet", reason: "result" },
      5,
    );
  };
  const result = (promptId: string, turnId: string, extra: Record<string, unknown> = {}, gap = 60) =>
    push(
      "turn_result",
      "mux",
      { status: "completed", stopReason: "end_turn", promptId, turnId, trigger: false, ...extra },
      gap,
    );

  // Turn A: the opener, some work, a three-chunk reply, then its ending.
  const turnA = "01a1e7e3-d4d9-745f-9c94-eb3ede3e2a07";
  const promptA =
    c.opener === "person"
      ? "c4a53106-70b2-4883-a772-bc6d86af32e8"
      : c.opener === "inbox"
        ? "inbox-notice-01a1e7e3"
        : "01a1e7e4-242f";
  opener(c.opener, turnA, promptA, 1000);
  work("toolu_A1");
  if (c.bgAt === "beforeReply") bgStart();
  const segA = `${turnA}.${BOOT}.1`;
  const piecesA = reply("Turn A");
  const steerId = "msg_2840c6d995079d75a9b3ae6e372e6c62";
  piecesA.forEach((piece, at) => {
    chunk(segA, "msg_A", piece, at === 0 ? 800 : 15);
    if (at !== 0) return;
    if (c.bgAt === "betweenChunks") bgStart();
    if (c.steer)
      push(
        "user_message",
        "mux",
        {
          text: "lane-4/coord: also check the iOS pane",
          promptId: steerId,
          turnId: turnA,
          steer: true,
          client: "acpmux-outbox#01a1e7",
          control: "peer",
          _meta: {
            provenance: {
              forwardedBy: { actor: "peer" },
              from: "lane-4",
              fromName: "lane-4/coord",
              kind: "agent_message",
              transport: "peer",
              verified: false,
            },
          },
        },
        3,
      );
  });
  if (c.ending !== "plain") wrapStart("toolu_wrapA");
  if (c.ending === "wrapUp") wrapDone("toolu_wrapA");
  // Claude Code's `result` ends a bracket that opened inside the turn (hub/background_turn.rs `on_line`).
  if (c.bgAt === "beforeReply" || c.bgAt === "betweenChunks") bgEndRecord();
  if (c.bgAt === "afterReply") {
    bgStart();
    bgWords();
  }
  const turnB = "01a1e7e4-728c-7616-8151-b657202629ab";
  const endA = result(
    promptA,
    turnA,
    c.steer
      ? {
          carriedTo: {
            client: "acpmux-outbox#01a1e7",
            control: "peer",
            promptId: steerId,
            promptIds: [steerId],
            reportsOnly: false,
          },
        }
      : {},
  );
  replies.push({ turnId: turnA, segment: segA, text: piecesA.join(""), endSeq: endA });
  if (c.ending === "wrapUpLate") wrapDone("toolu_wrapA", 1);
  if (c.bgAt === "afterResult") {
    bgStart();
    bgWords();
  }
  bgEndRecord();

  // The carried turn a steer opened, at once.
  if (c.steer) {
    push(
      "turn_started",
      "mux",
      {
        promptId: steerId,
        turnId: turnB,
        client: "acpmux-outbox#01a1e7",
        control: "peer",
        carried: { fromTurnId: turnA, promptIds: [steerId] },
        trigger: false,
      },
      c.delay,
    );
    push("steer_read", "mux", { promptId: steerId, turnId: turnB }, 400);
    const segB = `${turnB}.${BOOT}.1`;
    const piecesB = reply("Turn B");
    piecesB.forEach((piece, at) => chunk(segB, "msg_B", piece, at === 0 ? 300 : 10));
    if (c.ending !== "plain") {
      wrapStart("toolu_wrapB");
      if (c.ending === "wrapUp") wrapDone("toolu_wrapB");
    }
    const endB = result(steerId, turnB);
    replies.push({ turnId: turnB, segment: segB, text: piecesB.join(""), endSeq: endB });
    if (c.ending === "wrapUpLate") wrapDone("toolu_wrapB", 1);
  }

  // The next turn, 0-5 ms after the last turn_result.
  const turnC = "01a1e7e5-7a6e-71df-9170-2bc91c17f027";
  const promptC =
    c.next === "person"
      ? "01a1e7e5-person"
      : c.next === "inbox"
        ? "inbox-notice-01a1e7e5"
        : c.next === "agent"
          ? "01a1e7e5-7958"
          : "bg-done-bg-f474c1067b72";
  opener(c.next, turnC, promptC, c.steer ? c.delay + 50 : c.delay);
  const segC = `${turnC}.${BOOT}.1`;
  const piecesC = reply("Turn C");
  piecesC.forEach((piece, at) => chunk(segC, "msg_C", piece, at === 0 ? 900 : 10));
  if (c.ending !== "plain") {
    wrapStart("toolu_wrapC");
    if (c.ending === "wrapUp") wrapDone("toolu_wrapC");
  }
  const endC = result(promptC, turnC);
  // A finished acpmux background command's turn draws as one line by design, its acknowledgement
  // hidden (bgDoneNotice.ts, Lucas 2026-11-14): it opens the next turn here, it is not checked.
  if (c.next !== "bgdone") replies.push({ turnId: turnC, segment: segC, text: piecesC.join(""), endSeq: endC });
  if (c.ending === "wrapUpLate") wrapDone("toolu_wrapC", 1);
  return { events, replies };
}

export function allCases(): Case[] {
  const out: Case[] = [];
  for (const opener of ["person", "inbox", "agent"] as const)
    for (const ending of ["plain", "wrapUp", "wrapUpLate"] as const)
      for (const bgAt of ["none", "beforeReply", "betweenChunks", "afterReply", "afterResult"] as const)
        for (const bgEnd of bgAt === "none" ? (["quiet"] as const) : (["quiet", "loud", "never"] as const))
          for (const steer of [false, true])
            for (const next of ["person", "inbox", "agent", "bgdone"] as const)
              for (const delay of [0, 5]) out.push({ opener, ending, bgAt, bgEnd, steer, next, delay });
  return out;
}

// ---- The oracle ------------------------------------------------------------------------------

/// The replies among `replies` that `drawn` does not show as an assistant row of their own, whole
/// and outside a closed fold.
function undrawn(replies: readonly Expected[], drawn: readonly AcpmuxRow[]): Expected[] {
  const shown = new Map<string, string>();
  for (const row of drawn)
    if (row.kind === "assistant" && !row.foldedReply && typeof row.text === "string")
      shown.set(row.id, (shown.get(row.id) ?? "") + row.text);
  const texts = new Set(Array.from(shown.values(), (text) => text.trim()));
  return replies.filter((reply) => {
    const own = shown.get(`assistant-${reply.segment}`);
    if (own !== undefined) return own.trim() !== reply.text.trim();
    return !texts.has(reply.text.trim());
  });
}

const CHECKED = new Set(["turn_result", "turn_started", "user_message", "background_turn"]);

export type Miss = { arm: string; family: string; through: number; turns: string[] };

/// Every miss of `chat`: under each arm and family, on the full replay and at each checked prefix.
export function misses(c: Chat, opts: { arms?: Record<string, string>[]; prefixes?: boolean } = {}): Miss[] {
  const out: Miss[] = [];
  const ends: number[] = [];
  if (opts.prefixes !== false)
    c.events.forEach((event, at) => {
      if (CHECKED.has(event.kind) && at < c.events.length - 1) ends.push(at);
    });
  ends.push(c.events.length - 1);
  for (const arms of opts.arms ?? ARMS)
    withArms(arms, () => {
      for (const end of ends) {
        const through = c.events[end]!.seq;
        const expected = c.replies.filter((reply) => reply.endSeq <= through);
        if (!expected.length) continue;
        const rows = replay(c.events.slice(0, end + 1));
        for (const family of FAMILIES) {
          const missing = undrawn(expected, turnView(rows, new Set(), { agentFamily: family }));
          if (missing.length)
            out.push({
              arm: JSON.stringify(arms),
              family: String(family),
              through,
              turns: missing.map((reply) => reply.turnId.slice(0, 13)),
            });
        }
      }
    });
  return out;
}

/// The records of `events` as compact JSON lines, for a failure's message.
export const compact = (events: readonly EventRecord[]) =>
  events
    .map((event) => {
      const update = event.msg?.params?.update;
      const body =
        event.dir === "mux"
          ? Object.fromEntries(
              Object.entries(event.msg ?? {}).filter(([key]) =>
                ["state", "id", "quiet", "promptId", "turnId", "steer", "status", "carried", "carriedTo"].includes(key),
              ),
            )
          : {
              u: update?.sessionUpdate,
              ...(update?.toolCallId && { call: update.toolCallId, status: update.status }),
              ...(update?.content?.text !== undefined && { text: String(update.content.text).slice(0, 24) }),
              ...(event.msg?.params?._meta?.acpmux?.segment && {
                segment: event.msg.params._meta.acpmux.segment.slice(0, 13),
              }),
            };
      return JSON.stringify({ seq: event.seq, at: event.at % 100000, k: event.kind, ...body });
    })
    .join("\n");

// ---- The sweep: green, the regression ----------------------------------------------------------

/// A bracket that opened inside turn A (before its reply, or between its chunks), or that never
/// ends. These are the red mechanisms below; the sweep checks every other combination.
const RUNS = JSON.stringify({ "claude-turn-fold": "runs" });
const red = (c: Case) =>
  c.bgEnd === "never"
    ? c.bgAt !== "none"
    : c.bgAt === "betweenChunks" || (c.bgAt === "beforeReply" && c.bgEnd === "quiet");

test("sweep: every ending (text, wrap_up, late wrap_up), opener (person, inbox, agent, bg-done, 0-5 ms), steer and background turn around the end draws every final reply", () => {
  const failures: string[] = [];
  let checked = 0;
  for (const c of allCases()) {
    if (red(c)) continue;
    checked += 1;
    // R4 below: Claude Code's own loud turn in finish_turn's window takes the answer's place under
    // the `runs` fold for Claude; every other arm and family is checked.
    const found = misses(chat(c)).filter(
      (miss) => !(c.bgAt === "afterReply" && c.bgEnd === "loud" && miss.arm === RUNS && miss.family === "claude"),
    );
    if (found.length) failures.push(`${caseName(c)}: ${found.length} misses, first ${JSON.stringify(found[0])}`);
  }
  expect(checked).toBe(864);
  expect(failures.join("\n")).toBe("");
}, 600_000);

test("sweep: a background turn that opened after turn A's reply and never ended still leaves A's reply drawn at every record", () => {
  const failures: string[] = [];
  for (const c of allCases()) {
    if (c.bgEnd !== "never" || (c.bgAt !== "afterReply" && c.bgAt !== "afterResult")) continue;
    const full = chat(c);
    const found = misses({ events: full.events, replies: full.replies.slice(0, 1) });
    if (found.length) failures.push(`${caseName(c)}: ${JSON.stringify(found[0])}`);
  }
  expect(failures.join("\n")).toBe("");
}, 600_000);

// ---- Live: the realistic orders streamed to the pane, as finalReplyDrawn.test.ts streams them ----

const settle = async (done: () => boolean) => {
  for (let turns = 0; !done(); turns += 1) {
    if (turns > 20_000) throw new Error(`never settled: ${done.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

async function liveMisses(c: Chat): Promise<string[]> {
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const { turnViewFrom } = await import("./turns");
  let live: ReturnType<typeof turnViewFrom> | undefined;
  let shown: any;
  let snapshots = 0;
  let socket!: any;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      shown = snapshot;
      snapshots += 1;
      live = turnViewFrom(
        snapshot.rows,
        new Set() as never,
        {
          working: snapshot.isWorking,
          clockOffset: snapshot.clockOffsetMs,
          turnStartedAtMs: snapshot.turnStartedAtMs,
          agentFamily: "claude",
          waitingSteers: snapshot.waitingSteers,
        } as never,
        live,
      );
    },
    undefined,
    () => (socket = new MockAcpmuxSocket(() => Promise.resolve())) as unknown as WebSocket,
  );
  const out: string[] = [];
  try {
    const id = mockHost.sessionId!;
    await settle(() => shown?.summary !== undefined);
    for (const event of c.events) {
      if (event.dir === "mux") {
        if (event.kind === "turn_started") socket.touch(id, { status: "running", turn: { turnId: event.msg?.turnId } });
        socket.emit(id, { mux: event.kind, msg: event.msg });
        if (event.kind === "turn_result") socket.touch(id, { status: "idle", turn: undefined });
      } else
        socket.emit(id, {
          update: event.msg.params.update,
          ...(event.msg.params._meta && { meta: event.msg.params._meta }),
        });
      const before = snapshots;
      await settle(() => snapshots > before);
      if (!CHECKED.has(event.kind)) continue;
      const missing = undrawn(
        c.replies.filter((reply) => reply.endSeq <= event.seq),
        live!.rows,
      );
      if (missing.length)
        out.push(`through ${event.seq}: ${missing.map((reply) => reply.turnId.slice(0, 13)).join(", ")}`);
    }
  } finally {
    client.close?.();
  }
  return out;
}

test("live: the orders a daemon logs (wrap_up after the reply, Claude Code's own turn opened in finish_turn's window or after it, the next opener 0 ms later) draw every reply as they stream", async () => {
  const failures: string[] = [];
  for (const ending of ["wrapUp", "plain"] as const)
    for (const bgAt of ["none", "afterReply", "afterResult"] as const)
      for (const bgEnd of bgAt === "none" ? (["quiet"] as const) : (["quiet", "loud"] as const))
        for (const next of ["inbox", "agent", "bgdone"] as const) {
          const c: Case = { opener: "person", ending, bgAt, bgEnd, steer: false, next, delay: 0 };
          const found = await liveMisses(chat(c));
          if (found.length) failures.push(`${caseName(c)}: ${found.join("; ")}`);
        }
  expect(failures.join("\n")).toBe("");
}, 600_000);

// ---- Red: minimized sequences, one per mechanism ------------------------------------------------
// Plain tests on purpose: they fail today. Each names the code that hides the reply.

const S = SESSION;
let mini = 0;
let clock = 1794519714000;
const muxRecord = (kind: string, msg: Record<string, unknown>): EventRecord => ({
  seq: (mini += 1),
  at: (clock += 5),
  dir: "mux",
  kind,
  sessionId: S,
  msg,
});
const chunkRecord = (segment: string, messageId: string, text: string): EventRecord => ({
  seq: (mini += 1),
  at: (clock += 5),
  dir: "in",
  kind: "agent_message_chunk",
  sessionId: S,
  msg: {
    method: "session/update",
    params: {
      _meta: { acpmux: { segment } },
      update: { sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } },
    },
  },
});
const REPLY = "One.\n\nTwo.\n\nThree.";
/// The next turn's reply: other words, so the oracle's match by text cannot find the first turn's.
const NEXT = "Four.\n\nFive.\n\nSix.";
const ask = (promptId: string, turnId: string) => [
  muxRecord("user_message", { text: "Q", promptId, turnId, client: "cmux-react-agent-pane#01a1e7" }),
  muxRecord("turn_started", { promptId, turnId, client: "cmux-react-agent-pane#01a1e7" }),
];
const done = (promptId: string, turnId: string, extra: Record<string, unknown> = {}) =>
  muxRecord("turn_result", { status: "completed", stopReason: "end_turn", promptId, turnId, ...extra });
const started = (id: string) => muxRecord("background_turn", { state: "started", id, trigger: "task_notification" });
const ended = (id: string, quiet: boolean) =>
  muxRecord("background_turn", { state: "ended", id, trigger: "task_notification", quiet, reason: "result" });
const minimal = (build: () => EventRecord[]) => {
  mini = 0;
  return build();
};
/// Every arm and family's misses of `replies` on the full replay of `events`.
function redMisses(events: EventRecord[], replies: Expected[]): string {
  return misses({ events, replies }, { prefixes: false })
    .map((miss) => `${miss.arm} ${miss.family}: ${miss.turns.join(",")}`)
    .join("\n");
}

// R1. A bracket opened before the reply's first chunk, which acpmux then called quiet. Every row
// made after the started record is the background turn's: OrderedRows.set (direct.ts:2496-2499,
// `backgroundAt` direct.ts:2371) tags the reply `inBackground`, and `hiddenInBackground`
// (backgroundTurns.ts:173-175) drops it, its turn folded by `collectFoldedBackgroundId`
// (backgroundTurns.ts:125-135; quiet, so `foldsBackground` backgroundTurns.ts:73). turns.ts:764/803
// skip it. The prompt and "Worked for" stay: user rows are never tagged (direct.ts:2496).
// Daemon: only with no `session.turn` while the turn's own reply streams (background_turn.rs
// `background_turn_update`); pre-response updates are tapped in order (agent.rs:1289-1294), so
// today only an adopted host's replay before `hold_adopted_turn` (cmuxterm-hq#6338) or a log
// written by an older daemon. Theoretical for a live daemon of this tree.
test("R1: a reply after a background_turn started record, ended quiet, draws", () => {
  const events = minimal(() => [
    ...ask("p1", "t1"),
    started("bg-3"),
    chunkRecord(`t1.${BOOT}.1`, "m1", REPLY),
    ended("bg-3", true),
    done("p1", "t1"),
  ]);
  expect(redMisses(events, [{ turnId: "t1", segment: `t1.${BOOT}.1`, text: REPLY, endSeq: 6 }])).toBe("");
});

// R1b. The same bracket still running at the turn's end (its ended record not heard yet, or never
// written): the reply is hidden as R1, `foldsBackground` true while `running`.
test("R1b: a reply after a background_turn started record draws at its turn_result while the bracket runs", () => {
  const events = minimal(() => [
    ...ask("p1", "t1"),
    started("bg-3"),
    chunkRecord(`t1.${BOOT}.1`, "m1", REPLY),
    done("p1", "t1"),
  ]);
  expect(redMisses(events, [{ turnId: "t1", segment: `t1.${BOOT}.1`, text: REPLY, endSeq: 5 }])).toBe("");
});

// R2. A started record between the reply's first and later chunks (same segment, same messageId).
// reduceBackgroundTurn calls `endAssistantSegment` (direct.ts:9292, body direct.ts:11325), so the
// next chunk is not `sameMessage`; its stamped segment's row exists, so it gets a new row
// `assistant-<seq>` (direct.ts:10666-10670), whose order is after the started record and which
// OrderedRows.set tags `inBackground` (direct.ts:2496-2499). Ended loud, the reply draws split in
// two rows ("One." and "Two. Three."); quiet or running, its tail is hidden as R1. A row's order is
// its first chunk's seq, so the first row keeps its place. Theoretical, as R1.
test("R2: a reply split by a background_turn started record draws whole (ended loud)", () => {
  const events = minimal(() => [
    ...ask("p1", "t1"),
    chunkRecord(`t1.${BOOT}.1`, "m1", "One.\n\n"),
    started("bg-4"),
    chunkRecord(`t1.${BOOT}.1`, "m1", "Two.\n\nThree."),
    ended("bg-4", false),
    done("p1", "t1"),
  ]);
  expect(redMisses(events, [{ turnId: "t1", segment: `t1.${BOOT}.1`, text: REPLY, endSeq: 7 }])).toBe("");
});

test("R2q: a reply split by a background_turn started record, ended quiet, keeps its tail", () => {
  const events = minimal(() => [
    ...ask("p1", "t1"),
    chunkRecord(`t1.${BOOT}.1`, "m1", "One.\n\n"),
    started("bg-4"),
    chunkRecord(`t1.${BOOT}.1`, "m1", "Two.\n\nThree."),
    ended("bg-4", true),
    done("p1", "t1"),
  ]);
  expect(redMisses(events, [{ turnId: "t1", segment: `t1.${BOOT}.1`, text: REPLY, endSeq: 7 }])).toBe("");
});

// R3. A bracket that never ends: every later person, inbox or agent turn's reply is the background
// turn's. `backgroundAt` (direct.ts:2371-2378) matches any order past a span with no `to`; the
// prompt is spared (user rows, direct.ts:2496), the reply and the turn's summary are tagged, and
// `hiddenInBackground` hides the reply in every arm (the summary too in the "line" look).
// Daemon: REAL after a daemon restart or hot swap while Claude Code runs its own turn:
// `BackgroundTurns` is in memory (hub/session.rs:544), `end()` is a no-op with nothing running
// (background_turn.rs:177-179), so neither append_prompt's end("prompt") (prompt_images.rs:592),
// the exit end (tap.rs:177) nor the close (turns.rs:2640) writes the old run's ended record; only
// trigger brackets are restored (hosts.rs:948, carried_turn.rs:333).
test("R3: after a background_turn that never ended, the next prompt's reply draws", () => {
  const events = minimal(() => [
    ...ask("p1", "t1"),
    chunkRecord(`t1.${BOOT}.1`, "m1", REPLY),
    done("p1", "t1"),
    started("bg-6"),
    chunkRecord(`-.${BOOT}.1`, "mb", "Nothing new."),
    ...ask("p2", "t2"),
    chunkRecord(`t2.${BOOT}.1`, "m2", NEXT),
    done("p2", "t2"),
  ]);
  expect(
    redMisses(events, [
      { turnId: "t1", segment: `t1.${BOOT}.1`, text: REPLY, endSeq: 4 },
      { turnId: "t2", segment: `t2.${BOOT}.1`, text: NEXT, endSeq: 10 },
    ]),
  ).toBe("");
});

// R3b. The same unended bracket, then a steer carried into the next turn (no user_message opens
// it: turn_started `carried`): the carried turn's reply is hidden as R3.
test("R3b: after a background_turn that never ended, a carried steer's turn draws its reply", () => {
  const events = minimal(() => [
    started("bg-1"),
    ...ask("p1", "t1"),
    chunkRecord(`t1.${BOOT}.1`, "m1", "One.\n\n"),
    muxRecord("user_message", {
      text: "also this",
      promptId: "s1",
      turnId: "t1",
      steer: true,
      client: "acpmux-outbox#01a1e7",
      control: "peer",
    }),
    done("p1", "t1", { carriedTo: { promptId: "s1", promptIds: ["s1"] } }),
    muxRecord("turn_started", {
      promptId: "s1",
      turnId: "t2",
      client: "acpmux-outbox#01a1e7",
      carried: { fromTurnId: "t1", promptIds: ["s1"] },
    }),
    chunkRecord(`t2.${BOOT}.1`, "m2", REPLY),
    done("s1", "t2"),
  ]);
  expect(redMisses(events, [{ turnId: "t2", segment: `t2.${BOOT}.1`, text: REPLY, endSeq: 9 }])).toBe("");
});

// R4. REAL, today's daemon. Claude Code starts its own turn (a task notification) right after its
// `result`: `finish_turn` has taken the turn (hub/auto_resume.rs:529-534, turns.rs:1656) and awaits
// `drain_inbound` and `turn_git` (turns.rs:1738, :1852) before it writes turn_result (turns.rs:1921),
// and `background_turn_update` reads only `session.turn()` (background_turn.rs:274-276; not
// `session.ending`), so the started record and the background turn's words land BEFORE turn A's
// turn_result. The pane's turn runs from A's prompt to A's summary, so it holds the background turn's
// rows. Once the bracket ends loud, its reply is drawn (not hidden), and `answerAt` (turns.ts:1423-1435,
// via `foldSegments` turns.ts:1513-1538) takes it as turn A's takeaway; `repliesIn` (turns.ts:1574)
// still counts A's own reply, so the open fold of the `runs` arm (claudeTurnFold.experiment.ts; open
// at turns.ts:1893-1895 for a family with no turn fold) marks it `foldedReply` (turns.ts:2030): A's
// reply draws as a folded note, the background turn's words as the turn's answer. agentFamily
// "claude" under claude-turn-fold=runs only; the default arm draws both.
test("R4: Claude Code's own turn opened before turn_result (finish_turn's window) leaves the turn's reply its answer under the runs fold", () => {
  const events = minimal(() => ask("p1", "t1"));
  const update = (data: Record<string, unknown>): EventRecord => ({
    seq: (mini += 1),
    at: (clock += 5),
    dir: "in",
    kind: String(data.sessionUpdate),
    sessionId: S,
    msg: { method: "session/update", params: { update: data } },
  });
  events.push(
    update({ sessionUpdate: "tool_call", toolCallId: "c1", title: "Bash", kind: "execute", status: "pending" }),
    update({
      sessionUpdate: "tool_call_update",
      toolCallId: "c1",
      title: "git status",
      kind: "execute",
      status: "in_progress",
      rawInput: { command: "git status" },
    }),
    update({ sessionUpdate: "tool_call_update", toolCallId: "c1", status: "completed" }),
    chunkRecord(`t1.${BOOT}.1`, "m1", REPLY),
    started("bg-7"),
    chunkRecord(`-.${BOOT}.1`, "mb", "The watcher finished.\n\nCI is green."),
    done("p1", "t1"),
    ended("bg-7", false),
  );
  expect(redMisses(events, [{ turnId: "t1", segment: `t1.${BOOT}.1`, text: REPLY, endSeq: 9 }])).toBe("");
});
