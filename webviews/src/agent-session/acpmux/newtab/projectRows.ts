import { parseProjectRepos, type ProjectRepo } from "../projectRepos";

export type NativeProjectRow = { cwd: string; label: string; repo?: ProjectRepo };

/// Decode the host's Rust-owned snapshot without sorting or regrouping it.
export function parseProjectRows(value: unknown): NativeProjectRow[] | undefined {
  if (typeof value !== "string") return undefined;
  let rows: unknown;
  try { rows = JSON.parse(value); } catch { return undefined; }
  if (!Array.isArray(rows)) return undefined;
  return rows.flatMap((row): NativeProjectRow[] => {
    if (!row || typeof row.cwd !== "string" || typeof row.label !== "string") return [];
    const repo = parseProjectRepos({ [row.cwd]: row.repo })[row.cwd];
    return [{ cwd: row.cwd, label: row.label, ...(repo ? { repo } : {}) }];
  });
}
