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
