import { parseProjectRepos, type DisplayGroup, type ProjectRepo } from "../projectRepos";

export type NativeProjectRow = { cwd: string; label: string; repo?: ProjectRepo; displayGroup?: DisplayGroup };

/// Decode the host's Rust-owned snapshot without sorting or regrouping it.
export function parseProjectRows(value: unknown): NativeProjectRow[] | undefined {
  if (typeof value !== "string") return undefined;
  let rows: unknown;
  try {
    rows = JSON.parse(value);
  } catch {
    return undefined;
  }
  if (!Array.isArray(rows)) return undefined;
  return rows.flatMap((row): NativeProjectRow[] => {
    if (!row || typeof row.cwd !== "string" || typeof row.label !== "string") return [];
    const repo = parseProjectRepos({ [row.cwd]: row.repo })[row.cwd];
    const display = row.displayGroup;
    const displayGroup = display && typeof display.key === "string" && typeof display.name === "string" &&
      typeof display.lead === "string" && typeof display.mainLead === "string" && typeof display.hidden === "boolean"
      ? { ...display, github: typeof display.github === "string" ? display.github : undefined } as DisplayGroup
      : undefined;
    return [{ cwd: row.cwd, label: row.label, ...(repo ? { repo } : {}), ...(displayGroup ? { displayGroup } : {}) }];
  });
}
