// The per-snapshot passes a streamed delta runs read only the rows it changed, and give what a pass
// over every row gives (bench/transcript-replay.bench.ts long log: each token and each tool output
// update cost more as the transcript grew, 1.9x and 2.9x from 50 to 5,000 rows).
import { expect, test } from "bun:test";
import { LayeredMap } from "../src/agent-session/acpmux/conversation/layeredMap";
import { keptPrefix, PrefixFlatCache, prefixFlatMap } from "../src/agent-session/acpmux/conversation/prefixFlatMap";
import { rowPresence, type RowPresenceHints } from "../src/agent-session/acpmux/conversation/rowPresence";
import { withoutQuietThoughts } from "../src/agent-session/acpmux/conversation/thoughts";
import {
  transcriptRepositories,
  transcriptRepositoriesFrom,
  type RepositoryCache,
  type RepositoryReading,
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
  const drawn = (reading: RepositoryReading, count: number) => Array.from({ length: count }, (_, i) => reading.at(i));
  let reading = transcriptRepositoriesFrom(rows, "h/r", cache);
  expect(drawn(reading, rows.length)).toEqual(transcriptRepositories(rows, "h/r"));
  for (const text of ["x", "x see a/b#3", "x see a/b#3 done"]) {
    const next = [...rows, row("a2", { text })];
    reading = transcriptRepositoriesFrom(next, "h/r", cache, reading);
    expect(drawn(reading, next.length)).toEqual(transcriptRepositories(next, "h/r"));
  }
  expect(drawn(transcriptRepositoriesFrom(rows, undefined, cache, reading), rows.length)).toEqual(
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

// The pane's passes over a whole snapshot (App.tsx: the composer's rows, the tray's done lines, the
// hat's todo list, Find's waiting messages, Session Info's subagents, the asks, the failed runs):
// a thought token or a tool call is a new snapshot, and at 35,000 rows (bench/godFixture.ts) each
// pass that read every row made one update cost 2-3x what it costs in a small chat. Each must read
// only the rows the update changed, and answer what a pass over every row (fresh objects, so
// nothing is kept) answers.
function mixedHistory(count: number): AcpmuxRow[] {
  const agent = (index: number) => ({
    id: `agent-${index}`,
    parent: null,
    name: `Explore ${index}`,
    state: "completed",
    startedAt: index * 10,
    endedAt: index * 10 + 5,
  });
  return Array.from({ length: count }, (_, index): AcpmuxRow => {
    const at = index * 10;
    switch (index % 12) {
      case 0:
        return row(`u${index}`, { kind: "user", at, text: `prompt ${index}` });
      case 1:
        return row(`p${index}`, {
          kind: "plan",
          at,
          turnEnded: true,
          plan: [{ content: "step", status: index % 24 === 1 ? "pending" : "completed" }],
        } as Partial<AcpmuxRow>);
      case 2:
        return row(`g${index}`, {
          kind: "subagents",
          at,
          text: undefined,
          subagents: [agent(index)],
        } as Partial<AcpmuxRow>);
      case 3:
        return row(`b${index}`, {
          kind: "backgroundTurn",
          at,
          text: undefined,
          background: { id: `bg${index}`, cause: { kind: "subagent", origin: `agent-${index - 1}` } },
        } as Partial<AcpmuxRow>);
      case 4:
        return row(`f${index}`, { kind: "user", at, failed: true, text: `failed ${index}` });
      case 5:
        return row(`d${index}`, { kind: "date", at, text: undefined });
      case 6:
        return row(`f${index}`, { kind: "user", at, failed: true, text: `failed ${index}` });
      case 7:
        return row(`q${index}`, {
          kind: "permission",
          at,
          text: undefined,
          permission: { pending: index % 24 === 7, toolCallId: `call-${index}` },
        } as Partial<AcpmuxRow>);
      case 8:
        return row(`pair${index}`, {
          kind: "agentPair",
          at,
          text: undefined,
          agentPair: { peer: `peer-${index % 5}`, held: index % 36 === 8 ? ["m"] : [], resumed: false },
        } as unknown as Partial<AcpmuxRow>);
      case 9:
        return row(`s${index}`, { kind: "turnSummary", at, text: undefined, status: "completed" });
      default:
        return row(`a${index}`, { at, text: `reply ${index}` });
    }
  });
}

/// `pass` over a counted history and a tail that streams: no history row's field is read after the
/// first pass (but `allowed`, the chat's first rows), and each answer is a fresh whole pass's.
function readsOnlyTheTail<T>(
  name: string,
  pass: (rows: readonly AcpmuxRow[]) => T,
  allowed = 0,
  view: (answer: T) => unknown = (answer) => answer,
) {
  const plain = mixedHistory(4000);
  const history = countedRows(plain.length, (index) => plain[index]!);
  const tails = [
    [row("live", { text: "x" })],
    [row("live", { text: "x y" })],
    [row("live", { text: "x y" }), row("call", { kind: "activity", text: undefined, items: [] } as Partial<AcpmuxRow>)],
    [
      row("u-new", { kind: "user", text: "next" }),
      row("p-new", { kind: "plan", plan: [{ content: "a", status: "pending" }] } as Partial<AcpmuxRow>),
    ],
  ];
  pass([...history.rows, ...tails[0]!]);
  history.reads.count = 0;
  for (const tail of tails.slice(1)) {
    const answer = pass([...history.rows, ...tail]);
    // What the answer reads to compare it is the test's, not the pass's.
    const counted = history.reads.count;
    const got = view(answer);
    const whole = view(pass([...plain.map((each) => ({ ...each })), ...tail.map((each) => ({ ...each }))]));
    history.reads.count = counted;
    expect(Bun.deepEquals(got, whole), `${name}: the answer a whole pass gives`).toBe(true);
  }
  expect(history.reads.count, `${name}: history row fields read over three updates`).toBeLessThanOrEqual(allowed);
}

test("the pane's per-snapshot passes read only the rows an update changed", async () => {
  const { composerRows } = await import("../src/agent-session/acpmux/composer/composerView");
  const { subagentsIn, withSubagentRows } = await import("../src/agent-session/acpmux/subagents/subagentRows");
  const { withSubagentLines } = await import("../src/agent-session/acpmux/subagents/runningTray");
  const { pendingToolCalls } = await import("../src/agent-session/acpmux/summary/subagentStatusListModel");
  const { heldPairs } = await import("../src/agent-session/acpmux/needsYou/model");
  const { failedRuns } = await import("../src/agent-session/acpmux/sendFailure");
  const { liveTurnPlan, earlierTurnPlan } = await import("../src/agent-session/acpmux/conversation/turns");
  const { flattenInboxRows } = await import("../src/agent-session/acpmux/conversation/laneNoticeBatches");
  const { searchablePendingRows } = await import("../src/agent-session/acpmux/conversation/pendingMessages");
  const { firstReplyCompleted } = await import("../src/agent-session/acpmux/share/shareNudgeModel");
  const ids = (rows: readonly AcpmuxRow[]) => rows.map((each) => each.id);
  // The chat's start (its first row after the session start) is read once per update.
  readsOnlyTheTail("composerRows", composerRows, 3, ids);
  readsOnlyTheTail(
    "subagentsIn",
    (rows) => subagentsIn(rows),
    0,
    (agents) => [...agents.keys()],
  );
  readsOnlyTheTail("withSubagentRows", (rows) => withSubagentRows(rows, new Set()), 0, ids);
  readsOnlyTheTail(
    "pendingToolCalls",
    (rows) => pendingToolCalls({ rows: rows as AcpmuxRow[] }),
    0,
    (calls) => [...calls],
  );
  readsOnlyTheTail("heldPairs", heldPairs, 0, (pairs) => pairs.map((pair) => pair.peer));
  readsOnlyTheTail(
    "failedRuns",
    (rows) => failedRuns(rows),
    0,
    (runs) => [...runs].map(([id, run]) => [id, run.rowIds]),
  );
  readsOnlyTheTail("liveTurnPlan", liveTurnPlan, 0, (plan) => plan?.id);
  readsOnlyTheTail("earlierTurnPlan", earlierTurnPlan, 0, (plan) => plan?.id);
  readsOnlyTheTail("flattenInboxRows", flattenInboxRows, 0, ids);
  readsOnlyTheTail("searchablePendingRows", (rows) => searchablePendingRows(rows, []), 0, ids);
  // Up to the second ended turn, the history's first 22 rows, whatever the chat's length.
  readsOnlyTheTail("firstReplyCompleted", firstReplyCompleted, 3 * 22);
  // The groups and reports are found from the tail alone; each ended subagent's line is still
  // placed again per update (its group, its agent and the rows right after it: about a dozen
  // fields per group, 333 groups here), never the rows between groups. Grows with groups, not rows.
  const lines = new Map();
  readsOnlyTheTail(
    "withSubagentLines",
    (rows) => withSubagentLines(rows, lines),
    333 * 3 * 13,
    (rows) => rows.map((each) => [each.id, each.kind]),
  );
});

test("the prefix passes hold no rows of a chat that closed", async () => {
  // The passes are module state shared by every chat; holding a closed 35,000-row chat's arrays
  // there kept it in memory until newer passes pushed it out (review of #40592).
  const { composerRows } = await import("../src/agent-session/acpmux/composer/composerView");
  const { subagentsIn } = await import("../src/agent-session/acpmux/subagents/subagentRows");
  const cache = new PrefixFlatCache<AcpmuxRow, string>((each) => [each.id]);
  const open = (): WeakRef<readonly AcpmuxRow[]>[] => {
    const first = mixedHistory(2000);
    const next = [...first, row("live", { text: "x" })];
    for (const rows of [first, next]) {
      cache.read(rows);
      composerRows(rows);
      subagentsIn(rows);
      keptPrefix(first, rows);
    }
    // The passes reused the first snapshot's work for the next one.
    expect(cache.read(next).items.length).toBe(next.length);
    return [new WeakRef(first), new WeakRef(next)];
  };
  const closed = [...open(), ...open()];
  for (let pass = 0; pass < 4; pass += 1) {
    // A turn of the event loop between collections: a WeakRef holds its target until the job ends.
    await new Promise((resolve) => setImmediate(resolve));
    Bun.gc(true);
  }
  expect(closed.filter((ref) => ref.deref() !== undefined).length).toBe(0);
});
