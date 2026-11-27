// Pure helpers for the inspector: sizes, node names, the zoom path, and where cache cuts fall.
import type { Block, TurnRow, Usage, ViewLine } from "./types";

export function formatBytes(n: number | null | undefined): string {
  if (n == null) return "–";
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(2)} MB`;
}

/** About four bytes of English per token: a rough guide, labeled "≈" wherever it shows. */
export function approxTokens(bytes: number): number {
  return Math.round(bytes / 4);
}

export function formatTokens(n: number | null | undefined): string {
  if (n == null) return "–";
  return n >= 10_000 ? `${(n / 1000).toFixed(1)}k` : String(n);
}

export function formatMs(ms: number | null | undefined): string {
  if (ms == null) return "–";
  if (ms < 1000) return `${ms} ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)} s`;
  return `${Math.floor(ms / 60_000)} min ${Math.round((ms % 60_000) / 1000)} s`;
}

export function formatPct(x: number | null | undefined): string {
  return x == null ? "–" : `${Math.round(x * 100)}%`;
}

export function hitRate(u: Usage | null | undefined): number | null {
  if (!u) return null;
  const all = u.cache_read + u.cache_write + u.input;
  return all > 0 ? u.cache_read / all : null;
}

export type NodeName = { start: number; n: number; level: number };

/** `id+n` as numbers; null when n is not a power of two or id not a multiple of n. */
export function parseName(name: string): NodeName | null {
  const m = /^(\d+)\+(\d+)$/.exec(name.trim());
  if (!m) return null;
  const start = Number(m[1]);
  const n = Number(m[2]);
  if (n < 1 || (n & (n - 1)) !== 0 || start % n !== 0) return null;
  return { start, n, level: Math.log2(n) };
}

export function nodeName(start: number, n: number): string {
  return `${start}+${n}`;
}

/** The two nodes `zoom` opens a node into, or null for one message. */
export function childrenOf(name: string): [string, string] | null {
  const p = parseName(name);
  if (!p || p.n === 1) return null;
  const half = p.n / 2;
  return [nodeName(p.start, half), nodeName(p.start + half, half)];
}

/**
 * The zoom path after focusing `name`: a child of the last hop extends it (a zoom), a node on
 * the path cuts back to it, anything else starts a new path.
 */
export function nextPath(path: string[], name: string): string[] {
  const at = path.indexOf(name);
  if (at >= 0) return path.slice(0, at + 1);
  const last = path[path.length - 1];
  if (last && childrenOf(last)?.includes(name)) return [...path, name];
  return [name];
}

/** What ends at a view line's end: cache marks, grid cuts, our marker, the system prompt's end. */
export type LineCuts = { mark: boolean; grid: boolean; marker: boolean; systemEnd: boolean; unchanged: boolean };

export function lineCuts(
  lines: ViewLine[],
  marks: number[],
  grid: number[],
  blocks: Block[] | undefined,
  unchangedPrefix: number | null | undefined,
): LineCuts[] {
  const markSet = new Set(marks);
  const gridSet = new Set(grid);
  const ours = new Set<number>();
  let systemEnd = -1;
  for (const b of blocks ?? []) {
    if (b.kind !== "view" || b.view_start == null) continue;
    const end = b.view_start + b.bytes;
    if (b.role === "system") systemEnd = end;
    if (b.cache === "ours") ours.add(end);
  }
  return lines.map((l) => {
    const end = l.offset + l.bytes;
    return {
      mark: markSet.has(end),
      grid: gridSet.has(end),
      marker: ours.has(end),
      systemEnd: end === systemEnd,
      unchanged: unchangedPrefix != null && end <= unchangedPrefix,
    };
  });
}

/** One bar segment per prompt part, in send order, for the size bar. */
export type Segment = { label: string; bytes: number; tone: "system" | "view-system" | "view" | "messages" };

export function segments(blocks: Block[] | undefined): Segment[] {
  const out: Segment[] = [];
  for (const b of blocks ?? []) {
    const tone: Segment["tone"] =
      b.kind === "instructions"
        ? "system"
        : b.kind === "messages"
          ? "messages"
          : b.role === "system"
            ? "view-system"
            : "view";
    const label =
      tone === "system"
        ? "Instructions"
        : tone === "messages"
          ? "New messages"
          : tone === "view-system"
            ? "View head (in system prompt)"
            : "View";
    const prev = out[out.length - 1];
    if (prev && prev.tone === tone) prev.bytes += b.bytes;
    else out.push({ label, bytes: b.bytes, tone });
  }
  return out;
}

export function turnLabel(t: TurnRow): string {
  const when = new Date(t.ts);
  const hh = when.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  return `#${t.first} · ${when.toLocaleDateString([], { month: "short", day: "numeric" })} ${hh}`;
}

export function topTools(names: Record<string, number> | undefined, k = 3): string {
  const entries = Object.entries(names ?? {}).sort((a, b) => b[1] - a[1]);
  if (entries.length === 0) return "none";
  const shown = entries.slice(0, k).map(([n, c]) => (c > 1 ? `${n} ×${c}` : n));
  return entries.length > k ? `${shown.join(", ")} +${entries.length - k}` : shown.join(", ");
}
