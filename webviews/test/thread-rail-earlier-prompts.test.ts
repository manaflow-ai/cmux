// l10n-allow-file: test fixture prompts, not shipped UI.
// The chat's prompts older than the transcript, for the thread rail (Leo 2026-10-25: "if you
// haven't loaded in chats ... the session rails ... should be able to still, like, gradually load
// that stuff in"). They come from acpmux's records that say where a turn starts, a page per idle
// callback (earlierPrompts.ts), keyed as their turns will be once loaded (turnKey: the promptId,
// never the shown text). Which prompts open a turn is decided as the transcript decides it: a test
// reads one history both ways and compares.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnKey } from "../src/agent-session/acpmux/threadMinimap/model";
import { opensTurn } from "../src/agent-session/acpmux/turnStart";
import {
  EarlierPrompts,
  PROMPT_PAGE_LIMIT,
  type PromptPage,
  type PromptRecord,
} from "../src/agent-session/acpmux/threadMinimap/earlierPrompts";
import { fakeClient, records, settle, type FakeRecord } from "./support/fakeAcpmuxClient";

const prompt = (seq: number, text = `Question ${seq}`): AcpmuxRow => ({
  id: `user-${seq}`,
  version: 1,
  at: seq,
  kind: "user",
  text,
});
/// acpmux's paging over `user_message` records: the newest `limit` before `beforeSeq`.
function promptLog(count: number, steerEvery = 0) {
  const log: PromptRecord[] = [];
  for (let n = 1; n <= count; n++)
    log.push({
      seq: 2 * n,
      kind: "user_message",
      dir: "mux",
      msg: { text: `Question ${n}`, ...(steerEvery && n % steerEvery === 0 ? { steer: true } : {}) },
    });
  const reads: { beforeSeq: number; got: number }[] = [];
  const read = async (_sessionId: string, beforeSeq: number): Promise<PromptPage> => {
    const before = log.filter((record) => record.seq < beforeSeq);
    const events = before.slice(Math.max(0, before.length - PROMPT_PAGE_LIMIT));
    reads.push({ beforeSeq, got: events.length });
    return { events, hasMore: before.length > PROMPT_PAGE_LIMIT };
  };
  return { read, reads };
}

const toRow = (record: PromptRecord): AcpmuxRow | undefined => prompt(record.seq, String(record.msg?.text ?? ""));

/// Idle callbacks the test runs one at a time: each reads one page, never more.
function manualIdle() {
  const queue: (() => void)[] = [];
  return {
    queue,
    request(run: () => void) {
      queue.push(run);
      return () => {
        const at = queue.indexOf(run);
        if (at >= 0) queue.splice(at, 1);
      };
    },
  };
}

const flush = async () => {
  for (let n = 0; n < 4; n++) await Promise.resolve();
};

test("a 4,000-prompt chat with its last 50 loaded reads the rest, one page per idle callback, then stops", async () => {
  const { read, reads } = promptLog(4000);
  const idle = manualIdle();
  let changes = 0;
  /// How many prompts the rail would draw at each call: it draws all of them again each time.
  const drawn: number[] = [];
  const earlier = new EarlierPrompts(
    read,
    toRow,
    () => {
      changes++;
      drawn.push(earlier.shown(7902).length);
    },
    idle,
  );
  // The transcript holds turns 3951 to 4000: its first record is Question 3951's (seq 7902).
  earlier.start("s", 7902);
  expect(reads).toHaveLength(0);
  let callbacks = 0;
  while (idle.queue.length) {
    callbacks += 1;
    const before = reads.length;
    idle.queue.shift()!();
    await flush();
    // One read per callback, at most a page of records.
    expect(reads.length - before).toBe(1);
    expect(reads.at(-1)!.got).toBeLessThanOrEqual(PROMPT_PAGE_LIMIT);
  }
  expect(callbacks).toBe(Math.ceil(3950 / PROMPT_PAGE_LIMIT));
  expect(earlier.loading).toBe(false);
  // Fewer draws than pages, the last one whole: what the rail draws over the load is O(n), at most
  // three times the prompts, where a draw per page drew O(n²) (10 pages: 5.6 times here).
  expect(changes).toBeLessThan(callbacks);
  expect(drawn.at(-1)).toBe(3950);
  expect(drawn.reduce((sum, count) => sum + count, 0)).toBeLessThanOrEqual(3 * 3950);
  const shown = earlier.shown(7902);
  expect(shown).toHaveLength(3950);
  expect(shown[0]!.text).toBe("Question 1");
  expect(shown.at(-1)!.text).toBe("Question 3950");
  // The same list while nothing moved; older turns loaded drop the prompts they now draw.
  expect(earlier.shown(7902)).toBe(shown);
  expect(earlier.shown(7842)).toHaveLength(3920);
  // Asked again for the same chat, it reads nothing more.
  earlier.start("s", 7842);
  expect(idle.queue).toHaveLength(0);
});

test("a page appends its own prompts: earlier pages' rows are kept, never copied or built again", async () => {
  const { read } = promptLog(1300);
  const idle = manualIdle();
  const built: number[] = [];
  const earlier = new EarlierPrompts(
    read,
    (record) => {
      built.push(record.seq);
      return toRow(record);
    },
    () => {},
    idle,
  );
  earlier.start("s", 2602);
  idle.queue.shift()!();
  await flush();
  const first = earlier.shown(2602);
  const newest = first.at(-1)!;
  while (idle.queue.length) {
    idle.queue.shift()!();
    await flush();
  }
  // Each prompt's row was built once, and the first page's rows are the same objects.
  expect(built).toHaveLength(1300);
  expect(new Set(built).size).toBe(1300);
  expect(earlier.shown(2602).at(-1)).toBe(newest);
});

test("steers open no turn on the rail, and a chat switch stops the reading", async () => {
  const { read, reads } = promptLog(900, 10);
  const idle = manualIdle();
  const earlier = new EarlierPrompts(read, toRow, () => {}, idle);
  earlier.start("s", 1602);
  idle.queue.shift()!();
  await flush();
  // Questions 401 to 800, less the 40 steers among them.
  expect(earlier.shown(1602)).toHaveLength(360);
  expect(idle.queue).toHaveLength(1);
  earlier.stop();
  expect(idle.queue).toHaveLength(0);
  expect(earlier.shown(1602)).toHaveLength(0);
  expect(reads).toHaveLength(1);
});

test("a failed read stops the reading instead of retrying in a loop", async () => {
  const idle = manualIdle();
  const earlier = new EarlierPrompts(
    async () => {
      throw new Error("down");
    },
    toRow,
    () => {},
    idle,
  );
  earlier.start("s", 500);
  idle.queue.shift()!();
  await flush();
  expect(earlier.loading).toBe(false);
  expect(idle.queue).toHaveLength(0);
});

test("an in-flight index page is inert after a chat switch or dispose", async () => {
  const idle = manualIdle();
  let resolve!: (page: PromptPage) => void;
  let changes = 0;
  const earlier = new EarlierPrompts(
    () => new Promise<PromptPage>((done) => (resolve = done)),
    toRow,
    () => {
      changes++;
    },
    idle,
  );
  earlier.start("chat-a", 500);
  idle.queue.shift()!();
  earlier.stop();
  resolve({ events: [{ seq: 2, at: 2, kind: "user_message", dir: "mux", msg: { text: "stale" } }], hasMore: false });
  await flush();
  expect(changes).toBe(0);
  expect(earlier.shown(500)).toHaveLength(0);
  expect(earlier.loading).toBe(false);
});

test("index-only pages leave the transcript cursor and row identities alone", async () => {
  const history = records(
    CHAT,
    Array.from(
      { length: 240 },
      (_, index) => ["mux", "user_message", { text: `Question ${index + 1}`, promptId: `p-${index + 1}` }] as Step,
    ),
  );
  const pane = await fakeClient(history, { page: 40 });
  await settle(40);
  const before = pane.snapshot();
  const firstSeq = before.historyFrom;
  const rows = before.rows;
  await settle(120);
  expect(pane.snapshot().historyFrom).toBe(firstSeq);
  expect(pane.snapshot().rows).toBe(rows);
  expect(pane.reads.some((params) => params.kinds?.includes("user_message"))).toBe(true);
  expect(pane.reads.some((params) => params.kinds?.includes("transcript"))).toBe(false);
});

test("loadThrough materializes an indexed prompt through history paging", async () => {
  const history = records(
    CHAT,
    Array.from(
      { length: 240 },
      (_, index) => ["mux", "user_message", { text: `Question ${index + 1}`, promptId: `p-${index + 1}` }] as Step,
    ),
  );
  const pane = await fakeClient(history, { page: 40 });
  await settle(40);
  const cursor = pane.snapshot().historyFrom;
  await pane.client.loadThrough(5);
  expect(pane.snapshot().historyFrom).toBeLessThan(cursor ?? 0);
  expect(pane.rows().some((row) => row.id === "user-5")).toBe(true);
  // The index method has no view or scroll handle; only the normal transcript page changed here.
  expect(pane.reads.some((params) => params.kinds?.includes("transcript"))).toBe(true);
  expect(pane.client.loadThrough.toString()).not.toContain("scrollTop");
});

// The transcript's own reading of one history against the rail's: a chat with steers, prompts sent
// now that go on with the turn they stopped (one whose stop lands at a page's edge), one removed
// before it ran, a failed turn, and addressed messages from other chats.
const CHAT = "0190a000-0000-7000-8000-0000000ea71e";
const PANEL = { sessionId: "0190a000-0000-7000-8000-0000000ea71f", name: "summary-panel", cwd: "/x", status: "idle" };
const say = (text: string) => ({
  method: "session/update",
  params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});
type Step = [string, string, Record<string, unknown>];
function chatHistory(turns: number): FakeRecord[] {
  const steps: Step[] = [];
  for (let n = 1; n <= turns; n++) {
    const id = `p-${n}`;
    const text = n % 9 === 0 ? `summary-panel -> claude-sr2: report ${n}` : `Question ${n}`;
    steps.push(["mux", "user_message", { text, promptId: id, turnId: `t-${n}`, client: "acpmux-peer#1" }]);
    steps.push(["mux", "turn_started", { promptId: id, turnId: `t-${n}` }]);
    if (n % 7 === 0)
      steps.push(["mux", "user_message", { text: `steer ${n}`, promptId: `s-${n}`, turnId: `t-${n}`, steer: true }]);
    steps.push(["in", "agent_message_chunk", say(`Answer ${n}`)]);
    if (n % 5 === 0) {
      // A prompt sent now: next in the queue, the turn cancelled, then it runs and goes on with it.
      const now = `now-${n}`;
      steps.push(["mux", "queued", { text: `Send now ${n}`, promptId: now, turnId: `tn-${n}` }]);
      steps.push(["mux", "queue_order", { promptId: now, order: [now], next: true }]);
      steps.push(["mux", "turn_result", { status: "cancelled", turnId: `t-${n}` }]);
      steps.push(["mux", "dequeued", { promptId: now }]);
      steps.push(["mux", "user_message", { text: `Send now ${n}`, promptId: now, turnId: `tn-${n}` }]);
      steps.push(["mux", "turn_started", { promptId: now, turnId: `tn-${n}` }]);
      steps.push(["mux", "turn_result", { status: "completed", turnId: `tn-${n}` }]);
    } else if (n % 11 === 0) {
      // Sent now, then taken back before it ran: the next prompt opens its own turn.
      const gone = `gone-${n}`;
      steps.push(["mux", "queued", { text: `Taken back ${n}`, promptId: gone, turnId: `tg-${n}` }]);
      steps.push(["mux", "queue_order", { promptId: gone, order: [gone], next: true }]);
      steps.push(["mux", "queue_removed", { promptId: gone }]);
      steps.push(["mux", "turn_result", { status: "completed", turnId: `t-${n}` }]);
    } else steps.push(["mux", "turn_result", { status: n % 13 === 0 ? "failed" : "completed", turnId: `t-${n}` }]);
  }
  return records(CHAT, steps);
}

/// The records from turn `turn`'s prompt on: an attach page that starts at a clean turn.
const fromTurn = (history: FakeRecord[], turn: number) =>
  history.length - history.findIndex((event) => event.kind === "user_message" && event.msg.promptId === `p-${turn}`);

async function railOf(history: FakeRecord[], page: number, sessions: Record<string, unknown>[] = []) {
  const pane = await fakeClient(history, { page, sessions });
  await settle(80);
  return pane;
}

/// The prompts that open a turn, as the rail reads them: the earlier ones, then the loaded rows'.
const ticksOf = (pane: Awaited<ReturnType<typeof fakeClient>>) => {
  const rows = [...pane.client.earlier.get(), ...pane.snapshot().rows.filter(opensTurn)];
  return rows.map((row) => ({ key: turnKey(CHAT, row), prompt: (row.text ?? "").replace(/\s+/g, " ").trim() }));
};

test("the rail's earlier prompts are the turns the transcript draws once it holds them all", async () => {
  const history = chatHistory(120);
  const whole = await fakeClient([...history], { sessions: [PANEL] });
  const expected = ticksOf(whole);
  // The tail alone: its earlier prompts are read in pages, some of which end at a sent-now's stop.
  const tail = await railOf([...history], fromTurn(history, 101), [PANEL]);
  const reads = tail.reads.filter((read) => Array.isArray(read.kinds) && read.kinds.includes("queue_order"));
  expect(reads.length).toBeGreaterThan(0);
  const got = ticksOf(tail);
  expect(got.map((tick) => tick.key)).toEqual(expected.map((tick) => tick.key));
  expect(got.map((tick) => tick.prompt)).toEqual(expected.map((tick) => tick.prompt));
});

test("a page that ends at a prompt sent now leaves it off the rail, as the transcript does", async () => {
  // Pages of 400 records: find a history where a sent-now prompt is the first opener of a page.
  const history = chatHistory(400);
  const whole = await fakeClient([...history]);
  const expected = ticksOf(whole);
  const tail = await railOf([...history], fromTurn(history, 391));
  expect(ticksOf(tail).map((tick) => tick.key)).toEqual(expected.map((tick) => tick.key));
  // A continuation unloaded, then loaded: the tick count and keys hold.
  for (let n = 0; n < 40 && tail.snapshot().canLoadOlder; n++) {
    await tail.client.loadOlder();
    await settle();
    expect(ticksOf(tail).map((tick) => tick.key)).toEqual(expected.map((tick) => tick.key));
  }
});

test("an addressed message whose sender is listed late shows as its message, under the same key", async () => {
  const history = chatHistory(40);
  const tail = await railOf([...history], fromTurn(history, 31));
  const before = ticksOf(tail);
  const report = before.find((tick) => tick.prompt.includes("report 9"))!;
  expect(report.prompt).toBe("summary-panel -> claude-sr2: report 9");
  let heard = 0;
  const off = tail.client.earlier.subscribe(() => heard++);
  tail.list([PANEL]);
  await settle(40);
  off();
  expect(heard).toBeGreaterThan(0);
  // The rail hears the change from its own store, without a snapshot of the pane.
  const after = ticksOf(tail);
  const shown = after.find((tick) => tick.key === report.key)!;
  expect(shown).toBeDefined();
  expect(shown.prompt).not.toContain("summary-panel ->");
  // Every key holds, so a jump waiting for that turn by key still finds it.
  expect(after.map((tick) => tick.key)).toEqual(before.map((tick) => tick.key));
});
