// Find in Chat over the whole transcript (Leo, 2026-11-18: "shouldn't you be able to like have better
// tools for finding stuff?"): the pane holds only the turns it has paged in, so the daemon's
// transcript index (`_acpmux/transcript_search`, acpmux `transcript_search.rs`, scoped to the pane's
// session, `order: "transcript"`) answers for the rest. Loaded rows keep their exact local matches
// (chatFind.ts); an index hit counts only when no loaded row holds it, and stepping to one pages the
// transcript through it (`FindIndexSource.load`) before it is drawn and highlighted like any match.
// A daemon without the method (an older acpmux, a host that does not relay it) answers nothing, and
// Find works on the loaded rows as before.
import type { AcpmuxRow } from "../model";
import type { FindMatch } from "./chatFind";

/** One hit of the daemon's index in this chat, as Find reads it. */
export type IndexHit = {
  /** When the line was written (ms). */
  at: number;
  /** The log seq of the record holding it, when the daemon could place it in this session's log. */
  seq?: number;
  /** The harness message id the line carries (`agent_message_chunk.messageId`). */
  messageId?: string;
  /** Its transcript position, which tells two hits of one message apart. */
  line?: number;
  matchStart?: number;
  role?: string;
  snippet?: string;
  /** In the time span of the rows on screen (`window`). */
  inWindow?: boolean;
};

export type IndexAnswer = {
  hits: IndexHit[];
  /** Every hit of the query in the chat, past this page; absent when the daemon did not count. */
  total?: number;
};

export type IndexWindow = { fromMs: number; toMs: number };

export type IndexSearch = { query: string; window?: IndexWindow; limit: number; offset?: number };

/** What the pane gives Find for the daemon's index of its chat (App.tsx, through ChatFindScope). */
export type FindIndexSource = {
  /** The chat it searches: another key starts every search over. */
  key: string;
  /** One page of hits, oldest first; undefined when the daemon has no index to ask. */
  search: (search: IndexSearch) => Promise<IndexAnswer | undefined>;
  /** The time span of the rows on screen, asked for first. */
  window?: () => IndexWindow | undefined;
  /** Whether the record at `seq` is among the loaded rows. */
  holdsSeq?: (seq: number) => boolean;
  /** The loaded rows message `messageId` streamed into (direct.ts `rowsOfMessage`). */
  rowsOfMessage?: (messageId: string) => readonly string[];
  /** Pages the transcript in until it holds `hit`; true once it does. */
  load: (hit: IndexHit) => Promise<boolean>;
};

/** Hits per page, the daemon's most (transcript_search.rs MAX_LIMIT). */
export const INDEX_PAGE = 200;
/** The first answer, for the rows on screen: small, so it lands at once. */
export const WINDOW_PAGE = 50;
/** Pages read per query at most: past them the hits are newer than any page reaches. */
export const INDEX_PAGES = 5;
/** Typing settles this long before the daemon is asked. */
export const INDEX_DEBOUNCE_MS = 150;

const num = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : undefined);
const str = (value: unknown) => (typeof value === "string" && value ? value : undefined);

/** A daemon answer as Find reads it, oldest first (an acpmux before `order` answers newest first). */
export function readAnswer(raw: unknown): IndexAnswer | undefined {
  const hits = (raw as { hits?: unknown } | undefined)?.hits;
  if (!Array.isArray(hits)) return undefined;
  const read: IndexHit[] = [];
  for (const each of hits) {
    const hit = each as Record<string, unknown>;
    const at = num(hit.at);
    if (at === undefined) continue;
    read.push({
      at,
      ...(num(hit.seq) !== undefined && { seq: num(hit.seq) }),
      ...(str(hit.messageId) && { messageId: str(hit.messageId) }),
      ...(num(hit.line) !== undefined && { line: num(hit.line) }),
      ...(num(hit.matchStart) !== undefined && { matchStart: num(hit.matchStart) }),
      ...(str(hit.role) && { role: str(hit.role) }),
      ...(typeof hit.snippet === "string" && { snippet: hit.snippet }),
      ...(hit.inWindow === true && { inWindow: true }),
    });
  }
  const total = num((raw as { total?: unknown }).total);
  return { hits: read, ...(total !== undefined && { total }) };
}

/** A hit's identity across answers. */
export const hitKey = (hit: IndexHit) =>
  `hit:${hit.seq ?? ""}:${hit.messageId ?? ""}:${hit.at}:${hit.line ?? ""}:${hit.matchStart ?? ""}`;

/** Hits of several answers as one list, oldest first, each once. */
export function mergeHits(...answers: readonly (readonly IndexHit[])[]): IndexHit[] {
  const seen = new Map<string, IndexHit>();
  for (const hits of answers) for (const hit of hits) if (!seen.has(hitKey(hit))) seen.set(hitKey(hit), hit);
  return [...seen.values()].sort(
    (a, b) =>
      a.at - b.at ||
      (a.seq ?? 0) - (b.seq ?? 0) ||
      (a.line ?? 0) - (b.line ?? 0) ||
      (a.matchStart ?? 0) - (b.matchStart ?? 0),
  );
}

/** Whether a loaded row holds `hit`, so its local match stands for it: its record's seq is held,
 * else its message drew a row, else it is no older than the oldest loaded row. */
export function hitLoaded(
  hit: IndexHit,
  rows: readonly AcpmuxRow[],
  source: Pick<FindIndexSource, "holdsSeq" | "rowsOfMessage">,
): boolean {
  if (hit.seq !== undefined && source.holdsSeq) return source.holdsSeq(hit.seq);
  if (hit.messageId && (source.rowsOfMessage?.(hit.messageId).length ?? 0) > 0) return true;
  const first = rows[0];
  return first !== undefined && hit.at >= first.at;
}

/** A place Find can be: a match in a loaded row, or an index hit in a turn not loaded yet. */
export type FindStep = { key: string; at: number } & (
  | { match: FindMatch; matchIndex: number; hit?: undefined }
  | { hit: IndexHit; match?: undefined }
);

export const matchKey = (match: Pick<FindMatch, "rowId" | "occurrence">) => `${match.rowId}#${match.occurrence}`;

/** The loaded matches and the hits outside them, in transcript order: a hit goes before the first
 * match whose row is newer. */
export function findSteps(
  matches: readonly FindMatch[],
  rows: readonly AcpmuxRow[],
  hits: readonly IndexHit[],
): FindStep[] {
  const steps: FindStep[] = [];
  let next = 0;
  for (const [matchIndex, match] of matches.entries()) {
    const at = rows[match.rowIndex]?.at ?? 0;
    while (next < hits.length && hits[next]!.at < at) {
      const hit = hits[next++]!;
      steps.push({ key: hitKey(hit), at: hit.at, hit });
    }
    steps.push({ key: matchKey(match), at, match, matchIndex });
  }
  for (; next < hits.length; next++) steps.push({ key: hitKey(hits[next]!), at: hits[next]!.at, hit: hits[next]! });
  return steps;
}

/** The step nearest `atMs`; the first one when two are as near. -1 when there are none. */
export function nearestStep(steps: readonly FindStep[], atMs: number): number {
  let best = -1;
  for (const [index, step] of steps.entries())
    if (best < 0 || Math.abs(step.at - atMs) < Math.abs(steps[best]!.at - atMs)) best = index;
  return best;
}

/** The loaded match that stands for `hit` once its turn is loaded: the first in a row of its
 * message, else the first in a row no older than it, else the nearest. -1 when nothing matches. */
export function landedStep(
  steps: readonly FindStep[],
  hit: IndexHit,
  rowsOfMessage?: (messageId: string) => readonly string[],
): number {
  const local = steps.flatMap((step, index) => (step.match ? [{ step, index }] : []));
  if (local.length === 0) return -1;
  const ofMessage = hit.messageId ? new Set(rowsOfMessage?.(hit.messageId) ?? []) : undefined;
  if (ofMessage?.size) {
    const held = local.find(({ step }) => ofMessage.has(step.match!.rowId));
    if (held) return held.index;
  }
  const after = local.find(({ step }) => step.at >= hit.at);
  if (after && after.step.at - hit.at < LANDED_WITHIN_MS) return after.index;
  return local[nearestStep(local.map(({ step }) => step), hit.at)]!.index;
}

/** A row draws up to this long after the line it came from was written (a reply's first chunk). */
const LANDED_WITHIN_MS = 10 * 60_000;

/** The time span of rows `ids` (the rows on screen), from `rows`. */
export function rowsWindow(rows: readonly AcpmuxRow[], ids: readonly string[] | null | undefined): IndexWindow | undefined {
  if (!ids?.length) return undefined;
  const wanted = new Set(ids);
  let fromMs = Infinity;
  let toMs = -Infinity;
  for (const row of rows) {
    if (!wanted.has(row.id) || !row.at) continue;
    fromMs = Math.min(fromMs, row.at);
    toMs = Math.max(toMs, row.at);
  }
  return fromMs <= toMs ? { fromMs, toMs } : undefined;
}
