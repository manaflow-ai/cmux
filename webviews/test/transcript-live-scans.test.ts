// l10n-allow-file: test fixtures, not shipped UI.
// Two scans the pane ran over the whole chat on every rows change, a streamed token too: the chat's
// one Retry (turns.ts retryTargetIn, VirtualTranscript) and Find's matches while it is open
// (chatFind.ts findMatchesIncremental). Both now read only the rows a snapshot changed, from the
// client's note of the rows it kept (prefixFlatMap.ts noteKeptPrefix, as direct/orderedRows.ts says it).
// Correctness: the old scans are the oracles over random append / replace-tail / edit-middle /
// drop-tail sequences, with the kept prefix said exactly, said short, or not said (a walk).
// Speed: old against new on one 100k-row chat in one process, and new at 1M rows (flat).
import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { retryScanOf, retryTargetIn, type RetryScan } from "../src/agent-session/acpmux/conversation/turns";
import {
  findMatchesByWalk,
  findMatchesIncremental,
  type FindMatchesCache,
} from "../src/agent-session/acpmux/conversation/chatFind";
import { noteKeptPrefix } from "../src/agent-session/acpmux/conversation/prefixFlatMap";
import { expectGrowth, expectSpeedup, forSeeds, type Gen } from "./support/dsaBench";

/// A fixture row: the fields the scans read.
const made = (row: Record<string, unknown>) => row as unknown as AcpmuxRow;

let ids = 0;
const WORDS = ["alpha", "beta", "gamma", "delta"];

function randomRow(g: Gen, prompts: readonly string[]): AcpmuxRow {
  const id = `r${(ids += 1)}`;
  const text = `${g.pick(WORDS)} ${g.pick(WORDS)} ${g.bool(0.3) ? g.pick(WORDS) : ""}`;
  const base = { id, version: 1, at: ids };
  const pick = g.int(0, 9);
  if (pick <= 2) {
    // A prompt: retryable, or one of the ways one is not.
    const flavor = g.int(0, 6);
    return {
      ...base,
      kind: "user",
      text: flavor === 6 ? "" : text,
      ...(flavor === 1 && { incoming: true }),
      ...(flavor === 2 && { pending: true }),
      ...(flavor === 3 && { failed: true }),
      ...(flavor === 4 && { delivery: { state: "sending" } }),
    } as AcpmuxRow;
  }
  if (pick <= 4) {
    const retryRowId = prompts.length && g.bool(0.7) ? g.pick(prompts) : "nobody";
    return {
      ...base,
      kind: "turnSummary",
      status: g.bool(0.15) ? "failed" : "completed",
      text: g.bool(0.6) ? text : "",
      ...(g.bool(0.8) && { retryTarget: true, prompt: "again", retryRowId }),
    } as AcpmuxRow;
  }
  return { ...base, kind: "assistant", text } as AcpmuxRow;
}

/// The next snapshot: a new array with its unchanged rows the same objects, and the kept prefix said
/// exactly, said short (allowed: "never more"), or not said at all.
function step(g: Gen, rows: readonly AcpmuxRow[]): AcpmuxRow[] {
  const prompts = rows.filter((row) => row.kind === "user").map((row) => row.id);
  const next = rows.slice();
  let firstChanged = next.length;
  const op = g.int(0, 9);
  if (op <= 3 || next.length === 0) {
    for (let k = g.int(1, 4); k > 0; k -= 1) next.push(randomRow(g, prompts));
  } else if (op <= 6) {
    // A streamed token or a tail row turned into another kind.
    const at = next.length - 1 - g.int(0, Math.min(2, next.length - 1));
    next[at] = g.bool(0.6)
      ? { ...next[at]!, version: next[at]!.version + 1, text: `${next[at]!.text} ${g.pick(WORDS)}` }
      : randomRow(g, prompts);
    firstChanged = at;
  } else if (op <= 8) {
    const at = g.int(0, next.length - 1);
    next[at] = randomRow(g, prompts);
    firstChanged = at;
  } else {
    const drop = g.int(1, Math.min(3, next.length));
    next.length -= drop;
    firstChanged = next.length;
  }
  const say = g.int(0, 2);
  if (say === 0) noteKeptPrefix(next, rows, firstChanged);
  else if (say === 1) noteKeptPrefix(next, rows, g.int(0, firstChanged));
  return next;
}

describe("the pane's per-update scans read only what changed", () => {
  test("retryScanOf matches retryTargetIn at every step of random edit sequences", () => {
    forSeeds(600, (g) => {
      let rows: AcpmuxRow[] = [];
      for (let k = g.int(0, 12); k > 0; k -= 1)
        rows.push(
          randomRow(
            g,
            rows.map((row) => row.id),
          ),
        );
      let scan: RetryScan | undefined;
      let fresh = g.bool(0.2);
      for (let s = 0; s < 40; s += 1) {
        scan = retryScanOf(rows, fresh ? undefined : scan);
        fresh = false;
        const want = retryTargetIn(rows);
        expect(scan.target).toEqual(want);
        rows = step(g, rows);
      }
    });
  });

  test("an unchanged retry target is the same object, so the pane's context keeps", () => {
    const prompt = { id: "p", version: 1, at: 1, kind: "user", text: "go" } as AcpmuxRow;
    const reply = { id: "a", version: 1, at: 2, kind: "assistant", text: "x" } as AcpmuxRow;
    const first = [prompt, reply];
    const scan = retryScanOf(first);
    const next = [prompt, { ...reply, text: "xy", version: 2 }];
    noteKeptPrefix(next, first, 1);
    expect(retryScanOf(next, scan).target).toBe(scan.target);
  });

  test("findMatchesIncremental matches the walking find at every step, cached or not", () => {
    forSeeds(600, (g) => {
      let rows: AcpmuxRow[] = [];
      for (let k = g.int(0, 12); k > 0; k -= 1) rows.push(randomRow(g, []));
      const query = g.pick(WORDS);
      let cache: FindMatchesCache | undefined;
      let oracle: FindMatchesCache | undefined;
      for (let s = 0; s < 40; s += 1) {
        const got = findMatchesIncremental(rows, query, cache);
        const want = findMatchesByWalk(rows, query, oracle);
        expect(got.matches).toEqual(want.matches);
        expect(got.matches).toEqual(findMatchesByWalk(rows, query).matches);
        cache = got.cache;
        oracle = want.cache;
        rows = step(g, rows);
      }
    });
  });

  // A chat of `n` rows as the direct path holds one that grew live: its prompts are another agent's
  // (nothing to retry), or one prompt opened a long turn of work. The update streams a token into
  // the last row, and the client notes the rows it kept.
  function liveChat(n: number, mode: "peer" | "longTurn") {
    const rows: AcpmuxRow[] = [];
    for (let i = 0; i < n; i += 1) {
      const base = { id: `r${i}`, version: 1, at: i, text: `lorem ipsum ${i}` };
      if (mode === "longTurn") rows.push(made({ ...base, kind: i === 0 ? "user" : "assistant" }));
      else if (i % 10 === 0) rows.push(made({ ...base, kind: "user", incoming: true }));
      else if (i % 10 === 9) rows.push(made({ ...base, kind: "turnSummary", status: "completed" }));
      else rows.push(made({ ...base, kind: "assistant" }));
    }
    // Snapshots made ahead, so the timing is the scan's, not the copy the client already paid.
    const snapshots: AcpmuxRow[][] = [rows];
    for (let k = 0; k < 12; k += 1) {
      const last = snapshots[snapshots.length - 1]!;
      const next = last.slice();
      const tail = next[n - 1]!;
      next[n - 1] = { ...tail, version: tail.version + 1, text: `${tail.text} ipsum` };
      noteKeptPrefix(next, last, n - 1);
      snapshots.push(next);
    }
    return snapshots;
  }

  function retryUpdates(snapshots: AcpmuxRow[][]) {
    const first = retryScanOf(snapshots[0]!);
    let at = 0;
    let oldAt = 0;
    let scan = first;
    // Each with its own place in the snapshots: the two run interleaved.
    const old = () => retryTargetIn(snapshots[(oldAt = (oldAt % (snapshots.length - 1)) + 1)]!);
    const next = () => {
      at = (at % (snapshots.length - 1)) + 1;
      // Each snapshot read against the one before it, as the pane reads them.
      scan = retryScanOf(snapshots[at]!, at === 1 ? first : scan);
      return scan;
    };
    return { old, next };
  }

  function findUpdates(snapshots: AcpmuxRow[][]) {
    let at = 0;
    let oldAt = 0;
    const first = findMatchesIncremental(snapshots[0]!, "ipsum 1").cache;
    let cache = first;
    let oracle = findMatchesByWalk(snapshots[0]!, "ipsum 1").cache;
    const firstOracle = oracle;
    // Each with its own place in the snapshots: the two run interleaved.
    const old = () => {
      oldAt = (oldAt % (snapshots.length - 1)) + 1;
      const result = findMatchesByWalk(snapshots[oldAt]!, "ipsum 1", oldAt === 1 ? firstOracle : oracle);
      oracle = result.cache;
      return result;
    };
    const next = () => {
      at = (at % (snapshots.length - 1)) + 1;
      const result = findMatchesIncremental(snapshots[at]!, "ipsum 1", at === 1 ? first : cache);
      cache = result.cache;
      return result;
    };
    return { old, next };
  }

  test("retry: a streamed token in a 100k-row chat costs its row, flat at 1M", () => {
    for (const mode of ["peer", "longTurn"] as const) {
      const { old, next } = retryUpdates(liveChat(100_000, mode));
      expectSpeedup(`retryTarget.token_${mode}_100k`, 100_000, old, next, { minSpeedup: 5, budgetMs: 2, runs: 15 });
    }
    expectGrowth(
      "retryTarget.token_peer",
      100_000,
      (n) => {
        const { next } = retryUpdates(liveChat(n, "peer"));
        return next;
      },
      { maxRatio: 3, floorMs: 0.02, runs: 31 },
    );
  }, 60_000);

  test("find: a streamed token in a 100k-row chat with Find open costs its row, flat at 1M", () => {
    const snapshots = liveChat(100_000, "peer");
    const { old, next } = findUpdates(snapshots);
    old();
    next();
    expectSpeedup("chatFind.token_100k", 100_000, old, next, { minSpeedup: 3, budgetMs: 5, runs: 15 });
    expectGrowth(
      "chatFind.token",
      100_000,
      (n) => {
        const snaps = liveChat(n, "peer");
        const first = findMatchesIncremental(snaps[0]!, "ipsum 1").cache;
        let cache = first;
        let at = 0;
        return () => {
          at = (at % (snaps.length - 1)) + 1;
          // A cycle restarts from the first snapshot's matches, so every timed call is an update.
          if (at === 1) cache = first;
          const result = findMatchesIncremental(snaps[at]!, "ipsum 1", cache);
          cache = result.cache;
          return result;
        };
      },
      { maxRatio: 3, floorMs: 0.05, runs: 31 },
    );
  }, 60_000);
});
