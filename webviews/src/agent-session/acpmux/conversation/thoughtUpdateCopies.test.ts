// l10n-allow-file: test fixture text, not shipped UI.
// A thought or token in a long chat copies none of the chat's rows where nothing it changed draws
// differently, and at most once where it does (bench/transcript-replay.bench.ts god, ALLOC=1: each
// thought update copied the kept rows with `slice` and then again as `push` grew the copy).
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { projectInboxRows } from "./laneNoticeBatches";
import { noteKeptPrefix, prefixFlatMap } from "./prefixFlatMap";

const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at,
  ...extra,
});

/// A chat of `count` rows: a prompt every ten rows, replies between, no inbox.
function chat(count: number): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [];
  for (let index = 0; index < count; index += 1)
    rows.push(
      index % 10 === 0
        ? row(`p${index}`, "user", index, { text: `prompt ${index}` })
        : row(`r${index}`, "assistant", index, { text: `reply ${index}` }),
    );
  return rows;
}

/// The next snapshot, as the client makes it: the last row a new object, the rest kept and said so.
function token(rows: readonly AcpmuxRow[]): AcpmuxRow[] {
  const last = rows.at(-1)!;
  const next = [...rows.slice(0, -1), { ...last, version: last.version + 1, text: `${last.text} more` }];
  noteKeptPrefix(next, rows, rows.length - 1);
  return next;
}

test("a pass whose changed rows yield no item gives the last pass's items back, not a copy", () => {
  const prompts = (each: AcpmuxRow) => (each.kind === "user" ? [each.id] : []);
  const rows = chat(20_000);
  const first = prefixFlatMap(rows, prompts);
  const next = token(rows);
  const second = prefixFlatMap(next, prompts, first);
  expect(second.rows).toBe(next);
  expect(second.items).toBe(first.items);
  expect(second.from).toBe(first.from);
  expect(second.items.length).toBe(2_000);
  // A changed row that yields an item still gets its own lists.
  const prompt = [...next, row("p-new", "user", 30_000, { text: "again" })];
  noteKeptPrefix(prompt, next, next.length);
  const third = prefixFlatMap(prompt, prompts, second);
  expect(third.items).not.toBe(second.items);
  expect(third.items.at(-1)).toBe("p-new");
  expect(third.from.at(-1)).toBe(prompt.length - 1);
  expect(third.items.length).toBe(2_001);
});

test("a chat with no inbox draws its rows as they are on every update, with no copy of them", () => {
  const rows = chat(20_000);
  expect(projectInboxRows(rows)).toBe(rows);
  let previous = rows;
  for (let update = 0; update < 3; update += 1) {
    const next = token(previous);
    // turnViewFrom hands over the rows it reused: all but the last.
    expect(projectInboxRows(next, previous, next.length - 1)).toBe(next);
    previous = next;
  }
});
