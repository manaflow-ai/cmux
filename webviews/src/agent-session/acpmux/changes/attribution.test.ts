// Who wrote a changed line (attribution.ts): the answer's parse, a line's writers, the ranges a
// diff asks for, and the store's cache and request limits.
import { expect, test } from "bun:test";
import type { TurnFile } from "../diff";
import {
  AttributionStore,
  MAX_ATTRIBUTION_RANGES,
  addedLines,
  addedRanges,
  attributionKey,
  lineRanges,
  parseAttributions,
  targetOf,
  writersOf,
  type AttributionParams,
} from "./attribution";

const target = { root: "/repo", head: "aaa", path: "src/upload.ts" };

const entry = (start: number, end: number, turnId: string, at: number, sessionId = "s1") => ({
  start,
  end,
  sessionId,
  turnId,
  at,
});

/// A store whose requests the test answers by hand.
function harness() {
  const asked: { params: AttributionParams; answer(value: unknown): void; fail(): void }[] = [];
  const store = new AttributionStore(
    (params) =>
      new Promise((resolve, reject) => asked.push({ params, answer: resolve, fail: () => reject(new Error()) })),
  );
  return { store, asked };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("the answer parses defensively: a bad entry is dropped, optional fields kept", () => {
  expect(parseAttributions(undefined)).toEqual([]);
  expect(parseAttributions({ attributions: "no" })).toEqual([]);
  expect(
    parseAttributions({
      attributions: [
        { ...entry(3, 4, "t1", 10), model: "opus", title: "Chat", prompt: "Fix it", extra: 1 },
        entry(5, 4, "t2", 10),
        { ...entry(1, 1, "t3", 10), sessionId: "" },
        { ...entry(1, 1, "t4", 10), at: "now" },
        { ...entry(0, 1, "t5", 10) },
        null,
      ],
    }),
  ).toEqual([{ ...entry(3, 4, "t1", 10), model: "opus", title: "Chat", prompt: "Fix it" }]);
});

test("a line's writers: newest first, one per turn, nothing for a line no turn wrote", () => {
  const all = parseAttributions({
    attributions: [entry(1, 10, "old", 100), entry(5, 6, "new", 200), entry(5, 5, "old", 100)],
  });
  expect(writersOf(all, 5).map((each) => each.turnId)).toEqual(["new", "old"]);
  expect(writersOf(all, 2).map((each) => each.turnId)).toEqual(["old"]);
  expect(writersOf(all, 11)).toEqual([]);
});

test("the asked ranges are a numbered edit's added lines, merged and capped", () => {
  const file: TurnFile = {
    path: "src/upload.ts",
    displayPath: "src/upload.ts",
    additions: 4,
    deletions: 1,
    created: false,
    edits: [
      {
        toolId: "a",
        numbered: true,
        hunks: [
          {
            lines: [
              { type: "context", text: "a", oldLine: 1, newLine: 1 },
              { type: "del", text: "b", oldLine: 2 },
              { type: "add", text: "c", newLine: 2 },
              { type: "add", text: "d", newLine: 3 },
              { type: "context", text: "e", oldLine: 3, newLine: 4 },
              { type: "add", text: "f", newLine: 5 },
            ],
          },
        ],
      },
      { toolId: "b", numbered: false, hunks: [{ lines: [{ type: "add", text: "g", newLine: 1 }] }] },
    ],
  };
  expect(addedLines(file)).toEqual([2, 3, 5]);
  expect(addedRanges(file)).toEqual([
    [2, 3],
    [5, 5],
  ]);
  const scattered = Array.from({ length: 100 }, (_, index) => index * 2 + 1);
  const ranges = lineRanges(scattered);
  expect(ranges).toHaveLength(MAX_ATTRIBUTION_RANGES);
  expect(ranges[0]).toEqual([1, 1]);
  expect(ranges.at(-1)).toEqual([127, 127]);
});

test("a file is asked for only inside the repository, by its path from the top level", () => {
  expect(targetOf("/repo/src/upload.ts", { root: "/repo/", head: "aaa" })).toEqual(target);
  expect(targetOf("/other/src/upload.ts", { root: "/repo", head: "aaa" })).toBeUndefined();
  expect(targetOf("/repository/x.ts", { root: "/repo", head: "aaa" })).toBeUndefined();
  expect(targetOf("/repo/a/../b.ts", { root: "/repo", head: "aaa" })).toBeUndefined();
  expect(targetOf(undefined, { root: "/repo", head: "aaa" })).toBeUndefined();
  expect(targetOf("/repo/x.ts", undefined)).toBeUndefined();
});

test("the store answers a line two turns wrote, and never asks for an asked line again", async () => {
  const { store, asked } = harness();
  expect(store.want(target, [5, 6, 7])).toBe(true);
  expect(asked).toHaveLength(1);
  expect(asked[0]!.params).toEqual({ ...target, ranges: [[5, 7]] });
  asked[0]!.answer({ attributions: [entry(5, 6, "old", 100), entry(6, 7, "new", 200)] });
  await settle();
  expect(store.writersOf(target, 6).map((each) => each.turnId)).toEqual(["new", "old"]);
  expect(store.writersOf(target, 9)).toEqual([]);
  expect(store.want(target, [5, 6, 7])).toBe(true);
  store.want(target, [6, 7, 8]);
  expect(asked).toHaveLength(2);
  expect(asked[1]!.params.ranges).toEqual([[8, 8]]);
});

test("another head is another file: asked again, never answered from the old head", async () => {
  const { store, asked } = harness();
  store.want(target, [5]);
  asked[0]!.answer({ attributions: [entry(5, 5, "t1", 100)] });
  await settle();
  const moved = { ...target, head: "bbb" };
  expect(attributionKey(moved)).not.toBe(attributionKey(target));
  expect(store.writersOf(moved, 5)).toEqual([]);
  store.want(moved, [5]);
  expect(asked).toHaveLength(2);
  expect(asked[1]!.params.head).toBe("bbb");
});

test("at most two requests are out, and a newer want replaces the queued one", async () => {
  const { store, asked } = harness();
  const file = (path: string) => ({ ...target, path });
  store.want(file("a"), [1]);
  store.want(file("b"), [1]);
  expect(store.want(file("c"), [1])).toBe(false);
  store.want(file("d"), [1]);
  expect(asked.map((each) => each.params.path)).toEqual(["a", "b"]);
  asked[0]!.fail();
  await settle();
  expect(asked.map((each) => each.params.path)).toEqual(["a", "b", "d"]);
  // A refused request shows nothing and leaves its lines asked.
  expect(store.writersOf(file("a"), 1)).toEqual([]);
  store.want(file("a"), [1]);
  expect(asked).toHaveLength(3);
});

test("the store keeps a bounded number of files, the oldest out first", async () => {
  const asked: AttributionParams[] = [];
  const store = new AttributionStore(
    (params) => {
      asked.push(params);
      return Promise.resolve({ attributions: [entry(1, 1, `t-${params.path}`, 1)] });
    },
    2,
    8,
  );
  store.want({ ...target, path: "a" }, [1]);
  store.want({ ...target, path: "b" }, [1]);
  store.want({ ...target, path: "c" }, [1]);
  await settle();
  expect(store.writersOf({ ...target, path: "a" }, 1)).toEqual([]);
  expect(store.writersOf({ ...target, path: "c" }, 1).map((each) => each.turnId)).toEqual(["t-c"]);
  store.want({ ...target, path: "a" }, [1]);
  expect(asked.map((each) => each.path)).toEqual(["a", "b", "c", "a"]);
});

test("forget drops the answers and discards one still out", async () => {
  const { store, asked } = harness();
  let heard = 0;
  store.subscribe(() => heard++);
  // Nothing kept: a replayed chat's many turn ends tell no reader.
  store.forget();
  expect(heard).toBe(0);
  store.want(target, [1]);
  store.forget();
  expect(heard).toBe(1);
  asked[0]!.answer({ attributions: [entry(1, 1, "t1", 1)] });
  await settle();
  expect(store.writersOf(target, 1)).toEqual([]);
  store.want(target, [1]);
  expect(asked).toHaveLength(2);
  asked[1]!.answer({ attributions: [entry(1, 1, "t1", 1)] });
  await settle();
  expect(heard).toBe(2);
  store.forget();
  expect(heard).toBe(3);
  expect(store.writersOf(target, 1)).toEqual([]);
});

test("a want over the range cap asks the rest on the next want", () => {
  const { store, asked } = harness();
  const scattered = Array.from({ length: 70 }, (_, index) => index * 2 + 1);
  expect(store.want(target, scattered)).toBe(false);
  expect(asked[0]!.params.ranges).toHaveLength(MAX_ATTRIBUTION_RANGES);
  expect(store.want(target, scattered)).toBe(true);
  expect(asked[1]!.params.ranges).toHaveLength(6);
});

test("an answer counts only for the text it was asked with: an older diff's lines are asked again", async () => {
  const { store, asked } = harness();
  const newer = new Map([[5, "bar"]]);
  store.want(target, [5], newer);
  expect(asked[0]!.params.texts).toEqual([["bar"]]);
  asked[0]!.answer({ attributions: [entry(5, 5, "b", 200)] });
  await settle();
  expect(store.writersOf(target, 5, "bar").map((each) => each.turnId)).toEqual(["b"]);
  // An older turn's diff shows `foo` on that line: never the rewriter's answer.
  const older = new Map([[5, "foo"]]);
  expect(store.writersOf(target, 5, "foo")).toEqual([]);
  store.want(target, [5], older);
  expect(asked).toHaveLength(2);
  expect(asked[1]!.params.texts).toEqual([["foo"]]);
  asked[1]!.answer({ attributions: [] });
  await settle();
  expect(store.writersOf(target, 5, "foo")).toEqual([]);
});

test("a file's answers past the bound keep the newest", async () => {
  const { store, asked } = harness();
  store.want(target, [1]);
  const many = Array.from({ length: 600 }, (_, index) => entry(1, 1, `t${index}`, 1000 - index));
  asked[0]!.answer({ attributions: many });
  await settle();
  expect(store.writersOf(target, 1)[0]!.turnId).toBe("t0");
});
