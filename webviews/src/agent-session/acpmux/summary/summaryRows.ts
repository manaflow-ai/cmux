// A pinned summary section's rows as data (PINNED-SUMMARY S1). A section comes from the user's
// config, from a provider the daemon runs, or from the chat's agent; whatever wrote it, the pane
// draws only text: no HTML, no markdown, no remote images. Links are http(s) URLs or paths, and
// a row the agent wrote opens a URL only after an inline confirm that names the host; its paths
// open only inside the chat's folder (`provenance`, coordinator amendment 2026-10-09).

export type SummaryProvenance = "builtin" | "user" | "agent";
export type SummaryRowState = "ok" | "warn" | "error" | "running";

/// A row as a provider or an agent sent it: any field may be missing or of the wrong type.
export type SummaryRowInput = {
  title?: unknown;
  subtitle?: unknown;
  href?: unknown;
  badge?: unknown;
  state?: unknown;
};

/// A custom section as the host hands it over. `error` is a provider's failure reason (the
/// daemon backs off; the pane only shows it).
export type SummarySectionInput = {
  id: string;
  title: string;
  source: SummaryProvenance;
  rows?: readonly SummaryRowInput[];
  error?: string;
};

export type SummaryLink = { kind: "url"; url: string; host: string; confirm: boolean } | { kind: "path"; path: string };

export type SummaryRow = {
  key: string;
  title: string;
  subtitle?: string;
  badge?: string;
  state?: SummaryRowState;
  link?: SummaryLink;
};

export type SummaryCustomSection = {
  id: string;
  title: string;
  source: SummaryProvenance;
  rows: SummaryRow[];
  error?: string;
};

/// Rows a section keeps; the rest are dropped.
export const MAX_ROWS = 50;
const TITLE_MAX = 200;
const SUBTITLE_MAX = 200;
const BADGE_MAX = 24;
const STATES = new Set<SummaryRowState>(["ok", "warn", "error", "running"]);

/// Plain text: a string or number, control characters as spaces, cut to `max`; else nothing.
function text(value: unknown, max: number): string | undefined {
  const raw = typeof value === "number" && Number.isFinite(value) ? String(value) : value;
  if (typeof raw !== "string") return undefined;
  // oxlint-disable-next-line no-control-regex -- control characters are what this removes.
  const clean = raw.replace(/[\u0000-\u001f\u007f]/g, " ").trim();
  return clean ? clean.slice(0, max) : undefined;
}

/// `/a/b` inside `folder` (or `folder` itself), with no `.` or `..` segment.
function insideFolder(path: string, folder: string | undefined): boolean {
  if (!folder) return false;
  const base = folder.replace(/\/+$/, "");
  if (path.split("/").some((part) => part === "." || part === "..")) return false;
  return path === base || path.startsWith(`${base}/`);
}

function link(href: unknown, source: SummaryProvenance, folder: string | undefined): SummaryLink | undefined {
  if (typeof href !== "string") return undefined;
  const value = href.trim();
  if (value.startsWith("/")) {
    if (value.split("/").some((part) => part === "..")) return undefined;
    if (source === "agent" && !insideFolder(value, folder)) return undefined;
    return { kind: "path", path: value };
  }
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return undefined;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return undefined;
  return { kind: "url", url: url.href, host: url.host, confirm: source === "agent" };
}

/// The section the pane draws: text rows, allowed links only, at most `MAX_ROWS`.
export function sanitizeSection(input: SummarySectionInput, folder?: string): SummaryCustomSection {
  const rows: SummaryRow[] = [];
  for (const [index, row] of (input.rows ?? []).entries()) {
    if (rows.length === MAX_ROWS) break;
    const title = text(row?.title, TITLE_MAX);
    if (!title) continue;
    const state = typeof row.state === "string" && STATES.has(row.state as SummaryRowState) ? row.state : undefined;
    rows.push({
      key: String(index),
      title,
      subtitle: text(row.subtitle, SUBTITLE_MAX),
      badge: text(row.badge, BADGE_MAX),
      state: state as SummaryRowState | undefined,
      link: link(row.href, input.source, folder),
    });
  }
  return {
    id: input.id,
    title: text(input.title, TITLE_MAX) ?? input.id,
    source: input.source,
    rows,
    error: text(input.error, SUBTITLE_MAX),
  };
}
