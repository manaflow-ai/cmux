// The agent status island's state (StatusIsland.tsx, experiment `agent-status-island`): how many
// agents run, which one needs the person, and whether the pill is compact or expanded. Nothing here
// is a store of its own: the asks are the Needs you items (needsYou/model.ts), which acpmux already
// reports, and the counts are the session list's indicators. An answer leaves the island the moment
// acpmux says it was answered, wherever it was answered.
import type { NeedsYouItem } from "../needsYou/model";
import type { AcpmuxSessionEntry } from "../sessionList";

/// A chat whose agent stopped on an error: acpmux's `failed` dot, or `lost` (its machine is gone).
export type IslandFailure = { sessionId: string; name: string; harness?: string; error?: string };

export type IslandTone = "idle" | "running" | "attention" | "error";

export type IslandState = {
  /// Agents whose turn is running now (the `working` dot), archived chats aside.
  running: number;
  /// Every open ask (the Needs you list's length).
  waiting: number;
  /// The ask the expanded card shows: the newest one with one-click answers, else the newest ask.
  attention?: NeedsYouItem;
  /// The newest failed chat, shown when no ask is open.
  failure?: IslandFailure;
  /// The pill's mark: an ask outranks a failure, a failure outranks running work.
  tone: IslandTone;
  /// What the card would show, as a stable key: `ask:<item id>` or `failed:<sessionId>`. A new key
  /// expands the pill by itself; the key the person collapsed stays collapsed.
  focus?: string;
};

const failed = (entry: AcpmuxSessionEntry) =>
  !entry.archived && !entry.side && (entry.indicator === "failed" || entry.indicator === "lost");

export function islandState({
  sessions,
  items,
}: {
  sessions: readonly AcpmuxSessionEntry[];
  /// The Needs you items, newest first (needsYouItems).
  items: readonly NeedsYouItem[];
}): IslandState {
  let running = 0;
  let failure: AcpmuxSessionEntry | undefined;
  for (const entry of sessions) {
    if (entry.archived || entry.side) continue;
    if (entry.indicator === "working") running += 1;
    else if (failed(entry) && (entry.updatedAt ?? 0) >= (failure?.updatedAt ?? -1)) failure = entry;
  }
  const attention = items.find((item) => islandAnswers(item).length > 0) ?? items[0];
  if (attention) return { running, waiting: items.length, attention, tone: "attention", focus: `ask:${attention.id}` };
  if (failure)
    return {
      running,
      waiting: 0,
      failure: {
        sessionId: failure.sessionId,
        name: failure.displayTitle ?? failure.title ?? failure.name ?? failure.sessionId,
        ...(failure.harness ? { harness: failure.harness } : {}),
        ...(failure.laneError ? { error: failure.laneError } : {}),
      },
      tone: "error",
      focus: `failed:${failure.sessionId}`,
    };
  return { running, waiting: 0, tone: running > 0 ? "running" : "idle" };
}

/// Whether the pill shows its card. `toggled` is the person's last press: `open` on a focus key
/// they expanded, `closed` on one they collapsed. With no press on the current key, a card that has
/// something to show opens by itself; with nothing to show the pill is compact.
export function islandExpanded(state: IslandState, toggled?: { focus: string; open: boolean }): boolean {
  if (!state.focus) return false;
  if (toggled?.focus === state.focus) return toggled.open;
  return true;
}

/// The one-click answers the card draws: an allow and a deny (tones), or a question's choices.
/// The allow comes first, as on the permission card. Held messages (an agent pair's Resume, a
/// guest's prompt to review) are answered on their own card: the island opens it instead.
export function islandAnswers(item: NeedsYouItem): NeedsYouItem["answers"] {
  if (item.kind === "held") return [];
  const rank = { allow: 0, choice: 1, deny: 2 } as const;
  return [...item.answers].sort((a, b) => rank[a.tone] - rank[b.tone]);
}
