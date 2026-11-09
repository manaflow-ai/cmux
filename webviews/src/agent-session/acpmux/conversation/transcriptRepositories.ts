// The repository a bare `#N` in each row means when the chat's folder has no GitHub remote
// (a remote or cloud chat, a folder without one): the one the transcript mentioned last, up to and
// including that row, else `fallback` (the header pull request's). Only prompts and replies count.
import { mentionedRepository } from "../../../githubReferences";
import type { AcpmuxRow } from "../model";

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

/** One reading of a transcript (`transcriptRepositoriesFrom`): the rows read, the fallback, the
 *  repository each row means and the last one mentioned up to each row. */
export type RepositoryReading = {
  readonly rows: readonly Pick<AcpmuxRow, "id" | "kind" | "text">[];
  readonly fallback: string | undefined;
  readonly repositories: readonly (string | undefined)[];
  readonly mentioned: readonly (string | undefined)[];
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
    const limit = Math.min(rows.length, previous.rows.length);
    while (start < limit && rows[start] === previous.rows[start]) start += 1;
    if (start === rows.length && rows.length === previous.rows.length) return previous;
  }
  const mentioned = previous && start > 0 ? previous.mentioned.slice(0, start) : [];
  const repositories = previous && start > 0 ? previous.repositories.slice(0, start) : [];
  let latest = start > 0 ? mentioned[start - 1] : undefined;
  for (let index = start; index < rows.length; index += 1) {
    const row = rows[index]!;
    if ((row.kind === "user" || row.kind === "assistant") && row.text) {
      const cached = cache.get(row.id);
      const known = cached?.text === row.text ? cached : { text: row.text, repository: mentionedRepository(row.text) };
      if (known !== cached) cache.set(row.id, known);
      latest = known.repository ?? latest;
    }
    mentioned.push(latest);
    repositories.push(latest ?? fallback);
  }
  return { rows, fallback, repositories, mentioned };
}
