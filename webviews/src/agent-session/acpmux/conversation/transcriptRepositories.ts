// The repository a bare `#N` in each row means when the chat's folder has no GitHub remote
// (a remote or cloud chat, a folder without one): the one the transcript mentioned last, up to and
// including that row, else `fallback` (the header pull request's). Only prompts and replies count.
import { mentionedRepository } from "../../../githubReferences";
import type { AcpmuxRow } from "../model";
import { rowsDelta } from "./rowsDelta";

/** Each row's mention by id, kept with the text it was read from: only a changed row is read again. */
export type RepositoryCache = Map<string, { text: string; repository: string | undefined }>;

export function transcriptRepositories(
  rows: readonly Pick<AcpmuxRow, "id" | "kind" | "text">[],
  fallback?: string,
  cache: RepositoryCache = new Map(),
): (string | undefined)[] {
  let latest: string | undefined;
  return rows.map((row) => {
    if ((row.kind === "user" || row.kind === "assistant") && row.text) {
      const cached = cache.get(row.id);
      const known = cached?.text === row.text ? cached : { text: row.text, repository: mentionedRepository(row.text) };
      if (known !== cached) cache.set(row.id, known);
      latest = known.repository ?? latest;
    }
    return latest ?? fallback;
  });
}

/** One reading of a transcript (`transcriptRepositoriesFrom`): the rows read, the fallback, and
 *  where the repository mentioned last changes (`marks`, by row index, in order). `at(index)` is the
 *  repository row `index` means. A mention changes seldom, so a reading holds a few marks, never a
 *  value per row: a chat of 35,000 rows copied two arrays of 35,000 on each event. */
export type RepositoryReading = {
  readonly rows: readonly Pick<AcpmuxRow, "id" | "kind" | "text">[];
  readonly fallback: string | undefined;
  readonly marks: readonly { readonly index: number; readonly repository: string }[];
  readonly at: (index: number) => string | undefined;
};

/** `transcriptRepositories`, read again only where the rows are not the same objects as in
 *  `previous` (rowsDelta.ts: rows change at their tail, a streamed token changes the last reply, and
 *  a page of older history lands before the first row), so a delta's work does not grow with the
 *  transcript. The same rows and fallback give `previous` back. */
export function transcriptRepositoriesFrom(
  rows: readonly Pick<AcpmuxRow, "id" | "kind" | "text">[],
  fallback: string | undefined,
  cache: RepositoryCache,
  previous?: RepositoryReading,
): RepositoryReading {
  let start = 0;
  let end = rows.length;
  let baseEnd = 0;
  const reused = previous && previous.fallback === fallback ? previous : undefined;
  if (reused) {
    const delta = rowsDelta(reused.rows, rows);
    if (delta.from === rows.length && rows.length === reused.rows.length) return reused;
    ({ from: start, end, baseEnd } = delta);
  }
  let keep = start > 0 ? reused!.marks.length : 0;
  while (keep > 0 && reused!.marks[keep - 1]!.index >= start) keep -= 1;
  const marks = keep > 0 ? reused!.marks.slice(0, keep) : [];
  let latest = marks.at(-1)?.repository;
  const readRow = (index: number) => {
    const row = rows[index]!;
    if ((row.kind === "user" || row.kind === "assistant") && row.text) {
      const cached = cache.get(row.id);
      const known = cached?.text === row.text ? cached : { text: row.text, repository: mentionedRepository(row.text) };
      if (known !== cached) cache.set(row.id, known);
      if (known.repository !== undefined && known.repository !== latest) {
        latest = known.repository;
        marks.push({ index, repository: latest });
      }
    }
  };
  for (let index = start; index < end; index += 1) readRow(index);
  if (reused && end < rows.length) {
    // The rows after the change are the last reading's, moved by `shift`: its marks there hold once
    // the repository mentioned last is the same at their start as it was. Before the last
    // reading's first mark there, its rows mentioned only the repository it had then.
    const shift = end - baseEnd;
    let first = reused.marks.length;
    while (first > 0 && reused.marks[first - 1]!.index >= baseEnd) first -= 1;
    const before = first > 0 ? reused.marks[first - 1]!.repository : undefined;
    let next = first;
    if (latest !== before) {
      if (before === undefined) {
        // Those rows mentioned nothing: the first mark's row is the first that mentions anything.
        const mark = reused.marks[next];
        if (mark) {
          if (mark.repository !== latest) marks.push({ index: mark.index + shift, repository: mark.repository });
          latest = mark.repository;
          next += 1;
        }
      } else {
        // They may mention the repository this reading no longer has: read them again up to the
        // first mark, where both readings name the same repository.
        const to = (reused.marks[next]?.index ?? reused.rows.length) + shift;
        for (let index = end; index < to; index += 1) readRow(index);
        const mark = reused.marks[next];
        if (mark) {
          if (mark.repository !== latest) marks.push({ index: mark.index + shift, repository: mark.repository });
          latest = mark.repository;
          next += 1;
        }
      }
    }
    for (let at = next; at < reused.marks.length; at += 1) {
      const mark = reused.marks[at]!;
      marks.push(shift === 0 ? mark : { index: mark.index + shift, repository: mark.repository });
    }
  }
  const at = (index: number) => {
    // The last mark at or before `index`.
    let low = 0;
    let high = marks.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (marks[middle]!.index <= index) low = middle + 1;
      else high = middle;
    }
    return low > 0 ? marks[low - 1]!.repository : fallback;
  };
  return { rows, fallback, marks, at };
}
