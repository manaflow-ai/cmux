// `transcriptRepositoriesFrom` read once per change of the rows, the GitHub remote or the fallback, each
// reading from the one before it (transcriptRepositories.ts), outside the transcript's render so the
// React Compiler sees no ref read or written there.
import { useMemo, useState } from "react";
import type { AcpmuxRow } from "../model";
import { transcriptRepositoriesFrom, type RepositoryCache, type RepositoryReading } from "./transcriptRepositories";

/// Which repository each row's bare `#N` means (`at(index)`), or undefined with a GitHub remote.
export function useRowRepositories(
  rows: readonly AcpmuxRow[],
  githubRepository: string | undefined,
  fallbackRepository: string | undefined,
): ((index: number) => string | undefined) | undefined {
  const [reader] = useState(() => new RepositoryReader());
  return useMemo(
    () => (githubRepository ? undefined : reader.read(rows, fallbackRepository)),
    [reader, githubRepository, fallbackRepository, rows],
  );
}

class RepositoryReader {
  private readonly cache: RepositoryCache = new Map();
  private reading: RepositoryReading | undefined;

  read(rows: readonly AcpmuxRow[], fallback: string | undefined): (index: number) => string | undefined {
    this.reading = transcriptRepositoriesFrom(rows, fallback, this.cache, this.reading);
    return this.reading.at;
  }
}
