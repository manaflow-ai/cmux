import { expect, test } from "bun:test";
import {
  ArrayMemoryStore,
  compact,
  decompose,
  MAX_LINE_BYTES,
  toLines,
  wake,
  wakeCover,
} from "../src/index.ts";

test("decompose covers [0, n) with shrinking aligned blocks", () => {
  expect(decompose(13)).toEqual([
    { lo: 0, hi: 7 },
    { lo: 8, hi: 11 },
    { lo: 12, hi: 12 },
  ]);
  expect(decompose(1)).toEqual([{ lo: 0, hi: 0 }]);
});

test("wake cover splits newest blocks first and stays within budget", () => {
  const cover = wakeCover(1000, 20);
  expect(cover.length).toBeLessThanOrEqual(20);
  // Contiguous, in order, covering everything.
  expect(cover[0].lo).toBe(0);
  expect(cover.at(-1)!.hi).toBe(999);
  for (let i = 1; i < cover.length; i++) expect(cover[i].lo).toBe(cover[i - 1].hi + 1);
  // The newest entries are raw lines; the oldest block is coarse.
  expect(cover.at(-1)!.lo).toBe(cover.at(-1)!.hi);
  expect(cover[0].hi - cover[0].lo).toBeGreaterThan(100);
  // A small log is shown raw.
  expect(wakeCover(5, 20).every((r) => r.lo === r.hi)).toBe(true);
});

test("long text splits into lines within the byte limit, without losing words", () => {
  const text = Array.from({ length: 120 }, (_, i) => `word${i}`).join(" ");
  const lines = toLines(text);
  expect(lines.length).toBeGreaterThan(1);
  for (const line of lines)
    expect(new TextEncoder().encode(line).length).toBeLessThanOrEqual(MAX_LINE_BYTES);
  expect(lines.join(" ").replace(/…/g, "")).toContain("word0");
  expect(lines.at(-1)).toContain("word119");
});

test("wake shows missing summaries through their children, then uses them after compaction", async () => {
  const store = new ArrayMemoryStore();
  await store.append(Array.from({ length: 64 }, (_, i) => `fact ${i}`));
  const before = await wake(store, 8);
  expect(before.missing.length).toBeGreaterThan(0);
  expect(before.text.split("\n")).toHaveLength(64);

  const calls: number[] = [];
  const summarize = async ({
    left,
    right,
    level,
  }: {
    left: string;
    right: string;
    level: number;
  }) => {
    calls.push(level);
    return `${left.split(" ").pop()}..${right.split(" ").pop()}`;
  };
  // Compaction runs in bounded steps until wake has every summary it shows.
  let view = before;
  while (view.missing.length > 0) {
    expect(await compact(store, view.missing, summarize)).toBeGreaterThan(0);
    view = await wake(store, 8);
  }
  expect(Math.min(...calls)).toBe(1);

  const after = await wake(store, 8);
  expect(after.missing).toEqual([]);
  expect(after.text.split("\n").length).toBeLessThanOrEqual(8);
  expect(after.text).toMatch(/^#0-31 /);
  expect(after.text).toContain("#63 fact 63");
});

test("compaction stops at its per-call limit and resumes later", async () => {
  const store = new ArrayMemoryStore();
  await store.append(Array.from({ length: 32 }, (_, i) => `n${i}`));
  const target = [{ lo: 0, hi: 31 }];
  const summarize = async ({ left, right }: { left: string; right: string }) =>
    `${left}+${right}`.slice(0, 50);
  expect(await compact(store, target, summarize, 10)).toBe(10);
  let total = 10;
  while (!(await store.getNodes(target)).size) total += await compact(store, target, summarize, 10);
  expect(total).toBe(31);
});

test("recall finds lines newest first", async () => {
  const store = new ArrayMemoryStore();
  await store.append([
    "Lawrence prefers short replies",
    "build box is cmux14",
    "Lawrence moved to SF",
  ]);
  expect(await store.recall("lawrence", 5)).toEqual([
    { index: 2, line: "Lawrence moved to SF" },
    { index: 0, line: "Lawrence prefers short replies" },
  ]);
});
