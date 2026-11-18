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
import { minimapTurns, type MinimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";
import { movedHints, rowPresence, type RowPresenceHints } from "../src/agent-session/acpmux/conversation/rowPresence";

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
  /// Every turn's scope and every row's turn, as plain values: each place as the row index it is
  /// (a place is `index + cache.base`), each map's entries in key order.
  const read = (rows: readonly AcpmuxRow[], cache: ReturnType<typeof newReferenceScopeCache>) => {
    const scopeOf = referenceScopes(rows, cache);
    const openers = ["", ...rows.filter((each) => each.kind === "user").map((each) => each.id)];
    const index = (at: number) => at - cache.base;
    const sorted = <K, V>(map: ReadonlyMap<K, V>) => [...map].sort(([a], [b]) => String(a).localeCompare(String(b)));
    return {
      scopes: openers.map((opener) => {
        const scope = scopeOf(opener);
        return [
          opener,
          index(scope.at),
          [...scope.turn],
          sorted(scope.evidence.mentions).map(([number, list]) => [
            number,
            list.map(({ at, repo }) => [index(at), repo]),
          ]),
          scope.evidence.linked,
          sorted(scope.evidence.smallest),
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

  test("a page above is read alone and put in front, and taken away again, as a reading from the first row", () => {
    const seed = { n: 11 };
    let rows = make(seed, "r", 40);
    const cache = newReferenceScopeCache();
    read(rows, cache);
    const pages: AcpmuxRow[][] = [];
    for (let step = 0; step < 60; step += 1) {
      const before = rows;
      const kind = step % 6;
      if (kind < 3 || !pages.length) {
        // A page: the turn it ends in takes the rows above the first prompt after it.
        const page = make(seed, `p${step}-`, 1 + (step % 4));
        pages.push(page);
        rows = [...page, ...before];
        noteKeptSuffix(rows, before, before.length);
        const base = cache.base;
        expect(read(rows, cache)).toEqual(read(rows, newReferenceScopeCache()));
        // Read alone: the rows read before keep their places.
        expect(cache.base).toBe(base - page.length);
        continue;
      }
      if (kind === 3) {
        const page = pages.pop()!;
        rows = before.slice(page.length);
        noteKeptSuffix(rows, before, rows.length);
        const base = cache.base;
        expect(read(rows, cache)).toEqual(read(rows, newReferenceScopeCache()));
        expect(cache.base).toBe(base + page.length);
        continue;
      }
      // A streamed last row, or a new turn: the pages under it can no longer be taken away alone.
      rows =
        kind === 4
          ? [...before.slice(0, -1), row(before.at(-1)!.id, "see acme/api#9")]
          : [...before, ...make(seed, `n${step}-`, 2)];
      if (kind === 4) noteKeptPrefix(rows, before, rows.length - 1);
      expect(read(rows, cache)).toEqual(read(rows, newReferenceScopeCache()));
      pages.length = 0;
    }
  });
});

describe("referenceScopes over a page that takes the first row's place", () => {
  test("a page drawn over the first row's date line, and taken away again, reads as a reading from the first row", () => {
    const seed = { n: 21 };
    const texts = ["see manaflow-ai/cmux#12", "and acme/web#7 too", "plain", "#12 again"];
    const make = (prefix: string, count: number) =>
      Array.from({ length: count }, (_, at) => {
        seed.n = (seed.n * 1103515245 + 12345) % 2 ** 31;
        return row(`${prefix}${at}`, texts[seed.n % texts.length]!, seed.n % 3 === 0 ? "user" : "assistant");
      });
    /// A date line: a row the reading reads nothing from.
    const date = (id: string) => row(`date-${id}`, "", "date");
    const cache = newReferenceScopeCache();
    let body = make("r", 40);
    let rows = [date("r"), ...body];
    const plainRead = (list: readonly AcpmuxRow[], reading: ReturnType<typeof newReferenceScopeCache>) => {
      const scopeOf = referenceScopes(list, reading);
      return [...new Set(["", ...list.map((each) => reading.rowTurn.get(each.id) ?? "")])].map((opener) => {
        const scope = scopeOf(opener);
        return [
          opener,
          scope.at === -Infinity ? "first" : scope.at - reading.base,
          [...scope.turn].sort(([a], [b]) => a - b),
        ];
      });
    };
    plainRead(rows, cache);
    for (let step = 0; step < 12; step += 1) {
      const before = rows;
      const page = make(`p${step}-`, 1 + (step % 3));
      // The page's own date line over it, the body's moved under the page's rows, its first rows
      // shaped again (new objects, read alike).
      const again = () => [...body.slice(0, 2).map((each) => ({ ...each })), ...body.slice(2)];
      rows = [date(`p${step}`), ...page, ...again()];
      noteKeptSuffix(rows, before, body.length - 2);
      const base = cache.base;
      expect(plainRead(rows, cache)).toEqual(plainRead(rows, newReferenceScopeCache()));
      expect(cache.base).toBe(base + 1 - (1 + page.length));
      const shown = rows;
      rows = [date(`r${step}`), ...again()];
      noteKeptSuffix(rows, shown, body.length - 2);
      expect(plainRead(rows, cache)).toEqual(plainRead(rows, newReferenceScopeCache()));
      expect(cache.base).toBe(base);
      if (step % 4 === 3) {
        body = [...body, ...make(`n${step}-`, 2)];
        const was = rows;
        rows = [rows[0]!, ...body];
        noteKeptPrefix(rows, was, was.length);
        plainRead(rows, cache);
      }
    }
  });
});

describe("minimapTurns over a page above the rows", () => {
  /// Turns of a prompt, a reply and sometimes a tool call, some prompts steers.
  const make = (seed: { n: number }, prefix: string, count: number) =>
    Array.from({ length: count }, (_, at): AcpmuxRow => {
      seed.n = (seed.n * 1103515245 + 12345) % 2 ** 31;
      const pick = seed.n % 5;
      const id = `${prefix}${at}`;
      if (pick === 0) return { id, kind: "user", text: `ask ${id}`, version: 1, at: 0 };
      if (pick === 1)
        return { id, kind: "user", text: `steer ${id}`, steer: "waiting", version: 1, at: 0 } as AcpmuxRow;
      if (pick === 2) return { id, kind: "activity", items: [], version: 1, at: 0 } as AcpmuxRow;
      return row(id, `reply **${id}** with \`code\``);
    });
  const plain = (read: MinimapTurns) => ({
    turns: read.turns.map(({ index, id, key, prompt, reply, metadata }) => [index, id, key, prompt, reply, metadata]),
    ticks: read.ticks.map(({ key, id, prompt }) => [key, id, prompt]),
  });

  test("pages above, rows taken from the head and streamed rows read as a reading from the first row", () => {
    const seed = { n: 5 };
    let rows = make(seed, "r", 60);
    let reading = minimapTurns(rows, "s");
    const pages: AcpmuxRow[][] = [];
    for (let step = 0; step < 60; step += 1) {
      const before = rows;
      const kind = step % 5;
      if (kind < 2 || !pages.length) {
        const page = make(seed, `p${step}-`, 1 + (step % 6));
        pages.push(page);
        rows = [...page, ...before];
        noteKeptSuffix(rows, before, before.length);
      } else if (kind === 2) {
        rows = before.slice(pages.pop()!.length);
        noteKeptSuffix(rows, before, rows.length);
      } else if (kind === 3) {
        // The first row drawn again over a page (a date line): a head replaced.
        const page = make(seed, `h${step}-`, 2);
        rows = [...page, ...before.slice(1)];
        noteKeptSuffix(rows, before, rows.length - 2);
        pages.length = 0;
      } else {
        rows = [...before, ...make(seed, `n${step}-`, 2)];
        pages.length = 0;
      }
      reading = minimapTurns(rows, "s", reading, { base: before, rows, from: rowsDelta(before, rows).from });
      expect(plain(reading)).toEqual(plain(minimapTurns(rows, "s")));
    }
  });
});

describe("rowPresence hints over a delta", () => {
  test("hints moved with the rows find what a walk finds, and an id taken out is gone without one", () => {
    const seed = { n: 9 };
    const next = () => (seed.n = (seed.n * 1103515245 + 12345) % 2 ** 31);
    let rows = Array.from({ length: 30 }, (_, at) => row(`r${at}`));
    const hints: RowPresenceHints = {};
    let serial = 0;
    for (let step = 0; step < 200; step += 1) {
      const before = rows;
      const from = next() % (before.length + 1);
      const cut = Math.min(before.length - from, next() % 4);
      // Sometimes a row taken out comes back in (a page taken away and shown again).
      const back = step % 7 === 0 && cut > 0 ? [before[from]!] : [];
      const added = [...back, ...Array.from({ length: next() % 4 }, () => row(`n${(serial += 1)}`))];
      rows = [...before.slice(0, from), ...added, ...before.slice(from + cut)];
      if (!rows.length) rows = [row(`n${(serial += 1)}`)];
      const pick = () => (next() % 5 === 0 ? `n${serial + 1}` : rows[next() % rows.length]!.id);
      const ids =
        step % 3 === 0 ? { active: pick(), anchor: pick(), focus: pick() } : { active: hints.gone?.active ?? pick() };
      movedHints(hints, rows, rowsDelta(before, rows), ids);
      const hinted = rowPresence(rows, ids.active, ids.anchor, ids.focus, hints);
      expect(hinted).toEqual(rowPresence(rows, ids.active, ids.anchor, ids.focus));
    }
  });
});
