// The repository a bare `#N` in each row means when the chat's folder has no GitHub remote
// (a remote or cloud chat, a folder without one): the one the transcript mentioned last, up to and
// including that row, else `fallback` (the header pull request's). Only prompts and replies count.
import { mentionedRepository } from "../../../githubReferences";
import type { AcpmuxRow } from "../model";
import { keptPrefix } from "./prefixFlatMap";

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

/** `transcriptRepositories`, read again only from the first row that is not the same object as in
 *  `previous` (rows change at their tail: a streamed token changes the last reply), so a delta's
 *  work does not grow with the transcript. The same rows and fallback give `previous` back. */
export function transcriptRepositoriesFrom(
  rows: readonly Pick<AcpmuxRow, "id" | "kind" | "text">[],
  fallback: string | undefined,
  cache: RepositoryCache,
  previous?: RepositoryReading,
): RepositoryReading {
  let start = 0;
  if (previous && previous.fallback === fallback) {
    start = keptPrefix(previous.rows, rows);
    if (start === rows.length && rows.length === previous.rows.length) return previous;
  }
  let keep = start > 0 ? previous!.marks.length : 0;
  while (keep > 0 && previous!.marks[keep - 1]!.index >= start) keep -= 1;
  const marks = keep > 0 ? previous!.marks.slice(0, keep) : [];
  let latest = marks.at(-1)?.repository;
  for (let index = start; index < rows.length; index += 1) {
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
