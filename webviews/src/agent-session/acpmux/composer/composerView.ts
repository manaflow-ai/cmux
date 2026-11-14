// The snapshot the composer draws from keeps its identity while nothing the composer shows changed
// (coordinator brief after Leo, 2026-11-07: "the composer and the session info thing ... doing these
// kind of flicker re-renders when you are streaming in text"). Every snapshot acpmux sends is a new
// object with a new `rows` array, and a tool call is one: the pane drew the composer again for each,
// though it shows no tool call. The composer reads its rows only for the person's own prompts (the
// arrow keys' history), a held prompt waiting for its chat, whether the chat has any rows or any past
// its start, and why a failed turn paused the queue; `composerRows` keeps exactly those rows, and
// `useComposerView` hands back the last view while it holds the same values.
//
// A running turn and the chats around it change more than rows (Leo, 2026-11-09: "im still sometimes
// seeing a flicker on the composer/composer hat when scrolling and things are running in background
// aka time is ticking + i assume you're either thinking or runnign tool calls"). The turn's token
// counts and its subagents' progress change on each tool step, and another chat that runs changes its
// status, its dot and its times in `sessions` on each of its own events; the composer reads none of
// them, and each drew it again (four times a second with another chat working, in
// test/agent-pane-scroll-tick-composer-hat-still.test.ts). The view leaves the turn's live fields out
// (`TURN_LIVE`) and, in a chat that has started, holds its `sessions` while only another chat's live
// fields moved (`sameSessions`).
import { useRef } from "react";
import { PrefixFilter } from "../conversation/prefixFlatMap";
import { linkUp, type AcpmuxRow, type AcpmuxSnapshot } from "../model";
import type { AcpmuxSessionEntry } from "../sessionList";

/// What a running turn changes on each tool step that nothing in the composer reads (Composer.tsx,
/// ComposerPickers.tsx, ComposerContext.tsx and the chips: none of them names these): its token counts,
/// the turn's start, the count of ended turns, and its subagents' transcripts and progress, which the
/// transcript, the hat and Session Info draw from the pane's own snapshot.
const TURN_LIVE = [
  "turnTokens",
  "turnTokenSplit",
  "turnStartedAtMs",
  "turnsEnded",
  "subagentViews",
  "subagentProgress",
  "subagentStructureVersion",
] as const satisfies readonly (keyof AcpmuxSnapshot)[];

/// What another chat changes as it runs (its status, its dot, its times, its unread mark, its latest
/// words and pull request): the chat list's and the sidebar's, never a started chat's composer, which
/// reads another chat only for the @ menu (its title, folder and whether it is listed; mentionItems.ts)
/// and its own entry in full. The @ menu with nothing typed after the @ lists the most recent chats by
/// `updatedAt`: that order follows the composer's next draw (any change it shows), not each event of
/// another chat.
const OTHER_CHAT_LIVE: ReadonlySet<string> = new Set<keyof AcpmuxSessionEntry>([
  "status",
  "indicator",
  "updatedAt",
  "activityAt",
  "pendingPermissions",
  "unread",
  "preview",
  "lastMessage",
  "pullRequest",
  "pullRequestUrls",
]);

/// The rows the composer reads (Composer.tsx, ComposerPickers.tsx): the first row and the first past the
/// chat's start (so "no rows" and "started" read the same), every prompt the person sent, every queued
/// row, and every failed turn's summary (queuePause.ts). In order, as `rows` has them.
export function composerRows(rows: readonly AcpmuxRow[]): AcpmuxRow[] {
  const kept: AcpmuxRow[] = [];
  if (!rows.length) return kept;
  // The first row past the chat's start: a few rows in at most.
  let started = 0;
  while (started < rows.length && rows[started]!.kind === "sessionStart") started += 1;
  kept.push(rows[0]!);
  // The prompts, queued rows and failed summaries come from a pass that reads only the rows a
  // snapshot changed (prefixFlatMap.ts): a chat of 7,000 turns no longer reads every row per event.
  const { items, from } = composerReads.read(rows);
  let head = started > 0 && started < rows.length;
  for (let at = 0; at < items.length; at++) {
    const index = from[at]!;
    if (head && index >= started) {
      kept.push(rows[started]!);
      head = false;
    }
    if (index !== 0 && index !== started) kept.push(items[at]!);
  }
  if (head) kept.push(rows[started]!);
  return kept;
}

/// A row the composer reads wherever it is (composerRows): a prompt, a queued row, a failed turn's summary.
const composerReads = new PrefixFilter<AcpmuxRow>(
  (row) => row.kind === "user" || row.queued !== undefined || (row.kind === "turnSummary" && row.status === "failed"),
);

/// The same members by identity, one level down: arrays element by element, anything else by `Object.is`.
function sameMember(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
  for (let index = 0; index < a.length; index++) if (!Object.is(a[index], b[index])) return false;
  return true;
}

/// The same chat list for a started chat's composer: entry by entry the same object, or, for a chat
/// other than `shown`, the same chat with only its live fields (`OTHER_CHAT_LIVE`) changed.
export function sameSessions(
  a: readonly AcpmuxSessionEntry[],
  b: readonly AcpmuxSessionEntry[],
  shown: string | undefined,
): boolean {
  if (a === b) return true;
  if (a.length !== b.length) return false;
  for (let index = 0; index < a.length; index++) {
    const before = a[index]!;
    const after = b[index]!;
    if (before === after) continue;
    if (before.sessionId !== after.sessionId || before.sessionId === shown) return false;
    const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
    for (const key of keys)
      if (
        !OTHER_CHAT_LIVE.has(key) &&
        !Object.is(before[key as keyof AcpmuxSessionEntry], after[key as keyof AcpmuxSessionEntry])
      )
        return false;
  }
  return true;
}

/// Whether two views hold the same members (sameMember), key by key. A started chat's (one with rows)
/// `sessions` compare by `sameSessions`; a new chat's in full, since its folder strip and suggested
/// prompt (ComposerContext.tsx, promptSuggestion.ts) read the other chats' recency and pull requests.
export function sameComposerView(a: AcpmuxSnapshot, b: AcpmuxSnapshot): boolean {
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  const started = a.rows.length > 0 && b.rows.length > 0;
  for (const key of keys) {
    if (!Object.prototype.hasOwnProperty.call(b, key)) return false;
    if (key === "sessions" && started) {
      if (!sameSessions(a.sessions, b.sessions, a.sessionId)) return false;
      continue;
    }
    if (!sameMember(a[key as keyof AcpmuxSnapshot], b[key as keyof AcpmuxSnapshot])) return false;
  }
  return true;
}

/// The composer's view of `snapshot`: its rows cut to `composerRows`, its `connection` (which names
/// why the client emitted, a streamed event's kind among them; model.ts `linkUp`) to whether the link
/// is up, which is all the composer could read of it, and the turn's live fields (`TURN_LIVE`) left
/// out. The last view while it holds the same members (sameComposerView), so a snapshot that changed
/// only what the composer does not show leaves it be.
export function composerView(snapshot: AcpmuxSnapshot): AcpmuxSnapshot {
  const view: AcpmuxSnapshot = {
    ...snapshot,
    rows: composerRows(snapshot.rows),
    connection: linkUp(snapshot.connection) ? "connected" : snapshot.connection,
  };
  for (const key of TURN_LIVE) delete view[key];
  return view;
}

/// `composerView(snapshot)`, the last one returned while it holds the same members.
export function useComposerView(snapshot: AcpmuxSnapshot): AcpmuxSnapshot {
  const last = useRef<{ from: AcpmuxSnapshot; view: AcpmuxSnapshot } | undefined>(undefined);
  if (last.current?.from === snapshot) return last.current.view;
  const next = composerView(snapshot);
  const view = last.current && sameComposerView(last.current.view, next) ? last.current.view : next;
  last.current = { from: snapshot, view };
  return view;
}
