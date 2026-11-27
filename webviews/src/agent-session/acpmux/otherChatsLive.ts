// What a shown chat's pane can leave undrawn of another chat that runs (Leo, 2026-11-25: "the app
// speed on idle and on load we need to be better"). A running agent changes its chat's times and its
// latest words on each of its events; every shown pane hears them, and each one drew the whole pane
// again at most twice a second (direct.ts `drawOtherChats`): about 13 ms of render a time with 200
// listed chats, for a pane that draws none of those fields of an unrelated chat. The few views that do
// read them (a chat's hover card, the sub-session cards, the Steer queue while open, the picker's
// "last worked" order) read the newest list from the client's live hand-off instead
// (`AcpmuxDirectClient.onOtherChatsLive`), and the next snapshot carries it to everything else.
import { findSession } from "./sessionIndex";
import { sameValue } from "./session-info/sameValue";
import type { AcpmuxSessionEntry } from "./sessionList";

/// The fields another chat changes on each of its events while it runs: its times and its latest
/// words. Its status, dot, unread mark, asks and pull request change at a turn's edges and still draw.
const OTHER_CHAT_TICK: ReadonlySet<string> = new Set<keyof AcpmuxSessionEntry>([
  "updatedAt",
  "activityAt",
  "preview",
  "lastMessage",
]);

/// How far up a chat's starters are followed to tell whether the shown chat started it.
const MAX_DEPTH = 32;

/// Whether `entry` is the shown chat or one it started, at any depth (its sub-session cards and
/// Subagents list draw those chats' latest words).
function inShownTree(entry: AcpmuxSessionEntry, list: readonly AcpmuxSessionEntry[], shown: string): boolean {
  let at: AcpmuxSessionEntry | undefined = entry;
  for (let depth = 0; at && depth < MAX_DEPTH; depth++) {
    if (at.sessionId === shown) return true;
    const parent: string | undefined = at.startedBy ?? at.spawnedBy;
    if (!parent || parent === at.sessionId) return false;
    if (parent === shown) return true;
    at = findSession(list, parent);
  }
  return false;
}

/// Whether `after` differs from `before` (the list the shown chat last drew) only in chats outside
/// the shown chat's tree, and in those only in the fields they change on each event (OTHER_CHAT_TICK).
export function onlyOtherChatsTicked(
  before: readonly AcpmuxSessionEntry[],
  after: readonly AcpmuxSessionEntry[],
  shown: string | undefined,
): boolean {
  if (!shown) return false;
  if (before === after) return true;
  if (before.length !== after.length) return false;
  for (let index = 0; index < after.length; index++) {
    const was = before[index]!;
    const now = after[index]!;
    if (was === now) continue;
    if (was.sessionId !== now.sessionId || now.sessionId === shown) return false;
    if (inShownTree(now, after, shown) || inShownTree(was, before, shown)) return false;
    for (const key of new Set([...Object.keys(was), ...Object.keys(now)]))
      if (
        !OTHER_CHAT_TICK.has(key) &&
        !sameValue(was[key as keyof AcpmuxSessionEntry], now[key as keyof AcpmuxSessionEntry])
      )
        return false;
  }
  return true;
}
