// Session Info's Storage (StorageSection.tsx): the space this Mac can get back, as stale git
// worktrees from acpmux's worktree care (`_acpmux/worktree/report {staleOnly: true}`, cmux-tui
// crates/cmux-worktree-care pass.rs `Report`). Only a stale worktree is offered: clean, finished (its
// branch merged or squashed into a base) and used by no live session. Every other worktree is one
// folded count with its reason. A size is the one acpmux measured; a worktree it did not reach in its
// sizing budget reads "—", never a guess.
//
// Pure: parsing the replies, the rows, the selection's preview and what a clean did. The view and its
// requests are StorageSection.tsx's.
import type { StringValues } from "../i18n";
import { fileSizeLabel } from "../fileAttachmentModel";

export type StoragePressure = "normal" | "high" | "critical";

export type StorageDisk = { total: number; available: number };

/// One worktree acpmux looked at (pass.rs `Item`), as the section reads it.
export type StorageItem = {
  path: string;
  repository: string;
  branch?: string;
  action: "keep" | "trim" | "reclaim" | "archive";
  reason: string;
  /// Measured on disk; absent when not measured.
  bytes?: number;
  stale: boolean;
  /// What a clean did to it (pass.rs `Outcome`), on a clean's report only.
  outcome?: { ok: boolean; freed: number; error?: string };
};

/// A pass's report (pass.rs `Report`), as the section reads it.
export type StorageReport = {
  disk?: StorageDisk;
  pressure: StoragePressure;
  applied: boolean;
  items: StorageItem[];
  freed: number;
  reclaimable: number;
  errors: string[];
  at?: number;
};

const num = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
const text = (value: unknown): string | undefined => (typeof value === "string" && value ? value : undefined);

function itemOf(value: unknown): StorageItem | undefined {
  const raw = (value ?? {}) as Record<string, unknown>;
  const path = text(raw.path);
  if (!path) return undefined;
  const verdict = (raw.verdict ?? {}) as Record<string, unknown>;
  const action = verdict.action;
  const outcome = raw.outcome && typeof raw.outcome === "object" ? (raw.outcome as Record<string, unknown>) : undefined;
  const bytes = num(raw.bytes);
  const branch = text(raw.branch);
  return {
    path,
    repository: text(raw.repository) ?? "",
    ...(branch ? { branch } : {}),
    action: action === "trim" || action === "reclaim" || action === "archive" ? action : "keep",
    reason: text(verdict.reason) ?? "",
    ...(bytes !== undefined ? { bytes } : {}),
    stale: raw.stale === true,
    ...(outcome
      ? {
          outcome: {
            ok: outcome.ok === true,
            freed: num(outcome.freed) ?? 0,
            ...(text(outcome.error) ? { error: text(outcome.error) } : {}),
          },
        }
      : {}),
  };
}

/// A report from a `worktree/report` reply (`{report, last}`) or a `worktree/clean` reply (the report
/// itself); undefined for anything else.
export function parseStorageReport(reply: unknown): StorageReport | undefined {
  const outer = (reply ?? undefined) as Record<string, unknown> | undefined;
  if (!outer || typeof outer !== "object") return undefined;
  const raw = (outer.report && typeof outer.report === "object" ? outer.report : outer) as Record<string, unknown>;
  if (!Array.isArray(raw.items)) return undefined;
  const disk = raw.disk && typeof raw.disk === "object" ? (raw.disk as Record<string, unknown>) : undefined;
  const total = num(disk?.total);
  const available = num(disk?.available);
  const pressure = raw.pressure === "high" || raw.pressure === "critical" ? raw.pressure : "normal";
  return {
    ...(total !== undefined && available !== undefined && total > 0 ? { disk: { total, available } } : {}),
    pressure,
    applied: raw.applied === true,
    items: raw.items.flatMap((value) => {
      const item = itemOf(value);
      return item ? [item] : [];
    }),
    freed: num(raw.freed) ?? 0,
    reclaimable: num(raw.reclaimable) ?? 0,
    errors: Array.isArray(raw.errors) ? raw.errors.filter((e): e is string => typeof e === "string" && !!e) : [],
    ...(num(raw.at) !== undefined ? { at: num(raw.at) } : {}),
  };
}

/// The last part of a path.
export const baseName = (path: string) => path.replace(/\/+$/, "").split("/").pop() || path;

/// One worktree the person may free.
export type StaleRow = {
  path: string;
  /// The worktree's folder name.
  name: string;
  /// Its repository's folder name ("" when acpmux named none).
  repository: string;
  branch?: string;
  reason: string;
  bytes?: number;
};

/// One worktree kept, with why.
export type KeptRow = { path: string; name: string; reason: string };

export type StorageRows = { stale: StaleRow[]; kept: KeptRow[] };

/// The report's rows: the stale worktrees, the largest first (unmeasured last, by name), and the kept
/// ones by name.
export function storageRows(report: StorageReport): StorageRows {
  const stale: StaleRow[] = [];
  const kept: KeptRow[] = [];
  for (const item of report.items) {
    const name = baseName(item.path);
    if (item.stale)
      stale.push({
        path: item.path,
        name,
        repository: item.repository ? baseName(item.repository) : "",
        ...(item.branch ? { branch: item.branch } : {}),
        reason: item.reason,
        ...(item.bytes !== undefined ? { bytes: item.bytes } : {}),
      });
    else kept.push({ path: item.path, name, reason: item.reason });
  }
  stale.sort((a, b) => (b.bytes ?? -1) - (a.bytes ?? -1) || a.name.localeCompare(b.name));
  kept.sort((a, b) => a.name.localeCompare(b.name));
  return { stale, kept };
}

/// The stale rows under their repository's caption, the repositories in the order their first (largest)
/// row comes: the grouped layout's items, captions and rows in one list for WindowedRows.
export type GroupedItem = { caption: string } | { row: StaleRow };

export function groupedRows(stale: readonly StaleRow[]): GroupedItem[] {
  const groups = new Map<string, StaleRow[]>();
  for (const row of stale) {
    const group = groups.get(row.repository);
    if (group) group.push(row);
    else groups.set(row.repository, [row]);
  }
  return [...groups].flatMap(([caption, rows]) => [{ caption }, ...rows.map((row) => ({ row }))]);
}

/// What the selected rows would free.
export type StoragePreview = { count: number; bytes: number; unmeasured: number };

export function storagePreview(stale: readonly StaleRow[], selected: ReadonlySet<string>): StoragePreview {
  let count = 0;
  let bytes = 0;
  let unmeasured = 0;
  for (const row of stale) {
    if (!selected.has(row.path)) continue;
    count += 1;
    if (row.bytes === undefined) unmeasured += 1;
    else bytes += row.bytes;
  }
  return { count, bytes, unmeasured };
}

/// A size as the pane writes file sizes (fileAttachmentModel.ts); "—" when not measured.
export function storageBytes(bytes: number | undefined, language: string): string {
  return (bytes === undefined ? undefined : fileSizeLabel(bytes, language)) ?? "—";
}

/// The pieces of the Free button's label: the string and its values. "Free 3 worktrees · 2.1 GB";
/// with some of them unmeasured, "2.1 GB or more"; with none measured, no size.
export function previewLabel(
  preview: StoragePreview,
  language: string,
): { key: "sessionInfo.storage.free"; values: StringValues; size?: { unmeasured: boolean; text: string } } {
  const measured = preview.count - preview.unmeasured;
  return {
    key: "sessionInfo.storage.free",
    values: { n: preview.count },
    ...(measured > 0
      ? { size: { unmeasured: preview.unmeasured > 0, text: storageBytes(preview.bytes, language) } }
      : {}),
  };
}

/// `selected` with `path` flipped.
export function toggled(selected: ReadonlySet<string>, path: string): Set<string> {
  const next = new Set(selected);
  if (next.has(path)) next.delete(path);
  else next.add(path);
  return next;
}

/// Every stale row selected, or none when every one already is.
export function toggledAll(stale: readonly StaleRow[], selected: ReadonlySet<string>): Set<string> {
  const all = stale.length > 0 && stale.every((row) => selected.has(row.path));
  return all ? new Set() : new Set(stale.map((row) => row.path));
}

/// `selected` without the paths no row has any more.
export function keptSelection(stale: readonly StaleRow[], selected: ReadonlySet<string>): ReadonlySet<string> {
  if (selected.size === 0) return selected;
  const paths = new Set(stale.map((row) => row.path));
  const next = new Set([...selected].filter((path) => paths.has(path)));
  return next.size === selected.size ? selected : next;
}

/// What a clean did: the rows it freed leave, the ones it refused stay in place with its words, and
/// how much it freed (`report.freed`).
export function afterClean(
  stale: readonly StaleRow[],
  clean: StorageReport,
): { stale: StaleRow[]; failed: Map<string, string>; freed: number } {
  const outcomes = new Map(clean.items.flatMap((item) => (item.outcome ? [[item.path, item.outcome] as const] : [])));
  const failed = new Map<string, string>();
  const left = stale.filter((row) => {
    const outcome = outcomes.get(row.path);
    if (!outcome) return true;
    if (outcome.ok) return false;
    failed.set(row.path, outcome.error ?? "");
    return true;
  });
  return { stale: left, failed, freed: clean.freed };
}

/// The disk's used share, 0 to 1.
export function usedShare(disk: StorageDisk): number {
  return disk.total > 0 ? Math.min(1, Math.max(0, 1 - disk.available / disk.total)) : 0;
}

/// Why a request failed, for the section: acpmux (or the pane's host) does not know the method, so the
/// section hides; another pass runs; anything else.
export function storageFailure(error: unknown): "unsupported" | "busy" | "failed" {
  const raw = (error ?? {}) as { code?: unknown; message?: unknown };
  const code = raw.code;
  if (code === -32601 || code === "transport.method_refused" || code === "remote.unsupported") return "unsupported";
  if (typeof raw.message === "string" && /already running/i.test(raw.message)) return "busy";
  return "failed";
}
