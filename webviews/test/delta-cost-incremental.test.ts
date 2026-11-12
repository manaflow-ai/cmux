// The per-snapshot passes a streamed delta runs read only the rows it changed, and give what a pass
// over every row gives (bench/transcript-replay.bench.ts long log: each token and each tool output
// update cost more as the transcript grew, 1.9x and 2.9x from 50 to 5,000 rows).
import { expect, test } from "bun:test";
import { LayeredMap } from "../src/agent-session/acpmux/conversation/layeredMap";
import { PrefixFlatCache, prefixFlatMap } from "../src/agent-session/acpmux/conversation/prefixFlatMap";
import { rowPresence, type RowPresenceHints } from "../src/agent-session/acpmux/conversation/rowPresence";
import { withoutQuietThoughts } from "../src/agent-session/acpmux/conversation/thoughts";
import {
  transcriptRepositories,
  transcriptRepositoriesFrom,
  type RepositoryCache,
} from "../src/agent-session/acpmux/conversation/transcriptRepositories";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { transcriptBackground } from "../src/agent-session/acpmux/summary/sessionSummary";

const row = (id: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, version: 1, at: 0, kind: "assistant", text: id, ...extra }) as AcpmuxRow;

test("prefixFlatMap reads only the rows after the last kept one", () => {
  const rows = Array.from({ length: 1000 }, (_, index) => row(`r${index}`));
  const read: string[] = [];
  const each = (each: AcpmuxRow) => {
    read.push(each.id);
    return [each.id, `${each.id}!`];
  };
  const first = prefixFlatMap(rows, each);
  expect(read.length).toBe(1000);
  read.length = 0;
  expect(prefixFlatMap(rows.slice(), each, first)).toBe(first);
  expect(read).toEqual([]);
  // The last row changed and one came after it: two rows read, the items as a whole pass gives.
  const next = [...rows.slice(0, -1), row("r999", { text: "new" }), row("r1000")];
  const grown = prefixFlatMap(next, each, first);
  expect(read).toEqual(["r999", "r1000"]);
  expect(grown.items).toEqual(next.flatMap((each) => [each.id, `${each.id}!`]));
  expect(first.items.length).toBe(2000);
});

test("PrefixFlatCache starts each caller's rows from the pass that kept the most of them", () => {
  const rows = Array.from({ length: 100 }, (_, index) => row(`r${index}`));
  let reads = 0;
  const cache = new PrefixFlatCache<AcpmuxRow, string>((each) => {
    reads += 1;
    return [each.id];
  });
  cache.read(rows);
  const other = rows.slice(0, 40);
  cache.read(other);
  reads = 0;
  // Alternating callers keep their own passes.
  cache.read([...rows, row("r100")]);
  cache.read([...other, row("x")]);
  expect(reads).toBe(2);
});

test("LayeredMap keeps every value, deletes, and leaves older values as they were", () => {
  let map = LayeredMap.empty<number>();
  const versions: LayeredMap<number>[] = [];
  for (let index = 0; index < 500; index += 1) {
    map = map.with(new Map([[`k${index % 50}`, index]]));
    versions.push(map);
  }
  expect(map.size).toBe(50);
  for (let key = 0; key < 50; key += 1) expect(map.get(`k${key}`)).toBe(450 + key);
  // An older value still answers as it did.
  expect(versions[10]!.get("k10")).toBe(10);
  expect(versions[10]!.get("k11")).toBeUndefined();
  expect(versions[10]!.size).toBe(11);
  const less = map.with(new Map([["k3", undefined]]));
  expect(less.size).toBe(49);
  expect(less.has("k3")).toBe(false);
  expect(map.has("k3")).toBe(true);
  expect([...less.keys()].sort()).toEqual(
    Array.from({ length: 50 }, (_, key) => `k${key}`)
      .filter((key) => key !== "k3")
      .sort(),
  );
  expect(less.retain((key) => key === "k1").size).toBe(1);
  expect(map.with(new Map([["k1", map.get("k1")]]))).toBe(map);
});

test("transcriptRepositoriesFrom gives what a whole pass gives, as the rows stream", () => {
  const rows: AcpmuxRow[] = [
    row("u1", { kind: "user", text: "look at manaflow-ai/cmux#1" }),
    row("a1", { text: "sure" }),
    row("u2", { kind: "user", text: "and o/r#2" }),
  ];
  const cache: RepositoryCache = new Map();
  let reading = transcriptRepositoriesFrom(rows, "h/r", cache);
  expect(reading.repositories).toEqual(transcriptRepositories(rows, "h/r"));
  for (const text of ["x", "x see a/b#3", "x see a/b#3 done"]) {
    const next = [...rows, row("a2", { text })];
    reading = transcriptRepositoriesFrom(next, "h/r", cache, reading);
    expect(reading.repositories).toEqual(transcriptRepositories(next, "h/r"));
  }
  expect(transcriptRepositoriesFrom(rows, undefined, cache, reading).repositories).toEqual(
    transcriptRepositories(rows),
  );
});

test("withoutQuietThoughts gives the same rows read whole or after the last kept one", () => {
  const thought = (text: string) => ({ kind: "thought", text });
  const step = (id: string, ...items: { kind: string; text: string }[]) =>
    row(id, { kind: "activity", text: undefined, items } as Partial<AcpmuxRow>);
  const base = [row("u", { kind: "user" }), step("s1", thought("Thinking"), thought("**Plan**\nreal")), row("a")];
  const fresh = (rows: AcpmuxRow[], live: boolean) =>
    // A new object for every row: nothing is kept from an earlier pass.
    withoutQuietThoughts(
      rows.map((each) => ({ ...each })),
      live,
    );
  for (const live of [false, true]) {
    let rows = base;
    for (const text of ["", "one", "one two"]) {
      rows = [...rows.slice(0, 3), step("s2", thought(`**Now**\n${text}`))];
      expect(withoutQuietThoughts(rows, live).map((each) => [each.id, each.items])).toEqual(
        fresh(rows, live).map((each) => [each.id, each.items]),
      );
    }
  }
  // Nothing to shape: the rows themselves.
  const plain = [row("x"), row("y")];
  expect(withoutQuietThoughts(plain)).toBe(plain);
});

test("transcriptBackground reads a running call's update and answers as before", () => {
  const shell = (id: string, extra: Record<string, unknown> = {}) => ({
    kind: "tool",
    text: "",
    tool: { id, title: "Run bun test", kind: "execute", status: "in_progress", inputSummary: "{}", ...extra },
  });
  const background = (id: string) =>
    shell(id, { inputSummary: JSON.stringify({ run_in_background: true, command: "bun dev" }) });
  const history = Array.from({ length: 200 }, (_, index) =>
    row(`s${index}`, { kind: "activity", text: undefined, items: [shell(`t${index}`)] } as Partial<AcpmuxRow>),
  );
  const step = (output: string) =>
    row("live", {
      kind: "activity",
      text: undefined,
      items: [background("bg"), shell("run", { output })],
    } as Partial<AcpmuxRow>);
  const first = transcriptBackground([...history, step("a")]);
  expect(first.tasks.map((task) => [task.id, task.state])).toEqual([["bg", "running"]]);
  const rows = [...history, step("a")];
  expect(transcriptBackground(rows.slice())).toBe(transcriptBackground(rows));
  const next = transcriptBackground([...history, step("a b")]);
  expect(next).toEqual(first);
});

test("rowPresence finds an id at its last index without walking the rows", () => {
  const rows = Array.from({ length: 5000 }, (_, index) => ({ id: `r${index}` }));
  const hints: RowPresenceHints = {};
  expect(rowPresence(rows, "r3", undefined, undefined, hints).active).toBe(true);
  expect(hints.active).toBe(3);
  // Gone from its index (rows prepended): found by the walk, and the hint moves.
  const moved = [{ id: "new" }, ...rows];
  expect(rowPresence(moved, "r3", undefined, undefined, hints).active).toBe(true);
  expect(hints.active).toBe(4);
  expect(rowPresence(moved, "missing", "r1", undefined, hints)).toEqual({ active: false, anchor: true, focus: true });
});

/// Rows that count every read of their fields: a pass that reads only the rows a delta changed
/// touches none of the history's.
function countedRows(count: number, make: (index: number) => AcpmuxRow) {
  const reads = { count: 0 };
  const rows = Array.from({ length: count }, (_, index) => {
    const source = make(index) as unknown as Record<string, unknown>;
    const counted: Record<string, unknown> = {};
    for (const key of Object.keys(source))
      Object.defineProperty(counted, key, {
        enumerable: true,
        get: () => {
          reads.count += 1;
          return source[key];
        },
      });
    return counted as unknown as AcpmuxRow;
  });
  return { rows, reads };
}

test("transcriptRepositoriesFrom reads none of the rows before a streamed token", () => {
  const history = countedRows(5000, (index) => row(`a${index}`, { text: `reply ${index}` }));
  const cache: RepositoryCache = new Map();
  let reading = transcriptRepositoriesFrom([...history.rows, row("reply", { text: "x" })], undefined, cache);
  history.reads.count = 0;
  for (const text of ["x y", "x y z"])
    reading = transcriptRepositoriesFrom([...history.rows, row("reply", { text })], undefined, cache, reading);
  expect(history.reads.count, "transcriptRepositoriesFrom: history row fields read over two tokens").toBe(0);
});
