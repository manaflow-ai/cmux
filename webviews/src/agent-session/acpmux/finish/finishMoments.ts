// The chat's finish moments (leo-workspace research/2026-10-26-delight.md touches 13, 14 and 16): when a
// long turn ends, when the chat's checks go green and when its pull request merges, the line that
// says so (the turn's "Worked for" row, the header's PR chip) shows a short "done" state, and with
// Agent Chat > Play Sound When Work Finishes on, the host plays a soft sound.
//
// Each moment comes from a state transition only (a turn's end, a pull request's new state), never
// from a token. The store holds one moment at a time and one timer that clears it; nothing else
// runs. A hidden page (a hidden or occluded window: WebKit reports it hidden) gets no visual moment,
// and Reduce Motion or motion off draws the done state still for the same short time (finish.css).
import { useSyncExternalStore } from "react";
import type { HeaderPullRequest } from "../header/headerState";

export type FinishKind = "turn" | "ci" | "merged";

export interface FinishMoment {
  readonly kind: FinishKind;
  /// Rises with each moment, so a row that drew the last one can tell a new one from it.
  readonly id: number;
  /// The chat it belongs to.
  readonly session?: string;
  /// A turn's start in the session's clock (the snapshot's `turnStartedAtMs`): the "Worked for" row
  /// of that turn, the newest, is the one that shows it (`isFinishedTurnRow`).
  readonly turnStartedAt?: number;
  /// The pull request a `ci` or `merged` moment is about.
  readonly url?: string;
}

/// A turn shorter than this ends quietly: a quick answer is no event (the brief's "more than about 30 s").
export const LONG_TURN_MS = 30_000;

/// How long each moment holds (ms), under the delight rules' 1 s. A merge is the bigger moment.
export const FINISH_MS: Readonly<Record<FinishKind, number>> = { turn: 700, ci: 700, merged: 950 };

/// Which moment wins when two would overlap: a merge outranks green checks, which outrank a turn's end.
const RANK: Readonly<Record<FinishKind, number>> = { turn: 0, ci: 1, merged: 2 };

/// The turn state the App reads per render (snapshotCache.ts `TurnState`) with the running turn's start.
export interface TurnFinishState {
  readonly session?: string;
  readonly working: boolean;
  readonly turnStartedAtMs?: number;
}

/// The ended turn's start when `last` -> `next` is the end of a turn of the same chat that ran at
/// least LONG_TURN_MS by `now` (this computer's clock; `clockOffsetMs` is this computer's clock
/// minus the session's). A turn whose start the page never saw is not timed, so it ends quietly.
export function longTurnEnded(
  last: TurnFinishState,
  next: TurnFinishState,
  now: number,
  clockOffsetMs = 0,
): number | undefined {
  if (last.session === undefined || last.session !== next.session) return undefined;
  if (!last.working || next.working || last.turnStartedAtMs === undefined) return undefined;
  return now - (last.turnStartedAtMs + clockOffsetMs) >= LONG_TURN_MS ? last.turnStartedAtMs : undefined;
}

/// The moment a pull request's new read is: `merged` when it became merged, `ci` when its checks went
/// from pending or failing to passing while it is open. The first read of a pull request (none
/// before, or another link) is no transition: a chat opened on a merged pull request does not cheer.
export function pullRequestFinish(
  last: HeaderPullRequest | undefined,
  next: HeaderPullRequest | undefined,
): FinishKind | undefined {
  if (!last || !next || last.url !== next.url) return undefined;
  if (next.state === "merged") return last.state === "merged" ? undefined : "merged";
  if (next.state !== "open" && next.state !== "draft") return undefined;
  const was = last.checks.state;
  return next.checks.state === "passing" && (was === "pending" || was === "failing") ? "ci" : undefined;
}

/// Whether a "Worked for" row (its `at` is its prompt's and `endAt` its end, in the session's clock) is
/// the turn a `turn` moment is about: the row whose span holds the ended turn's start. A resumed
/// turn's row keeps its first prompt, long before its latest start; an older turn's row ended
/// before this one began, and a newer turn's row starts after it. A row with no end yet is matched by
/// its start alone.
export function isFinishedTurnRow(moment: FinishMoment | undefined, rowAt: number, endAt?: number): boolean {
  if (moment?.kind !== "turn" || moment.turnStartedAt === undefined) return false;
  const start = moment.turnStartedAt;
  // A later prompt's row (a new turn started while the moment shows) starts after this turn's start.
  // The ended turn's row ends at least LONG_TURN_MS after its start; the turn before it ended at
  // or before that start, so the end has no tolerance (a live row with no end yet is judged by its start).
  return rowAt <= start + 2_000 && (endAt === undefined ? rowAt >= start - 2_000 : endAt > start);
}

let current: FinishMoment | undefined;
let nextId = 1;
let timer: ReturnType<typeof setTimeout> | undefined;
const listeners = new Set<() => void>();

function publish(next: FinishMoment | undefined): void {
  current = next;
  for (const listener of listeners) listener();
}

/// Whether the page is on screen now; a hidden or occluded window's page is hidden.
const pageShown = (): boolean => typeof document === "undefined" || document.visibilityState !== "hidden";

/// Starts a moment. Returns whether it shows: not on a hidden page, and not under a bigger one still
/// showing. Its one timer clears it after FINISH_MS; a newer moment cancels that timer and starts its own.
export function startFinishMoment(moment: Omit<FinishMoment, "id">, shown = pageShown()): boolean {
  if (!shown) return false;
  if (current && RANK[current.kind] > RANK[moment.kind]) return false;
  if (timer !== undefined) clearTimeout(timer);
  const started: FinishMoment = { ...moment, id: nextId++ };
  publish(started);
  timer = setTimeout(() => {
    timer = undefined;
    if (current?.id === started.id) publish(undefined);
  }, FINISH_MS[moment.kind]);
  return true;
}

/// Ends any moment at once (the chat closed or changed): its timer goes with it.
export function endFinishMoment(): void {
  if (timer !== undefined) clearTimeout(timer);
  timer = undefined;
  if (current) publish(undefined);
}

export const finishMoment = (): FinishMoment | undefined => current;

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// Whether the "Worked for" row from `rowAt` to `endAt` shows a `turn` moment now. A
/// boolean, so only that row draws again when a moment starts or ends.
export function useFinishedTurn(rowAt: number, endAt?: number): boolean {
  const read = () => isFinishedTurnRow(current, rowAt, endAt);
  return useSyncExternalStore(subscribe, read, read);
}

/// The `ci` or `merged` moment pull request `url` shows now.
export function usePullRequestFinish(url: string): FinishKind | undefined {
  const read = () => (current && current.kind !== "turn" && current.url === url ? current.kind : undefined);
  return useSyncExternalStore(subscribe, read, read);
}
