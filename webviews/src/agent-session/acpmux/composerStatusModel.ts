// What the composer status dot shows (ComposerStatusDot.tsx), and nothing it draws. acpmux decides the
// session's items and facts (`summary.composerStatus`, cmux-tui/crates/acpmux/src/protocol/
// composer_status.rs) and the machine link's item (`status` on a peer's link); the pane adds only what
// it alone knows (its own connection to acpmux, a send it holds). Everything here is pure: the dot's
// clock is passed in, so a test runs it on a fake one.
import { hostRecoveryLine, type HostRestoring } from "./hostRetry";
import { CONNECTION_QUIET_MS } from "../../ui/lasting";
import type { StringKey } from "./i18n";
import type { FactKind, StatusAction, StatusKind, StatusLevel } from "./protocol/generated/types";

export type { FactKind, StatusAction, StatusKind, StatusLevel };

/// One entry of the dot's rundown (acpmux `StatusItem`), with every optional field absent, never null.
export type StatusItem = {
  kind: StatusKind;
  level: StatusLevel;
  /// A string-catalog key; one this build does not know is never drawn (`statusWordsKey`).
  words: string;
  subject?: string;
  since?: number;
  until?: number;
  /// The dot shows it no earlier than this, ms since the epoch.
  showAt?: number;
  action?: StatusAction;
};

/// One piece of the footer's quiet metadata (acpmux `FooterFact`).
export type FooterFact = {
  kind: FactKind;
  text?: string;
  count?: number;
  /// The share of the context window used, 0 to 1.
  fraction?: number;
  since?: number;
  /// Worth a counter in the footer row itself now.
  live: boolean;
  /// Worth its words in the footer at rest (the machine of a chat on another machine); the pane
  /// draws it only behind `composer-machine-at-rest`.
  atRest?: boolean;
};

export type ComposerStatus = { items: StatusItem[]; facts: FooterFact[] };

const KINDS: ReadonlySet<string> = new Set<StatusKind>([
  "machineLink",
  "rateLimited",
  "stuck",
  "queuePaused",
  "harnessSandbox",
  "agentService",
  "restoringSessions",
  "sendsHeld",
]);
const LEVELS: ReadonlySet<string> = new Set<StatusLevel>(["info", "attention", "problem"]);
const ACTIONS: ReadonlySet<string> = new Set<StatusAction>(["reconnect", "resumeQueue", "signIn", "update"]);
const FACTS: ReadonlySet<string> = new Set<FactKind>([
  "machine",
  "folder",
  "branch",
  "harness",
  "model",
  "context",
  "turn",
  "subagents",
  "queued",
]);

/// Every words key this build draws. A key acpmux sends that is not here (a newer daemon's) renders
/// nothing rather than the raw key.
const WORDS: Record<string, StringKey> = {
  "status.machineLink.connecting": "status.machineLink.connecting",
  "status.machineLink.reconnecting": "status.machineLink.reconnecting",
  "status.machineLink.degraded": "status.machineLink.degraded",
  "status.machineLink.restarting": "status.machineLink.restarting",
  "status.machineLink.offline": "status.machineLink.offline",
  "status.machineLink.removed": "status.machineLink.removed",
  "status.machineLink.authFailed": "status.machineLink.authFailed",
  "status.machineLink.updateRequired": "status.machineLink.updateRequired",
  "status.machineLink.offline.credentialUnavailable": "status.machineLink.offline.credentialUnavailable",
  "status.machineLink.offline.machineStopped": "status.machineLink.offline.machineStopped",
  "status.machineLink.offline.loginNeeded": "status.machineLink.offline.loginNeeded",
  "status.machineLink.offline.restartBudgetExceeded": "status.machineLink.offline.restartBudgetExceeded",
  "status.machineLink.offline.diskFull": "status.machineLink.offline.diskFull",
  "status.rateLimited.parked": "status.rateLimited.parked",
  "status.rateLimited.until": "status.rateLimited.until",
  "status.stuck.harnessUnavailable": "status.stuck.harnessUnavailable",
  "status.stuck.capacity": "status.stuck.capacity",
  "status.stuck.auth": "status.stuck.auth",
  "status.stuck.spawnFailed": "status.stuck.spawnFailed",
  "status.harnessSandbox.failing": "status.harnessSandbox.failing",
  "status.queuePaused.paused": "status.queuePaused.paused",
  "status.agentService.reconnecting": "status.agentService.reconnecting",
  "status.restoringSessions.restoring": "status.restoringSessions.restoring",
  "status.sendsHeld.held": "status.sendsHeld.held",
};

/// The catalog key an item draws: undefined for words this build does not know and, given `now`, for
/// an item not yet due (`statusDueAt`).
export function statusWordsKey(
  item: Pick<StatusItem, "words" | "kind" | "level" | "since" | "showAt">,
  now?: number,
): StringKey | undefined {
  const key = Object.hasOwn(WORDS, item.words) ? WORDS[item.words] : undefined;
  if (key === undefined || now === undefined) return key;
  // The quiet bound a link coming back waits (acpmux's LINK_QUIET_MS is the same 10 s).
  const quietFrom = quietLink(item) ? item.since : undefined;
  const due = item.showAt ?? (quietFrom === undefined ? undefined : quietFrom + CONNECTION_QUIET_MS);
  return due === undefined || due <= now ? key : undefined;
}

const quietLink = (item: Pick<StatusItem, "kind" | "level" | "since">) =>
  item.kind === "machineLink" && item.level === "info" && item.since !== undefined;

/// When an item may show: its `showAt`; else, for a link coming back (an info machine-link item) sent
/// without one, the shared quiet bound after its `since`; undefined: at once.
export function statusDueAt(item: StatusItem): number | undefined {
  const quietFrom = quietLink(item) ? item.since : undefined;
  return item.showAt ?? (quietFrom === undefined ? undefined : quietFrom + CONNECTION_QUIET_MS);
}

const time = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : undefined);
const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);
const record = (value: unknown): Record<string, unknown> | undefined =>
  value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;

/// An item as acpmux sent it, or undefined when it is not one (an unknown kind or level). A null
/// field reads as absent.
export function readStatusItem(value: unknown): StatusItem | undefined {
  const raw = record(value);
  if (!raw || typeof raw.kind !== "string" || !KINDS.has(raw.kind)) return undefined;
  if (typeof raw.level !== "string" || !LEVELS.has(raw.level) || typeof raw.words !== "string") return undefined;
  const item: StatusItem = { kind: raw.kind as StatusKind, level: raw.level as StatusLevel, words: raw.words };
  const subject = text(raw.subject);
  if (subject !== undefined) item.subject = subject;
  const since = time(raw.since);
  if (since !== undefined) item.since = since;
  const until = time(raw.until);
  if (until !== undefined) item.until = until;
  const showAt = time(raw.showAt);
  if (showAt !== undefined) item.showAt = showAt;
  if (typeof raw.action === "string" && ACTIONS.has(raw.action)) item.action = raw.action as StatusAction;
  return item;
}

function readFact(value: unknown): FooterFact | undefined {
  const raw = record(value);
  if (!raw || typeof raw.kind !== "string" || !FACTS.has(raw.kind)) return undefined;
  const fact: FooterFact = { kind: raw.kind as FactKind, live: raw.live === true };
  const words = text(raw.text);
  if (words !== undefined) fact.text = words;
  const count = time(raw.count);
  if (count !== undefined) fact.count = count;
  const fraction = time(raw.fraction);
  if (fraction !== undefined) fact.fraction = Math.min(1, Math.max(0, fraction));
  const since = time(raw.since);
  if (since !== undefined) fact.since = since;
  if (raw.atRest === true) fact.atRest = true;
  return fact;
}

/// A session's `composerStatus`, or undefined from an older acpmux (absent, null or malformed).
export function readComposerStatus(value: unknown): ComposerStatus | undefined {
  const raw = record(value);
  if (!raw || !Array.isArray(raw.items) || !Array.isArray(raw.facts)) return undefined;
  return {
    items: raw.items.flatMap((item) => readStatusItem(item) ?? []),
    facts: raw.facts.flatMap((fact) => readFact(fact) ?? []),
  };
}

const RANK: Record<StatusLevel, number> = { info: 0, attention: 1, problem: 2 };

/// Worst level first, then the oldest `since` (an unknown one last): acpmux's own order.
export function byWorst(a: StatusItem, b: StatusItem): number {
  return RANK[b.level] - RANK[a.level] || (a.since ?? Number.POSITIVE_INFINITY) - (b.since ?? Number.POSITIVE_INFINITY);
}

/// One item per kind, the worst (then the oldest) of each, in `byWorst` order. Items whose words this
/// build does not know are dropped first, so they neither draw nor tint the dot.
export function dedupe(items: readonly StatusItem[]): StatusItem[] {
  const best = new Map<StatusKind, StatusItem>();
  for (const item of items) {
    if (!statusWordsKey(item)) continue;
    const held = best.get(item.kind);
    if (!held || byWorst(item, held) < 0) best.set(item.kind, item);
  }
  return [...best.values()].sort(byWorst);
}

/// The items due by `now` (`statusDueAt`) whose words this build knows.
export function shown(items: readonly StatusItem[], now: number): StatusItem[] {
  return items.filter((item) => statusWordsKey(item, now) !== undefined);
}

/// The earliest moment after `now` among `times`, the dot's one timer's wake; undefined when none.
export function nextWake(times: readonly (number | undefined)[], now: number): number | undefined {
  let next: number | undefined;
  for (const at of times) if (at !== undefined && at > now && (next === undefined || at < next)) next = at;
  return next;
}

/// The worst level among `items`, or undefined for none.
export function worstLevel(items: readonly StatusItem[]): StatusLevel | undefined {
  let worst: StatusLevel | undefined;
  for (const item of items) if (worst === undefined || RANK[item.level] > RANK[worst]) worst = item.level;
  return worst;
}

/// What the pane's own connection to acpmux says (App.tsx, as HostRecoveringLine reads it).
export type HostRecovery = {
  linkDown?: boolean;
  restoring?: HostRestoring;
  failureShown?: boolean;
};

/// The pane's own recovery as a dot item, under HostRecoveringLine's rule (hostRetry.ts
/// `hostRecoveryLine`): it follows the connection's state, never a clock (Leo, 2026-11-22: "surely we
/// can think of better fixes than random timing which can shift"). "Restoring sessions…" while the
/// host says acpmux restores, else "Reconnecting…" while the link is down for real; nothing while a
/// failure the pane already says covers it. No `wakeAt`: only a new state changes the answer.
export function hostRecoveryItem(host: HostRecovery | undefined, now: number): { item?: StatusItem; wakeAt?: number } {
  const line = host && hostRecoveryLine({ ...host, now });
  if (!line) return {};
  if (line.kind === "restoring") {
    return {
      item: {
        kind: "restoringSessions",
        level: "info",
        words: "status.restoringSessions.restoring",
        since: now - line.waitedMs,
      },
    };
  }
  return { item: { kind: "agentService", level: "info", words: "status.agentService.reconnecting" } };
}

/// A send the composer holds until acpmux answers (sendWhenReady.ts), as a dot item.
export function sendsHeldItem(held: boolean): StatusItem | undefined {
  return held ? { kind: "sendsHeld", level: "info", words: "status.sendsHeld.held" } : undefined;
}

/// The last two segments of a folder path, for the card's row (the whole path is its tooltip).
export function folderTail(path: string): string {
  const parts = path.split(/[\\/]+/).filter(Boolean);
  if (parts.length <= 2) return path;
  return parts.slice(-2).join("/");
}

/// A live counter's number: up to 9, then "9+".
export function counterText(count: number): string {
  return count > 9 ? "9+" : String(Math.max(0, Math.floor(count)));
}
