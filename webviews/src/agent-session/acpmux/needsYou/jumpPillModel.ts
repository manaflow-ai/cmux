import type { AcpmuxSessionEntry } from "../sessionList";
import type { NeedsYouItem } from "./model";

export function needsYouPillOn(
  root: { dataset: DOMStringMap } | undefined = globalThis.document?.documentElement,
): boolean {
  return root?.dataset.needsYouPill !== "off";
}

/// The asks the pill speaks for in chat `sessionId`: its own, and those of the chats it started
/// (acpmux `startedBy` for a sub-session, `spawnedBy` for a chat its agent made), at any depth, the
/// agents its tray lists. Never another chat's: the person did not ask for it here and may not be
/// able to answer it from here (another computer's chat), so it stays in the header's list.
export function pillAsks(
  items: readonly NeedsYouItem[],
  sessions: readonly Pick<AcpmuxSessionEntry, "sessionId" | "startedBy" | "spawnedBy">[],
  sessionId: string | undefined,
): NeedsYouItem[] {
  if (!sessionId) return [];
  const byId = new Map(sessions.map((session) => [session.sessionId, session]));
  const ours = new Map<string, boolean>([[sessionId, true]]);
  const isOurs = (id: string): boolean => {
    const known = ours.get(id);
    if (known !== undefined) return known;
    // Walk up the chat's starters; a loop of links (or a chat not listed) is not ours.
    const seen: string[] = [];
    let at: string | undefined = id;
    let found = false;
    while (at !== undefined && !seen.includes(at)) {
      const cached = ours.get(at);
      if (cached !== undefined) {
        found = cached;
        break;
      }
      seen.push(at);
      const session = byId.get(at);
      at = session?.startedBy ?? session?.spawnedBy;
    }
    for (const each of seen) ours.set(each, found);
    return found;
  };
  return items.filter((item) => isOurs(item.sessionId));
}

/// The order a press visits asks in: this chat's first, then the others, newest first.
export function pillOrder(items: readonly NeedsYouItem[], sessionId: string | undefined): NeedsYouItem[] {
  const here = items.filter((item) => item.sessionId === sessionId);
  return [...here, ...items.filter((item) => item.sessionId !== sessionId)];
}

/// The next ask a press goes to: with `behind`, the press already jumped to this chat's own ask, so
/// it stays; else the next ask elsewhere after `last` (the one the previous press went to).
export function nextAsk(
  items: readonly NeedsYouItem[],
  sessionId: string | undefined,
  behind: boolean,
  last: string | undefined,
): NeedsYouItem | undefined {
  const order = pillOrder(items, sessionId);
  if (behind && order[0]?.sessionId === sessionId) return undefined;
  const away = order.filter((item) => item.sessionId !== sessionId);
  if (away.length === 0) return undefined;
  const at = away.findIndex((item) => item.id === last);
  return away[(at + 1) % away.length];
}
