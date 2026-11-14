/// <reference types="bun" />
// l10n-allow-file: bench output labels, not shipped UI.

/**
 * The page's thin row store (rows/store.ts) on a god chat against a small one, for the design
 * doc's row 6 gates. Model-only: the host client and the store, fed change strings of the shapes
 * the client core gives; no React, DOM or frame claim.
 *
 * - v2.pr06.page_store_apply: p95 to take one batch holding one settled row op (decode, apply,
 *   the new snapshot, `taken`), the store opened on a chat of 100,000 rows against one of 100. Each
 *   opens as the daemon opens a chat: its window at the end (the core's default, 100 rows), the god
 *   one with rows before it. Rounds alternate which side goes first; each side takes the same
 *   samples. Pass: god p95 within 1.2x of small p95.
 * - v2.pr06.page_store_held: the rows and row bytes the store holds after paging up through a chat
 *   of 20,000 rows against one of 200, a page of 400 rows at a time. Pass: the god store at or under
 *   the cap (STORE_MAX_ROWS, STORE_MAX_BYTES), whatever the chat's length.
 *
 *   bun bench/page-row-store.bench.ts
 *   ROUNDS=40 SAMPLES=250 bun bench/page-row-store.bench.ts
 */
import { ChatRowsHost } from "../src/agent-session/acpmux/rows/host";
import { STORE_MAX_BYTES, STORE_MAX_ROWS } from "../src/agent-session/acpmux/rows/store";
import type { ChatRow } from "../src/agent-session/acpmux/rows/wire";
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

type Side = { name: "god" | "small"; host: ChatRowsHost; next: number; batch: number; ms: number[] };

async function openSide(name: Side["name"], chatRows: number): Promise<Side> {
  let taken = 0;
  const host = new ChatRowsHost(async (method) => {
    if (method === "chat.rows.open") return { sid: name };
    if (method === "chat.rows.taken") taken += 1;
    return {};
  });
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
  host.receive({ batch: 1, changes: [JSON.stringify(window)] });
  let drawn = 0;
  host.store.subscribe(name, () => (drawn += 1));
  const side: Side = { name, host, next: chatRows + 1, batch: 1, ms: [] };
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
  const start = performance.now();
  side.host.receive({ batch: ++side.batch, changes: [change] });
  side.ms.push(performance.now() - start);
}

function percentile(values: number[], share: number): number {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(share * sorted.length))]!;
}

const god = await openSide("god", 100_000);
const small = await openSide("small", 100);
for (let round = 0; round < ROUNDS; round += 1) {
  const order = round % 2 === 0 ? [god, small] : [small, god];
  for (const side of order) for (let sample = 0; sample < SAMPLES; sample += 1) take(side);
}
if (god.ms.length !== small.ms.length) throw new Error("the sides took different samples");
const godP95 = percentile(god.ms, 0.95);
const smallP95 = percentile(small.ms, 0.95);
const applyRatio = godP95 / Math.max(smallP95, Number.EPSILON);

async function pageThrough(name: string, chatRows: number) {
  let taken = 0;
  const host = new ChatRowsHost(async (method) => {
    if (method === "chat.rows.open") return { sid: name };
    if (method === "chat.rows.taken") taken += 1;
    return {};
  });
  await host.open(`chat-${name}`);
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
  host.receive({ batch: ++batch, changes: [JSON.stringify({ kind: "chatWindow", replaces: true, window })] });
  let pages = 0;
  let peak = { rows: 0, bytes: 0 };
  while (host.store.snapshot(name)!.hasBefore) {
    const edge = host.store.edge(name, "before")!;
    if (!host.page(name, "before")) throw new Error(`${name}: a page was refused`);
    const from = Math.max(1, edge - 400);
    const page = { sid: name, edition: 1, rows: rows(from, edge - 1), hasBefore: from > 1, hasAfter: true };
    host.receive({ batch: ++batch, changes: [JSON.stringify({ kind: "chatPage", page })] });
    const held = host.store.held(name)!;
    peak = { rows: Math.max(peak.rows, held.rows), bytes: Math.max(peak.bytes, held.bytes) };
    pages += 1;
  }
  const snapshot = host.store.snapshot(name)!;
  if (snapshot.rows[0]!.id !== 1) throw new Error(`${name}: paging stopped at ${snapshot.rows[0]!.id}`);
  if (taken !== batch) throw new Error(`${name}: ${taken} taken for ${batch} batches`);
  return { chatRows, pages, ...host.store.held(name)!, peakRows: peak.rows, peakBytes: peak.bytes };
}

const heldGod = await pageThrough("god", 20_000);
const heldSmall = await pageThrough("small", 200);
const heldOk = heldGod.peakRows <= STORE_MAX_ROWS && heldGod.peakBytes <= STORE_MAX_BYTES;
const applyOk = applyRatio <= LIMIT;

const round4 = (value: number) => Number(value.toFixed(4));
console.log(
  JSON.stringify(
    {
      scope: "model-only; the host client and the store, no React, DOM, WebKit or frame claim",
      rounds: ROUNDS,
      samplesPerSide: god.ms.length,
      "v2.pr06.page_store_apply": {
        godRows: 100_000,
        smallRows: 100,
        godP50Ms: round4(percentile(god.ms, 0.5)),
        godP95Ms: round4(godP95),
        smallP50Ms: round4(percentile(small.ms, 0.5)),
        smallP95Ms: round4(smallP95),
        ratio: Number(applyRatio.toFixed(3)),
        limit: LIMIT,
        pass: applyOk,
      },
      "v2.pr06.page_store_held": {
        cap: { rows: STORE_MAX_ROWS, bytes: STORE_MAX_BYTES },
        god: heldGod,
        small: heldSmall,
        pass: heldOk,
      },
    },
    null,
    2,
  ),
);
perfRow({ name: "v2.pr06.page_store_apply.god", p50: percentile(god.ms, 0.5), p95: godP95 });
perfRow({ name: "v2.pr06.page_store_apply.small", p50: percentile(small.ms, 0.5), p95: smallP95 });
perfRow({ name: "v2.pr06.page_store_held.rows", p95: heldGod.peakRows, unit: "rows", target: STORE_MAX_ROWS });
perfRow({ name: "v2.pr06.page_store_held.bytes", p95: heldGod.peakBytes, unit: "bytes", target: STORE_MAX_BYTES });
if (!applyOk || !heldOk) {
  console.error(
    `page-row-store: ${applyOk ? "" : `apply ratio ${applyRatio.toFixed(3)} over ${LIMIT}; `}${heldOk ? "" : "held over the cap"}`,
  );
  process.exit(1);
}
