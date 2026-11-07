// The transcript's open folds in a hidden chat's wake state (AgentPaneWakeState.swift `folds`): a page
// let go while hidden (agents.hiddenChats.discard, browser.hibernation) is built again with the chat's
// tool cards, thoughts, "Worked for" and subagent groups open or closed as the reader left them
// (Leo, 2026-11-07: "if it really isn't being used after a while, can't things be more aggressive?").
import { isTranscriptView, type TranscriptView } from "./transcriptView";

/// The most fold ids each list keeps: the newest ones (a Set keeps insertion order), so a long chat's
/// wake state stays small while the folds the reader touched last come back.
export const WAKE_FOLD_LIMIT = 200;

/// What the page hands the host (`pane.wakeState`) and gets back with its handshake (`wake.folds`).
export type WakeFolds = {
  session: string;
  expanded?: string[];
  opened?: string[];
  viewToggles?: Partial<Record<TranscriptView, string[]>>;
};

/// The folds as the pane holds them (App.tsx `expanded`, `openedGroups`, `viewToggles`).
export type PaneFolds = {
  expanded: ReadonlySet<string>;
  opened: ReadonlySet<string>;
  viewToggles: ReadonlyMap<TranscriptView, ReadonlySet<string>>;
};

const newest = (ids: Iterable<string>): string[] => {
  const all = [...ids];
  return all.length > WAKE_FOLD_LIMIT ? all.slice(all.length - WAKE_FOLD_LIMIT) : all;
};

/// Chat `session`'s open folds for the wake state, bounded; undefined when nothing is open or toggled.
export function wakeFolds(session: string | undefined, folds: PaneFolds): WakeFolds | undefined {
  if (!session) return undefined;
  const expanded = newest(folds.expanded);
  const opened = newest(folds.opened);
  const toggles: Partial<Record<TranscriptView, string[]>> = {};
  for (const [view, toggled] of folds.viewToggles) if (toggled.size > 0) toggles[view] = newest(toggled);
  const hasToggles = Object.keys(toggles).length > 0;
  if (!expanded.length && !opened.length && !hasToggles) return undefined;
  return {
    session,
    ...(expanded.length ? { expanded } : {}),
    ...(opened.length ? { opened } : {}),
    ...(hasToggles ? { viewToggles: toggles } : {}),
  };
}

const ids = (value: unknown): string[] =>
  Array.isArray(value) ? newest(value.filter((id): id is string => typeof id === "string")) : [];

/// The handshake's `wake.folds` for chat `session`; undefined when absent, malformed or another chat's.
export function readWakeFolds(value: unknown, session: string | undefined): PaneFolds | undefined {
  if (!session || !value || typeof value !== "object") return undefined;
  const folds = value as { session?: unknown; expanded?: unknown; opened?: unknown; viewToggles?: unknown };
  if (folds.session !== session) return undefined;
  const viewToggles = new Map<TranscriptView, ReadonlySet<string>>();
  if (folds.viewToggles && typeof folds.viewToggles === "object")
    for (const [view, list] of Object.entries(folds.viewToggles as Record<string, unknown>)) {
      const toggled = ids(list);
      if (isTranscriptView(view) && toggled.length) viewToggles.set(view, new Set(toggled));
    }
  return { expanded: new Set(ids(folds.expanded)), opened: new Set(ids(folds.opened)), viewToggles };
}

/// A composer holds a draft a hidden-chat release keeps its page for (`holdsDraft`): typed text, or chips.
export const composerHoldsDraft = (text: string, attachments: readonly unknown[]): boolean =>
  text.trim() !== "" || attachments.length > 0;
