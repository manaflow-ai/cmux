// The asks of the sub-sessions below the shown chat, drawn in that chat (cmuxterm-hq#7794 #7: a
// subagent's ask showed only in its own chat and the Chief, so the run stalled where nobody looked).
// They come from the asks every chat holds open (needsYou/asks.ts); a sub-session is one acpmux
// lists with `startedBy`, at any depth. Only those: acpmux answers a person's answer sent to the
// shown chat for an ask pending in an open sub-session below it (acpmux server/requests.rs
// `route_ask_below`), so the card answers through the shown chat as its own asks do, keys included.
// A chat its agent made another way (`spawnedBy`) is not answered so and stays in Needs you.
import type { AcpmuxSessionEntry } from "../sessionList";
import type { WatchedAsk } from "../needsYou/model";

/// One ask below the shown chat, and the sub-session that asked: its name and whether it is a
/// direct child (`Sub-session · tests`) or further down (`Related · lint`).
export type ChildAsk = {
  readonly ask: WatchedAsk;
  readonly name: string;
  readonly direct: boolean;
  /// The sub-session's harness, for its card's wording.
  readonly harness?: string;
};

type Listed = Pick<
  AcpmuxSessionEntry,
  "sessionId" | "startedBy" | "shortName" | "displayTitle" | "name" | "peer" | "harness"
>;

/// The asks of the open sub-sessions below `sessionId`, oldest first: the first is the one its card
/// shows, the rest wait behind it. Never the chat's own asks (its own card has them) and never a
/// chat on another computer (its asks are answered there).
export function childAsks(
  asks: readonly WatchedAsk[],
  sessions: readonly Listed[],
  sessionId: string | undefined,
): ChildAsk[] {
  if (!sessionId || asks.length === 0) return [];
  const byId = new Map(sessions.map((session) => [session.sessionId, session]));
  const out: ChildAsk[] = [];
  for (const ask of asks) {
    if (ask.sessionId === sessionId) continue;
    const session = byId.get(ask.sessionId);
    if (!session || session.peer) continue;
    const depth = depthBelow(byId, ask.sessionId, sessionId);
    if (depth === undefined) continue;
    out.push({
      ask,
      name: session.shortName ?? session.displayTitle ?? session.name ?? ask.sessionId,
      direct: depth === 1,
      ...(session.harness ? { harness: session.harness } : {}),
    });
  }
  return out.sort((a, b) => a.ask.at - b.ask.at);
}

/// How many `startedBy` steps lead from `id` up to `ancestor`; undefined when none do (another
/// family, a loop of links, or a starter not listed).
function depthBelow(byId: ReadonlyMap<string, Listed>, id: string, ancestor: string): number | undefined {
  const seen = new Set<string>();
  let at: string | undefined = byId.get(id)?.startedBy;
  let depth = 1;
  while (at !== undefined && !seen.has(at)) {
    if (at === ancestor) return depth;
    seen.add(at);
    at = byId.get(at)?.startedBy;
    depth++;
  }
  return undefined;
}
