// l10n-allow-file: test output, not shipped UI.
// RFD 0199 section 11: diff find scans each line once while a PR streams in, and an extending keystroke checks only
// the previous query's matching lines, not the whole diff. The old full pass (`collectFindMatches`) is the oracle.
// Op counts (`diffFindWork.lines`) carry the bounds, so a loaded runner cannot flake them; the timings print the
// before -> after and only fail on a gross regression.
import { describe, expect, test } from "bun:test";
import { parsePatchFiles } from "@pierre/diffs";
import type { DiffItem } from "../src/diff-stream";
import { collectFindMatches, diffFindWork, FIND_MATCH_CAP, IncrementalDiffFind } from "../src/find/model";
import { collapsedFileSet } from "../src/diff-viewer/state";
import { makeMixedPatch } from "../bench/diff-fixture";
import { expectGrowth, expectSpeedup, forSeeds, type Gen } from "./support/dsaBench";

function itemsOf(patch: string): DiffItem[] {
  const files = parsePatchFiles(patch).flatMap((parsed: { files: unknown[] }) => parsed.files);
  return files.map((fileDiff, i) => ({ id: `f${i}`, fileDiff }) as unknown as DiffItem);
}

function bigFilePatch(lines: number): string {
  let s = `diff --git a/big.ts b/big.ts\nindex 1111111..2222222 100644\n--- a/big.ts\n+++ b/big.ts\n@@ -1,${lines} +1,${lines} @@\n`;
  for (let i = 0; i < lines; i++) {
    s +=
      i % 3 === 0
        ? `-const value_${i} = compute(${i}); // old\n+const value_${i} = computeNext(${i}); // new\n`
        : ` const ctx_${i} = render(${i});\n`;
  }
  return s;
}

const WORDS = ["alpha", "Beta", "gamma", "İndex", "needle", "NEEDLE", "x", "xx", "compute", "computeNext", "état", ""];

function randomPatch(g: Gen, files: number): string {
  let s = "";
  for (let f = 0; f < files; f++) {
    const path = `src/f${f}.ts`;
    const body: string[] = [];
    let adds = 0;
    let dels = 0;
    const n = g.int(1, 12);
    for (let i = 0; i < n; i++) {
      const text = Array.from({ length: g.int(0, 4) }, () => g.pick(WORDS)).join(g.pick([" ", "", "_"]));
      const kind = g.pick([" ", "+", "-"]);
      if (kind !== "+") dels++;
      if (kind !== "-") adds++;
      body.push(`${kind}${text}`);
    }
    s += `diff --git a/${path} b/${path}\nindex 1111111..2222222 100644\n--- a/${path}\n+++ b/${path}\n@@ -1,${dels} +1,${adds} @@\n${body.join("\n")}\n`;
  }
  return s;
}

const QUERIES = [
  "n",
  "ne",
  "nee",
  "needle",
  "e",
  "x",
  "xx",
  "xxx",
  "i",
  "in",
  "ind",
  "compute",
  "computen",
  "zz",
  "a",
  "al",
  "État",
  "_",
];

/** Lines a full pass looks at: what `collectFindMatches` visits for a query that never matches. */
function lineCount(items: DiffItem[]): number {
  const finder = new IncrementalDiffFind();
  const before = diffFindWork.lines;
  finder.update(items, "\u0000never\u0000");
  return diffFindWork.lines - before;
}

describe("IncrementalDiffFind equals collectFindMatches (oracle)", () => {
  test("random diffs, random batch splits, extending and fresh queries", () => {
    forSeeds(200, (g) => {
      const all = itemsOf(randomPatch(g, g.int(1, 30)));
      const finder = new IncrementalDiffFind();
      let shown = 0;
      let query = g.pick(QUERIES);
      for (let step = 0; step < 24; step++) {
        const r = g.next();
        if (r < 0.35 && shown < all.length) {
          shown = Math.min(all.length, shown + g.int(1, 6));
        } else if (r < 0.65) {
          query += g.pick(["e", "d", "l", "x", "n", "E", "İ", " "]);
        } else if (r < 0.8) {
          query = query.slice(0, Math.max(0, query.length - g.int(1, 3)));
        } else if (r < 0.9) {
          query = g.pick(QUERIES);
        } else if (shown > 0) {
          // A changed earlier item (a deferred file loading, a filter) must not reuse the old scan.
          shown = g.int(0, shown);
        }
        const items = all.slice(0, shown);
        expect(finder.update(items, query)).toEqual(collectFindMatches(items, query));
      }
    });
  });

  test("the match cap holds while narrowing past it and streaming on", () => {
    const all = itemsOf(bigFilePatch(30_000));
    const finder = new IncrementalDiffFind();
    for (const query of ["c", "co", "compute", "computen", "computenext", "computenext(1", "computenext(12"]) {
      const got = finder.update(all, query);
      expect(got).toEqual(collectFindMatches(all, query));
    }
    expect(finder.update(all, "c").length).toBe(FIND_MATCH_CAP);
  });
});

describe("find work is bounded (op counts)", () => {
  test("find work per streamed batch is O(new lines): 10k files in 512-file batches", () => {
    const all = itemsOf(makeMixedPatch(10_000));
    const lines = lineCount(all);
    const finder = new IncrementalDiffFind();
    const before = diffFindWork.lines;
    for (let n = 512; n < all.length + 512; n += 512) {
      finder.update(all.slice(0, Math.min(n, all.length)), "zzqqxx");
    }
    const work = diffFindWork.lines - before;
    console.log(`dsa-bench name=diffFind.stream_ops files=${all.length} lines=${lines} lines_checked=${work}`);
    expect(work).toBeLessThanOrEqual(Math.ceil(1.1 * lines));
  });

  test("extending keystrokes scan only the previous matches: key 11 of computenext at 100k lines", () => {
    const all = itemsOf(bigFilePatch(100_000));
    const finder = new IncrementalDiffFind();
    const q = "computenext";
    let previousMatches = Infinity;
    for (let k = 1; k <= q.length; k++) {
      const before = diffFindWork.lines;
      const matches = finder.update(all, q.slice(0, k));
      const work = diffFindWork.lines - before;
      // Key 11 only narrows (every "computenex" line has "computenext"). An earlier key that drops matches under
      // the cap resumes the scan to refill it, so its work is the previous matches plus the lines to fill the cap:
      // a constant, never the 200k lines.
      if (k === q.length) expect(work).toBeLessThanOrEqual(previousMatches);
      if (k >= 2) expect(work).toBeLessThanOrEqual(3 * FIND_MATCH_CAP);
      previousMatches = matches.length;
      if (k === q.length) {
        console.log(`dsa-bench name=diffFind.key11_ops lines=200000 lines_checked=${work} matches=${matches.length}`);
      }
    }
  });
});

describe("diff find timing (fail-open budgets)", () => {
  test("per keystroke at a 100k-line file: typing computenext", () => {
    const all = itemsOf(bigFilePatch(100_000));
    const q = "computenext";
    const typeOld = () => {
      let n = 0;
      for (let k = 1; k <= q.length; k++) n += collectFindMatches(all, q.slice(0, k)).length;
      return n;
    };
    const typeNew = () => {
      const finder = new IncrementalDiffFind();
      let n = 0;
      for (let k = 1; k <= q.length; k++) n += finder.update(all, q.slice(0, k)).length;
      return n;
    };
    expectSpeedup("diffFind.type_computenext_100k_lines", 100_000, typeOld, typeNew, {
      minSpeedup: 3,
      budgetMs: 200,
    });
  });

  test("per keystroke is flat from 10k to 100k lines once the file's lines are folded", () => {
    const byLines = new Map<number, DiffItem[]>();
    const q = "computenext";
    expectGrowth(
      "diffFind.type_computenext_per_key",
      10_000,
      (n) => {
        if (!byLines.has(n)) byLines.set(n, itemsOf(bigFilePatch(n)));
        const all = byLines.get(n)!;
        return () => {
          const finder = new IncrementalDiffFind();
          let m = 0;
          for (let k = 1; k <= q.length; k++) m += finder.update(all, q.slice(0, k)).length;
          return m;
        };
      },
      // Each key stops at the match cap and narrows from the last key's matches: constant per key.
      { maxRatio: 4, runs: 9 },
    );
  });

  test("find while the PR streams in: 10k files in 512-file batches, flat per file at 10x", () => {
    const at10k = itemsOf(makeMixedPatch(10_000));
    const stream = (all: DiffItem[], next: boolean) => () => {
      const finder = new IncrementalDiffFind();
      let n = 0;
      for (let end = 512; end < all.length + 512; end += 512) {
        const items = all.slice(0, Math.min(end, all.length));
        n += next ? finder.update(items, "zzqqxx").length : collectFindMatches(items, "zzqqxx").length;
      }
      return n;
    };
    expectSpeedup("diffFind.stream_10k_files", 10_000, stream(at10k, false), stream(at10k, true), {
      minSpeedup: 3,
      budgetMs: 150,
      runs: 5,
    });
    const byFiles = new Map<number, DiffItem[]>();
    expectGrowth(
      "diffFind.stream",
      2_000,
      (n) => {
        if (!byFiles.has(n)) byFiles.set(n, itemsOf(makeMixedPatch(n)));
        return stream(byFiles.get(n)!, true);
      },
      // Line work is O(new lines) per batch (the op-count test above). What is left per batch is one pass over the
      // item array, the same order as the reducer's append copy and the hook's filter, so the total grows a bit past
      // linear (about 25x measured); the old full rescan was 85x.
      { maxRatio: 45, runs: 7 },
    );
  });

  test("collapsed lookup does not scan the list: 1k items against 1k collapsed keys", () => {
    const keys = Array.from({ length: 1000 }, (_, i) => `repo\u0000src/file-${i}.ts`);
    const probe = keys.map((key, i) => (i % 2 === 0 ? key : `${key}.missing`));
    const lookups = () => {
      let hits = 0;
      for (const key of probe) if (collapsedFileSet(keys).has(key)) hits++;
      return hits;
    };
    expect(lookups()).toBe(500);
    expectSpeedup(
      "diffViewer.collapsed_lookup_1k",
      1000,
      () => probe.filter((key) => keys.includes(key)).length,
      lookups,
      { minSpeedup: 3, budgetMs: 5 },
    );
  });
});
