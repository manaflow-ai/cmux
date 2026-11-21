/// <reference types="bun" />
// l10n-allow-file: bench output labels, not shipped UI.

/**
 * The page's thin row store (rows/store.ts) on a god chat against a small one, for the design
 * doc's row 6 gates. Model-only: the host client, the receiver and the store, fed change strings
 * of the shapes the client core gives; no React, DOM or frame claim.
 *
 * - v2.pr06.page_store_apply: p95 to take one batch holding one settled row op (decode, apply,
 *   the new snapshot, `taken`), the store opened on a chat of 100,000 rows against one of 100. Each
 *   opens as the daemon opens a chat: its window at the end (the core's default, 100 rows), the god
 *   one with rows before it. Rounds alternate which side goes first; each side takes the same
 *   samples. Pass: god p95 within 1.2x of small p95.
 * - v2.pr06.page_store_held: the rows and row bytes the store holds after paging up through a chat
 *   of 20,000 rows against one of 200, a page of 400 rows at a time. Pass: the god store at or under
 *   the cap (STORE_MAX_ROWS, STORE_MAX_BYTES), whatever the chat's length.
 * - v2.pr06.page_store_text: p95 to take one batch holding one text op on an open row whose body
 *   is 200 KB against one of 1 KB. Pass: within 1.2x.
 *
 * - v2.frame_paced (reported, not judged): the document's receiver (`window.cmuxChatRows`, the
 *   acpmux.v2 chat's path) against a host that sends the next 64 KiB batch only after `taken`, with
 *   frames run by this bench on the real clock. "before" applies in the receiving task, "after" in
 *   the frame lane: apply ms per batch, batches taken per frame, the longest task, and the apply
 *   time of one 256 KiB change (PACED_BATCHES, BIG_SAMPLES).
 *
 *   bun bench/page-row-store.bench.ts
 *   ROUNDS=40 SAMPLES=250 bun bench/page-row-store.bench.ts
 *
 * The nightly's gate script runs each row alone through bench/v2-gate.ts, which imports the three
 * measures below and prints the v2 gate home's line for each.
 */
import { ChatRowsHost, type ChatRowsPost } from "../src/agent-session/acpmux/rows/host";
import {
  addChatRowsHost,
  listenForChatRows,
  receiveChatRows,
  resetChatRowsReceiver,
} from "../src/agent-session/acpmux/rows/receiver";
import { createLanes, type LanesEnv } from "../src/agent-session/acpmux/schedule";
import { STORE_MAX_BYTES, STORE_MAX_ROWS } from "../src/agent-session/acpmux/rows/store";
import { changeSid, parseChange, type ChatChange, type ChatRow } from "../src/agent-session/acpmux/rows/wire";
import { syncLanes } from "../test/support/chatRowsFeed";
import { perfRow } from "./perfRow";

const ROUNDS = Number(process.env.ROUNDS ?? 20);
const SAMPLES = Number(process.env.SAMPLES ?? 200);
const LIMIT = 1.2;
if (!Number.isSafeInteger(ROUNDS) || ROUNDS < 2 || !Number.isSafeInteger(SAMPLES) || SAMPLES < 1)
  throw new Error("ROUNDS must be an integer of at least 2 and SAMPLES a positive integer");

const WORDS = ["the", "row", "store", "keeps", "a", "window", "of", "rows", "and", "nothing", "else", "✓"];
function row(id: number): ChatRow {
  const length = 20 + ((id * 7919) % 60);
  const text = Array.from({ length }, (_, index) => WORDS[(id + index) % WORDS.length]).join(" ");
  return {
    id,
    rev: 1,
    kind: id % 5 === 0 ? "tool" : "text",
    turn: id - (id % 5),
    at: 1794480726 + id,
    open: false,
    body: { text },
    est: 1 + (length >> 4),
  };
}
const rows = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, index) => row(from + index));

/// The document's receiver (rows/receiver.ts) holding `host` alone, as the host feeds a page, on
/// lanes that apply each batch in the receiving task: each side's batches go through it and its
/// `taken` to that side's post. Set before a sample's clock. v2.frame_paced below runs its own
/// frame lanes.
function feedOnly(host: ChatRowsHost, post: ChatRowsPost): void {
  resetChatRowsReceiver();
  listenForChatRows(syncLanes());
  addChatRowsHost(host, post);
}

type Side = {
  name: "god" | "small";
  host: ChatRowsHost;
  post: ChatRowsPost;
  next: number;
  batch: number;
  ms: number[];
};

async function openSide(name: Side["name"], chatRows: number): Promise<Side> {
  let taken = 0;
  const post: ChatRowsPost = async (method, params) => {
    if (method === "chat.rows.open") return { sid: params.sid };
    if (method === "chat.rows.taken") taken += 1;
    return {};
  };
  const host = new ChatRowsHost(post, undefined, () => name);
  const opened = await host.open(`chat-${name}`);
  if (!("sid" in opened)) throw new Error(`${name}: open fell to v1`);
  const first = Math.max(1, chatRows - 99);
  const window = {
    kind: "chatWindow",
    replaces: true,
    window: {
      sid: name,
      cursor: chatRows,
      edition: 1,
      rows: rows(first, chatRows),
      hasBefore: first > 1,
      hasAfter: false,
      queue: { entries: [], count: 0 },
    },
  };
  feedOnly(host, post);
  receiveChatRows({ batch: 1, changes: [JSON.stringify(window)] });
  let drawn = 0;
  host.store.subscribe(name, () => (drawn += 1));
  const side: Side = { name, host, post, next: chatRows + 1, batch: 1, ms: [] };
  // Warm the path before timing it, on both sides alike.
  for (let index = 0; index < 50; index += 1) take(side);
  if (drawn !== 50 || taken !== 51) throw new Error(`${name}: ${drawn} draws and ${taken} taken for 50 ops`);
  side.ms = [];
  return side;
}

function take(side: Side): void {
  const id = side.next++;
  const change = JSON.stringify({
    kind: "chatOp",
    sid: side.name,
    replay: false,
    op: { op: "row", seq: id, row: row(id) },
  });
  feedOnly(side.host, side.post);
  const start = performance.now();
  receiveChatRows({ batch: ++side.batch, changes: [change] });
  side.ms.push(performance.now() - start);
}

function percentile(values: number[], share: number): number {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(share * sorted.length))]!;
}

/// One side's samples of a timed row, in ms.
export type Timed = { ms: number[]; p50: number; p95: number };
const timed = (ms: number[]): Timed => ({ ms, p50: percentile(ms, 0.5), p95: percentile(ms, 0.95) });

/// v2.pr06.page_store_apply: the god side (100,000 rows) and the small one (100).
export async function measureApply(): Promise<{ god: Timed; small: Timed }> {
  const god = await openSide("god", 100_000);
  const small = await openSide("small", 100);
  for (let round = 0; round < ROUNDS; round += 1) {
    const order = round % 2 === 0 ? [god, small] : [small, god];
    for (const side of order) for (let sample = 0; sample < SAMPLES; sample += 1) take(side);
  }
  if (god.ms.length !== small.ms.length) throw new Error("the sides took different samples");
  return { god: timed(god.ms), small: timed(small.ms) };
}

async function pageThrough(name: string, chatRows: number) {
  let taken = 0;
  const post: ChatRowsPost = async (method, params) => {
    if (method === "chat.rows.open") return { sid: params.sid };
    if (method === "chat.rows.taken") taken += 1;
    return {};
  };
  const host = new ChatRowsHost(post, undefined, () => name);
  await host.open(`chat-${name}`);
  feedOnly(host, post);
  const first = Math.max(1, chatRows - 99);
  const window = {
    sid: name,
    cursor: chatRows,
    edition: 1,
    rows: rows(first, chatRows),
    hasBefore: first > 1,
    hasAfter: false,
  };
  let batch = 0;
  receiveChatRows({ batch: ++batch, changes: [JSON.stringify({ kind: "chatWindow", replaces: true, window })] });
  let pages = 0;
  let peak = { rows: 0, bytes: 0 };
  while (host.store.snapshot(name)!.hasBefore) {
    const edge = host.store.edge(name, "before")!;
    if (!host.page(name, "before")) throw new Error(`${name}: a page was refused`);
    const from = Math.max(1, edge - 400);
    const page = { sid: name, edition: 1, rows: rows(from, edge - 1), hasBefore: from > 1, hasAfter: true };
    receiveChatRows({ batch: ++batch, changes: [JSON.stringify({ kind: "chatPage", page })] });
    const held = host.store.held(name)!;
    peak = { rows: Math.max(peak.rows, held.rows), bytes: Math.max(peak.bytes, held.bytes) };
    pages += 1;
  }
  const snapshot = host.store.snapshot(name)!;
  if (snapshot.rows[0]!.id !== 1) throw new Error(`${name}: paging stopped at ${snapshot.rows[0]!.id}`);
  if (taken !== batch) throw new Error(`${name}: ${taken} taken for ${batch} batches`);
  return { chatRows, pages, ...host.store.held(name)!, peakRows: peak.rows, peakBytes: peak.bytes };
}

export type Held = Awaited<ReturnType<typeof pageThrough>>;

/// v2.pr06.page_store_held: the god store (20,000 rows paged through) and the small one (200).
export async function measureHeld(): Promise<{ god: Held; small: Held }> {
  return { god: await pageThrough("god", 20_000), small: await pageThrough("small", 200) };
}

// v2.pr06.page_store_text: one text op on an open row of 200 KB against one of 1 KB. The store
// keeps each row's bytes and adds the piece's, so the op does not measure the row again.
type TextSide = { name: "big" | "little"; host: ChatRowsHost; post: ChatRowsPost; batch: number; ms: number[] };

async function openText(name: TextSide["name"], bodyBytes: number): Promise<TextSide> {
  const post: ChatRowsPost = async (method, params) => (method === "chat.rows.open" ? { sid: params.sid } : {});
  const host = new ChatRowsHost(post, undefined, () => name);
  await host.open(`chat-${name}`);
  const open = { ...row(101), open: true, body: { text: "x".repeat(bodyBytes) } };
  const window = {
    sid: name,
    cursor: 101,
    edition: 1,
    rows: rows(1, 100),
    open: [{ row: open }],
    hasBefore: false,
    hasAfter: false,
  };
  feedOnly(host, post);
  receiveChatRows({ batch: 1, changes: [JSON.stringify({ kind: "chatWindow", replaces: true, window })] });
  const side: TextSide = { name, host, post, batch: 1, ms: [] };
  for (let index = 0; index < 50; index += 1) appendText(side);
  side.ms = [];
  return side;
}

function appendText(side: TextSide): void {
  const change = JSON.stringify({
    kind: "chatOp",
    sid: side.name,
    replay: false,
    op: { op: "text", seq: side.batch, rowId: 101, text: "a piece " },
  });
  feedOnly(side.host, side.post);
  const start = performance.now();
  receiveChatRows({ batch: ++side.batch, changes: [change] });
  side.ms.push(performance.now() - start);
}

/// v2.pr06.page_store_text: the open row of 200 KB (big) and the one of 1 KB (little).
export async function measureText(): Promise<{ big: Timed; little: Timed }> {
  const big = await openText("big", 200 * 1024);
  const little = await openText("little", 1024);
  for (let round = 0; round < ROUNDS; round += 1) {
    const order = round % 2 === 0 ? [big, little] : [little, big];
    for (const side of order) for (let sample = 0; sample < SAMPLES; sample += 1) appendText(side);
  }
  return { big: timed(big.ms), little: timed(little.ms) };
}

/// The held measure's pass: the god store at or under the cap, rows and bytes.
export const heldUnderCap = (god: Held) => god.peakRows <= STORE_MAX_ROWS && god.peakBytes <= STORE_MAX_BYTES;

// v2.frame_paced: the document's receiver (rows/receiver.ts, the path `window.cmuxChatRows`
// takes), fed as the v2 row host feeds it: one batch of at most 64 KiB, the next only after
// `taken`, which the host reads in a later task. Frames are a loop run here on the real clock:
// each frame runs its rAF callbacks, then every task they and the host post. "before" is the
// receiver as it was before frame pacing (`receiveInTask`, a copy of its body: decode the batch,
// one applyBatch, taken, all in the receiving task); "after" is rows/receiver.ts in the frame lane
// (schedule/lanes.ts on this engine). Reports apply ms per batch, batches taken per frame, the
// stream ms of the busiest frame, the longest task, and the apply time of one 256 KiB change.
function receiveInTask(host: ChatRowsHost, post: ChatRowsPost, event: { batch: number; changes: readonly string[] }) {
  const changes: ChatChange[] = [];
  for (const line of event.changes) {
    const change = parseChange(line);
    if (change && changeSid(change) !== null && host.store.has(changeSid(change)!)) changes.push(change);
  }
  try {
    host.store.applyBatch(changes);
  } finally {
    void post("chat.rows.taken", { batch: event.batch }).catch(() => {});
  }
}

function frameLoopEngine() {
  let frames: (() => void)[] = [];
  const tasks: (() => void)[] = [];
  let longest = 0;
  /// Main-thread ms spent in tasks so far, and the start of the one running now.
  let spent = 0;
  let runningSince: number | null = null;
  const runTimed = (cb: () => void) => {
    const start = performance.now();
    runningSince = start;
    cb();
    runningSince = null;
    const took = performance.now() - start;
    spent += took;
    longest = Math.max(longest, took);
  };
  const env: LanesEnv = {
    now: () => performance.now(),
    requestFrame: (cb) => frames.push(cb),
    postTask: (cb) => tasks.push(cb),
    setTimer: () => () => {},
    hidden: () => false,
    listen: () => () => {},
    reportError: (error) => {
      throw error;
    },
  };
  return {
    env,
    post: (cb: () => void) => tasks.push(cb),
    /** Main-thread ms in tasks so far, the running one's included. */
    busy: () => spent + (runningSince === null ? 0 : performance.now() - runningSince),
    /** One frame: its rAF callbacks, then every task until none is left. */
    async frame() {
      const run = frames;
      frames = [];
      for (const cb of run) runTimed(cb);
      await Promise.resolve();
      for (let guard = 0; tasks.length && guard < 100_000; guard += 1) {
        runTimed(tasks.shift()!);
        await new Promise<void>((resolve) => setImmediate(resolve));
      }
    },
    get longest() {
      return longest;
    },
    resetLongest() {
      longest = 0;
    },
  };
}

/// Batches of row ops of about `batchBytes` each, `count` of them, for sid `sid`.
function rowBatches(sid: string, firstId: number, count: number, batchBytes: number): string[][] {
  const out: string[][] = [];
  let id = firstId;
  for (let index = 0; index < count; index += 1) {
    const changes: string[] = [];
    let bytes = 0;
    while (bytes < batchBytes - 400) {
      const change = JSON.stringify({ kind: "chatOp", sid, replay: false, op: { op: "row", seq: id, row: row(id) } });
      id += 1;
      bytes += change.length;
      changes.push(change);
    }
    out.push(changes);
  }
  return out;
}

async function framePaced(mode: "before" | "after", batchCount: number) {
  resetChatRowsReceiver();
  const engine = frameLoopEngine();
  const lanes = mode === "before" ? null : createLanes(engine.env);
  const sid = `paced-${mode}`;
  const batches = rowBatches(sid, 101, batchCount, 64 * 1024);
  let sent = 0;
  let takenThisFrame = 0;
  const applyMs: number[] = [];
  let sentAt = 0;
  const post: ChatRowsPost = async (method, params) => {
    if (method === "chat.rows.open") return { sid: params.sid };
    if (method === "chat.rows.taken") {
      takenThisFrame += 1;
      applyMs.push(engine.busy() - sentAt);
      // The host reads `taken` in a later task and sends the next batch then.
      engine.post(send);
    }
    return {};
  };
  const host = new ChatRowsHost(post, undefined, () => sid);
  addChatRowsHost(host, post);
  await host.open(`chat-${sid}`);
  const window = { sid, cursor: 100, edition: 1, rows: rows(1, 100), hasBefore: false, hasAfter: false };
  host.store.applyBatch([{ kind: "chatWindow", replaces: true, window } as never]);
  function send() {
    if (sent >= batches.length) return;
    sentAt = engine.busy();
    const event = { batch: ++sent, changes: batches[sent - 1]! };
    if (lanes) receiveChatRows(event, lanes);
    else receiveInTask(host, post, event);
  }
  const perFrame: number[] = [];
  /// Main-thread ms of stream work between one frame and the next.
  const frameMs: number[] = [];
  engine.resetLongest();
  engine.post(send);
  for (let frame = 0; frame < batchCount * 4 && applyMs.length < batchCount; frame += 1) {
    takenThisFrame = 0;
    const busyBefore = engine.busy();
    await engine.frame();
    perFrame.push(takenThisFrame);
    frameMs.push(engine.busy() - busyBefore);
  }
  if (applyMs.length !== batchCount) throw new Error(`${mode}: ${applyMs.length} of ${batchCount} batches taken`);
  lanes?.dispose();
  const framesWithWork = perFrame.filter((count) => count > 0);
  return {
    batches: batchCount,
    changesPerBatch: batches[0]!.length,
    applyP50Ms: round4(percentile(applyMs, 0.5)),
    applyP95Ms: round4(percentile(applyMs, 0.95)),
    maxTakenPerFrame: Math.max(...perFrame),
    framesUsed: framesWithWork.length,
    busiestFrameMs: round4(Math.max(...frameMs)),
    longestTaskMs: round4(engine.longest),
  };
}

/// One change of 256 KiB (a settled row whose body is that big), applied whole in one frame slice:
/// parse, apply, commit, `taken`. Each sample is its own batch.
async function bigChange(samples: number) {
  resetChatRowsReceiver();
  const engine = frameLoopEngine();
  const lanes = createLanes(engine.env);
  const sid = "paced-big";
  const host = new ChatRowsHost(
    async (method, params) => (method === "chat.rows.open" ? { sid: params.sid } : {}),
    undefined,
    () => sid,
  );
  addChatRowsHost(host, async () => ({}));
  await host.open(`chat-${sid}`);
  const window = { sid, cursor: 100, edition: 1, rows: rows(1, 100), hasBefore: false, hasAfter: false };
  host.store.applyBatch([{ kind: "chatWindow", replaces: true, window } as never]);
  const ms: number[] = [];
  let id = 101;
  for (let sample = 0; sample < samples + 5; sample += 1) {
    const base = row(id);
    const big = { ...base, body: { text: "x".repeat(256 * 1024 - 300) } };
    const change = JSON.stringify({ kind: "chatOp", sid, replay: false, op: { op: "row", seq: id, row: big } });
    id += 1;
    receiveChatRows({ batch: sample + 1, changes: [change] }, lanes);
    engine.resetLongest();
    await engine.frame();
    if (sample >= 5) ms.push(engine.longest);
  }
  lanes.dispose();
  resetChatRowsReceiver();
  return {
    changeBytes: 256 * 1024,
    p50Ms: round4(percentile(ms, 0.5)),
    p95Ms: round4(percentile(ms, 0.95)),
    maxMs: round4(Math.max(...ms)),
  };
}

const round4 = (value: number) => Number(value.toFixed(4));
const PACED_BATCHES = Number(process.env.PACED_BATCHES ?? 60);

async function main(): Promise<void> {
  const { god, small } = await measureApply();
  const applyRatio = god.p95 / Math.max(small.p95, Number.EPSILON);
  const applyOk = applyRatio <= LIMIT;
  const { god: heldGod, small: heldSmall } = await measureHeld();
  const heldOk = heldUnderCap(heldGod);
  const { big, little } = await measureText();
  const textRatio = big.p95 / Math.max(little.p95, Number.EPSILON);
  const textOk = textRatio <= LIMIT;
  const pacedBefore = await framePaced("before", PACED_BATCHES);
  const pacedAfter = await framePaced("after", PACED_BATCHES);
  const big256 = await bigChange(Number(process.env.BIG_SAMPLES ?? 40));
  resetChatRowsReceiver();
  console.log(
    JSON.stringify(
      {
        scope: "model-only; the host client and the store, no React, DOM, WebKit or frame claim",
        rounds: ROUNDS,
        samplesPerSide: god.ms.length,
        "v2.pr06.page_store_apply": {
          godRows: 100_000,
          smallRows: 100,
          godP50Ms: round4(god.p50),
          godP95Ms: round4(god.p95),
          smallP50Ms: round4(small.p50),
          smallP95Ms: round4(small.p95),
          ratio: Number(applyRatio.toFixed(3)),
          limit: LIMIT,
          pass: applyOk,
        },
        "v2.pr06.page_store_text": {
          bigBodyBytes: 200 * 1024,
          littleBodyBytes: 1024,
          bigP50Ms: round4(big.p50),
          bigP95Ms: round4(big.p95),
          littleP50Ms: round4(little.p50),
          littleP95Ms: round4(little.p95),
          ratio: Number(textRatio.toFixed(3)),
          limit: LIMIT,
          pass: textOk,
        },
        "v2.pr06.page_store_held": {
          cap: { rows: STORE_MAX_ROWS, bytes: STORE_MAX_BYTES },
          god: heldGod,
          small: heldSmall,
          pass: heldOk,
        },
        "v2.frame_paced": {
          scope: "the document receiver against a host that sends the next 64 KiB batch after taken; frames run here",
          before: pacedBefore,
          after: pacedAfter,
          change256KiB: big256,
        },
      },
      null,
      2,
    ),
  );
  perfRow({ name: "v2.pr06.page_store_apply.god", p50: god.p50, p95: god.p95 });
  perfRow({ name: "v2.pr06.page_store_apply.small", p50: small.p50, p95: small.p95 });
  perfRow({ name: "v2.pr06.page_store_text.big", p50: big.p50, p95: big.p95 });
  perfRow({ name: "v2.pr06.page_store_text.little", p50: little.p50, p95: little.p95 });
  perfRow({ name: "v2.pr06.page_store_held.rows", p95: heldGod.peakRows, unit: "rows", target: STORE_MAX_ROWS });
  perfRow({ name: "v2.pr06.page_store_held.bytes", p95: heldGod.peakBytes, unit: "bytes", target: STORE_MAX_BYTES });
  if (!applyOk || !heldOk || !textOk) {
    console.error(
      `page-row-store: ${applyOk ? "" : `apply ratio ${applyRatio.toFixed(3)} over ${LIMIT}; `}${textOk ? "" : `text ratio ${textRatio.toFixed(3)} over ${LIMIT}; `}${heldOk ? "" : "held over the cap"}`,
    );
    process.exit(1);
  }
}

if (import.meta.main) await main();
