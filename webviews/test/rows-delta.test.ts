// rowsDelta.ts: what a new rows array changed of the last, found once and read by the transcript's
// passes, and the readings built on it, which must equal a reading from the first row.
import { describe, expect, test } from "bun:test";
import { movedIndex, noteKeptSuffix, rowsDelta } from "../src/agent-session/acpmux/conversation/rowsDelta";
import { noteKeptPrefix } from "../src/agent-session/acpmux/conversation/prefixFlatMap";
import {
  transcriptRepositoriesFrom,
  type RepositoryReading,
} from "../src/agent-session/acpmux/conversation/transcriptRepositories";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { newReferenceScopeCache, referenceScopes } from "../src/agent-session/acpmux/conversation/bareReferences";

const row = (id: string, text = "", kind = "assistant"): AcpmuxRow => ({ id, kind, text, version: 1, at: 0 });

describe("rowsDelta", () => {
  test("a streamed token: the changed row, the rows before it and after it kept", () => {
    const base = Array.from({ length: 10 }, (_, at) => row(`r${at}`));
    const rows = [...base];
    rows[8] = row("r8", "more");
    expect(rowsDelta(base, rows)).toMatchObject({ from: 8, end: 9, baseEnd: 9 });
  });

  test("a page above the rows, told by its maker: no walk over the rows it kept", () => {
    const base = Array.from({ length: 1000 }, (_, at) => row(`r${at}`));
    const rows = [row("p0"), row("p1"), ...base];
    noteKeptSuffix(rows, base, base.length);
    const delta = rowsDelta(base, rows);
    expect(delta).toMatchObject({ from: 0, end: 2, baseEnd: 0 });
    expect(movedIndex(delta, 0)).toBe(2);
    expect(movedIndex(delta, 999)).toBe(1001);
  });

  test("a told count is a floor: the delta walks on to the true change", () => {
    const base = Array.from({ length: 20 }, (_, at) => row(`r${at}`));
    const rows = [...base];
    rows[15] = row("r15", "changed");
    noteKeptPrefix(rows, base, 3);
    expect(rowsDelta(base, rows)).toMatchObject({ from: 15, end: 16, baseEnd: 16 });
  });

  test("the prefix and suffix never overlap", () => {
    const shared = row("x");
    const base = [shared, shared];
    const rows = [shared, shared, shared];
    const delta = rowsDelta(base, rows);
    expect(delta.from + (rows.length - delta.end)).toBeLessThanOrEqual(base.length);
    expect(delta.end - delta.from).toBe(rows.length - base.length + (delta.baseEnd - delta.from));
  });

  test("rows taken from the head, and the same rows", () => {
    const base = Array.from({ length: 6 }, (_, at) => row(`r${at}`));
    const rows = base.slice(2);
    expect(rowsDelta(base, rows)).toMatchObject({ from: 0, end: 0, baseEnd: 2 });
    expect(rowsDelta(base, base)).toMatchObject({ from: 6, end: 6, baseEnd: 6 });
    expect(movedIndex(rowsDelta(base, rows), 1)).toBe(-1);
  });
});

describe("transcriptRepositoriesFrom over a delta", () => {
  const mention = (repo: string) => `see ${repo}#12`;
  /// Random rows, some mentioning one of a few repositories.
  const make = (seed: { n: number }, prefix: string, count: number) =>
    Array.from({ length: count }, (_, at) => {
      seed.n = (seed.n * 1103515245 + 12345) % 2 ** 31;
      const pick = seed.n % 7;
      const text = pick < 3 ? mention(["manaflow-ai/cmux", "acme/web", "acme/api"][pick]!) : "plain words";
      return row(`${prefix}${at}`, text, pick % 2 ? "user" : "assistant");
    });
  const same = (a: RepositoryReading, b: RepositoryReading) => {
    expect(a.marks.map((m) => [m.index, m.repository])).toEqual(b.marks.map((m) => [m.index, m.repository]));
    for (let at = 0; at < a.rows.length; at += 1) expect(a.at(at)).toBe(b.at(at));
  };

  test("pages above, streamed tails and rows taken away read as a reading from the first row", () => {
    const seed = { n: 7 };
    let rows = make(seed, "r", 40);
    let reading = transcriptRepositoriesFrom(rows, "fallback/repo", new Map());
    for (let step = 0; step < 60; step += 1) {
      const before = rows;
      const kind = step % 4;
      if (kind === 0) {
        rows = [...make(seed, `p${step}-`, 1 + (step % 3)), ...before];
        noteKeptSuffix(rows, before, before.length);
      } else if (kind === 1) {
        rows = [...before];
        rows[rows.length - 1] = row(rows.at(-1)!.id, step % 2 ? mention("acme/web") : "streamed");
      } else if (kind === 2) rows = before.slice(1 + (step % 2));
      else rows = [...before.slice(0, 5), ...make(seed, `m${step}-`, 3), ...before.slice(9)];
      reading = transcriptRepositoriesFrom(rows, "fallback/repo", new Map(), reading);
      same(reading, transcriptRepositoriesFrom(rows, "fallback/repo", new Map()));
    }
  });
});

describe("referenceScopes over a delta", () => {
  const texts = ["see manaflow-ai/cmux#12", "and acme/web#7 too", "plain", "#12 again", "nothing"];
  const make = (seed: { n: number }, prefix: string, count: number) =>
    Array.from({ length: count }, (_, at) => {
      seed.n = (seed.n * 1103515245 + 12345) % 2 ** 31;
      return row(`${prefix}${at}`, texts[seed.n % texts.length]!, seed.n % 3 === 0 ? "user" : "assistant");
    });
  /// Every turn's scope and every row's turn, as plain values.
  const read = (rows: readonly AcpmuxRow[], cache: ReturnType<typeof newReferenceScopeCache>) => {
    const scopeOf = referenceScopes(rows, cache);
    const openers = ["", ...rows.filter((each) => each.kind === "user").map((each) => each.id)];
    return {
      scopes: openers.map((opener) => {
        const scope = scopeOf(opener);
        return [
          opener,
          scope.at,
          [...scope.turn],
          [...scope.evidence.mentions],
          scope.evidence.linked,
          [...scope.evidence.smallest],
        ];
      }),
      turns: rows.map((each) => cache.rowTurn.get(each.id)),
    };
  };

  test("streamed rows above the last, pages above and new turns read as a reading from the first row", () => {
    const seed = { n: 3 };
    let rows = make(seed, "r", 30);
    const cache = newReferenceScopeCache();
    read(rows, cache);
    for (let step = 0; step < 80; step += 1) {
      const before = rows;
      const kind = step % 5;
      if (kind === 0 || kind === 1) {
        rows = [...before];
        const at = rows.length - 1 - (step % 3);
        rows[at] = row(rows[at]!.id, texts[step % texts.length]!, rows[at]!.kind);
        noteKeptPrefix(rows, before, at);
      } else if (kind === 2) rows = [...before, ...make(seed, `n${step}-`, 2)];
      else if (kind === 3) {
        rows = [...make(seed, `p${step}-`, 2), ...before];
        noteKeptSuffix(rows, before, before.length);
      } else rows = before.slice(0, -1);
      expect(read(rows, cache)).toEqual(read(rows, newReferenceScopeCache()));
    }
  });
});
