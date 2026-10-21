import type { AcpmuxRow } from "../model";

export type RepositoryCache = Map<string, { text: string; repository: string | undefined }>;

/** Not implemented yet. */
export function transcriptRepositories(
  rows: readonly Pick<AcpmuxRow, "id" | "kind" | "text">[],
  _fallback?: string,
  _cache: RepositoryCache = new Map(),
): (string | undefined)[] {
  return rows.map(() => undefined);
}
