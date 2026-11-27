// RowSeq (rowSeq.ts) against a plain array: seeded random writes, appends, drops, inserts and
// moves give the same rows, and the kept prefix by chunk identity is the kept prefix by row walk.
// Then OrderedRows publishing one beside every snapshot, checked row by row, and the per-chunk cost
// of the next sequence against the snapshot copy it is to replace, with a budget and a 10x check.
// Runs on every pull request (no environment gate).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { OrderedRows } from "./direct";
import { freezeRowSeqChunks, ROW_SEQ_CHUNK, RowSeq, rowSeqKeptPrefix, rowSeqOf } from "./rowSeq";
import { keptPrefix } from "./conversation/prefixFlatMap";

/// SplitMix32-ish seeded generator, so a failure replays from its seed.
function seeded(seed: number): (below: number) => number {
  let state = seed >>> 0;
  return (below) => {
    state = (state + 0x9e3779b9) >>> 0;
    let z = state;
    z = Math.imul(z ^ (z >>> 16), 0x85ebca6b) >>> 0;
    z = Math.imul(z ^ (z >>> 13), 0xc2b2ae35) >>> 0;
    z = (z ^ (z >>> 16)) >>> 0;
    return below <= 0 ? 0 : z % below;
  };
}

function walkPrefix<T>(previous: readonly T[], next: readonly T[]): number {
  const limit = Math.min(previous.length, next.length);
  let index = 0;
  while (index < limit && previous[index] === next[index]) index += 1;
  return index;
}

type Item = { n: number };

// The oracle tests run with chunks frozen, so a write into a shared chunk throws; the timing test
// turns it off, as the app runs.
let wasFreezing = false;
beforeAll(() => {
  wasFreezing = freezeRowSeqChunks(true);
});
afterAll(() => {
  freezeRowSeqChunks(wasFreezing);
});

for (let seed = 1; seed <= 12; seed += 1) {
  test(`RowSeq matches the array it mirrors (seed ${seed})`, () => {
    const random = seeded(seed);
    let made = 0;
    const item = (): Item => ({ n: (made += 1) });
    let oracle: Item[] = Array.from({ length: random(3_000) }, item);
    let seq = RowSeq.from(oracle);
    for (let step = 0; step < 200; step += 1) {
      const before = oracle;
      oracle = oracle.slice();
      const kind = random(100);
      let first = oracle.length;
      if (kind < 40 && oracle.length > 0) {
        // A row written in place (a streamed delta): one chunk.
        const at = kind < 30 ? oracle.length - 1 - random(Math.min(oracle.length, 4)) : random(oracle.length);
        oracle[at] = item();
        seq = seq.with(at, oracle[at]!);
        first = at;
      } else {
        if (kind < 70 && oracle.length < 8_000) {
          for (let count = 1 + random(ROW_SEQ_CHUNK + 40); count > 0; count -= 1) oracle.push(item());
        } else if (kind < 82 && oracle.length > 0) {
          first = random(oracle.length);
          oracle.splice(first, 1 + random(Math.min(oracle.length - first, 3_000)));
        } else if (kind < 92) {
          first = random(oracle.length + 1);
          oracle.splice(first, 0, ...Array.from({ length: 1 + random(50) }, item));
        } else if (oracle.length > 1) {
          // A move: a row taken out and put back earlier or later.
          const from = random(oracle.length);
          const [moved] = oracle.splice(from, 1);
          const to = random(oracle.length + 1);
          oracle.splice(to, 0, moved!);
          first = Math.min(from, to);
        }
        // The maker may say less than the true kept prefix, never more.
        seq = seq.withTail(random(4) === 0 ? random(first + 1) : first, oracle);
      }
      const previousSeq = RowSeq.from(before);
      expect(seq.length).toBe(oracle.length);
      if (oracle.length > 0) {
        const at = random(oracle.length);
        expect(seq.at(at)).toBe(oracle[at]!);
      }
      expect(seq.at(oracle.length)).toBeUndefined();
      expect(seq.at(-1)).toBeUndefined();
      if (step % 50 === 0) {
        expect(seq.toArray()).toEqual(oracle);
        expect([...seq]).toEqual(oracle);
        for (const chunk of seq.chunks.slice(0, -1)) expect(chunk.length).toBe(ROW_SEQ_CHUNK);
        expect(Object.isFrozen(seq.chunks.at(-1) ?? [])).toBe(true);
      }
      // Kept prefix: shared chunks by identity equals the row walk. The previous sequence here shares
      // no chunk with `seq`, so this also checks the walk inside a chunk.
      expect(rowSeqKeptPrefix(previousSeq, seq)).toBe(walkPrefix(before, oracle));
    }
  });
}

test("the kept prefix by chunk identity equals the row walk across sequences that share chunks", () => {
  const random = seeded(99);
  let made = 0;
  const item = (): Item => ({ n: (made += 1) });
  let rows: Item[] = Array.from({ length: 12_000 }, item);
  let seq = RowSeq.from(rows);
  for (let step = 0; step < 400; step += 1) {
    const previousRows = rows;
    const previous = seq;
    rows = rows.slice();
    if (random(3) === 0) {
      const at = random(rows.length);
      rows[at] = item();
      seq = seq.with(at, rows[at]!);
    } else {
      const from = random(rows.length);
      rows.splice(from, random(3), ...Array.from({ length: random(3) }, item));
      seq = seq.withTail(from, rows);
    }
    expect(rowSeqKeptPrefix(previous, seq)).toBe(walkPrefix(previousRows, rows));
    expect(rowSeqKeptPrefix(seq, seq)).toBe(rows.length);
  }
  expect(seq.toArray()).toEqual(rows);
});

const row = (index: number, text = "fixture") => ({
  id: `row-${index}`,
  version: 1,
  at: index,
  kind: "assistant" as const,
  text,
});

for (let seed = 1; seed <= 8; seed += 1) {
  test(`OrderedRows publishes a RowSeq of every snapshot's rows (seed ${seed})`, () => {
    const verify = OrderedRows.verifyRowSeq;
    OrderedRows.verifyRowSeq = true;
    try {
      const random = seeded(seed * 7919);
      const rows = new OrderedRows();
      let next = 0;
      const ids: number[] = [];
      let previous: ReturnType<OrderedRows["sorted"]> | undefined;
      for (let step = 0; step < 600; step += 1) {
        const kind = random(100);
        if (kind < 45 || ids.length === 0) {
          rows.current = next + 1;
          rows.set(`row-${next}`, row(next));
          rows.current = undefined;
          ids.push(next);
          next += 1;
        } else if (kind < 85) {
          const id = ids[ids.length - 1 - random(Math.min(ids.length, kind < 75 ? 3 : ids.length))]!;
          const old = rows.get(`row-${id}`)!;
          rows.set(`row-${id}`, { ...old, version: old.version + 1, text: `${old.text}+` });
        } else if (kind < 95) {
          const at = random(ids.length);
          rows.delete(`row-${ids[at]}`);
          ids.splice(at, 1);
        } else {
          rows.retain(() => random(20) !== 0);
          ids.splice(0, ids.length, ...[...rows.keys()].map((key) => Number(key.slice(4))));
        }
        if (random(3) !== 0) continue;
        const snapshot = rows.sorted();
        const seq = rowSeqOf(snapshot)!;
        expect(seq).toBeDefined();
        expect(seq.length).toBe(snapshot.length);
        if (step % 100 === 0) expect(seq.toArray()).toEqual(snapshot);
        if (previous) {
          const before = rowSeqOf(previous)!;
          expect(rowSeqKeptPrefix(before, seq)).toBe(walkPrefix(previous, snapshot));
          // What the snapshot told prefixFlatMap it kept is never more than what the sequence kept.
          expect(keptPrefix(previous, snapshot)).toBeLessThanOrEqual(rowSeqKeptPrefix(before, seq));
        }
        previous = snapshot;
      }
    } finally {
      OrderedRows.verifyRowSeq = verify;
    }
  });
}

/// The fastest of `rounds` batches of `batch` calls of `body`, in ms per call: a batch smooths the
/// timer, and the fastest batch is the one the machine's other load (a loaded CI host) touched least.
function perCall(rounds: number, batch: number, body: () => void): number {
  let best = Infinity;
  for (let round = 0; round < rounds; round += 1) {
    const start = performance.now();
    for (let call = 0; call < batch; call += 1) body();
    best = Math.min(best, (performance.now() - start) / batch);
  }
  return best;
}

/// One streamed chunk at `held` rows: the reply row (the last) written in place, and every 16th
/// chunk a new row at the end. Before: the snapshot copy, `ordered.slice()`. After: the next RowSeq.
function chunkCosts(held: number): { slice: number; seq: number } {
  /// One side's chat: its own order, and the snapshots the pane still holds (PrefixFlatCache keeps
  /// 4), so they are not garbage at once.
  const side = (useSeq: boolean) => {
    const ordered: Item[] = Array.from({ length: held }, (_, n) => ({ n }));
    let seq = RowSeq.from(ordered);
    let chunk = 0;
    const live: unknown[] = [];
    return () => {
      chunk += 1;
      if (chunk % 16 === 0) {
        ordered.push({ n: -chunk });
        if (useSeq) seq = seq.withTail(ordered.length - 1, ordered);
      } else {
        ordered[ordered.length - 1] = { n: -chunk };
        if (useSeq) seq = seq.with(ordered.length - 1, ordered[ordered.length - 1]!);
      }
      live.push(useSeq ? seq : ordered.slice());
      if (live.length > 4) live.shift();
    };
  };
  const after = side(true);
  const before = side(false);
  for (let warm = 0; warm < 200; warm += 1) {
    after();
    before();
  }
  return { seq: perCall(21, 64, after), slice: perCall(11, 16, before) };
}

test("a streamed chunk's RowSeq costs one chunk, flat from 15k to 150k held rows", () => {
  const freezing = freezeRowSeqChunks(false);
  let small: { slice: number; seq: number };
  let big: { slice: number; seq: number };
  try {
    small = chunkCosts(15_000);
    big = chunkCosts(150_000);
  } finally {
    freezeRowSeqChunks(freezing);
  }
  const ratio = big.seq / Math.max(small.seq, 0.0005);
  console.log(
    `row-seq per streamed chunk: slice ${small.slice.toFixed(4)} ms @15k -> ${big.slice.toFixed(4)} ms @150k (x${(big.slice / Math.max(small.slice, 0.0005)).toFixed(1)}); ` +
      `RowSeq ${small.seq.toFixed(4)} ms @15k -> ${big.seq.toFixed(4)} ms @150k (x${ratio.toFixed(1)})`,
  );
  expect(big.seq).toBeLessThan(0.1);
  expect(big.seq).toBeLessThan(Math.max(small.seq, 0.005) * 2);
});

test("snapshot arrays built per streamed chunk (the count RowSeq readers ratchet down)", () => {
  const rows = new OrderedRows();
  for (let index = 0; index < 20_000; index += 1) {
    rows.current = index + 1;
    rows.set(`row-${index}`, row(index));
    rows.current = undefined;
  }
  rows.sorted();
  const before = OrderedRows.arraysBuilt;
  const CHUNKS = 200;
  for (let chunk = 0; chunk < CHUNKS; chunk += 1) {
    const last = rows.get("row-19999")!;
    rows.set("row-19999", { ...last, version: last.version + 1, text: `${last.text} tok${chunk}` }, false);
    rows.sorted();
  }
  const perChunk = (OrderedRows.arraysBuilt - before) / CHUNKS;
  console.log(`row-seq ratchet: snapshot arrays built per streamed chunk ${perChunk}`);
  // Today every chunk still builds its array (stage 2 of RFD 0191); the readers' moves lower this.
  expect(perChunk).toBeLessThanOrEqual(1);
});
