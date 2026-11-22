// The agent status island's state (StatusIsland.tsx, experiment `agent-status-island`): how many
// agents run, which one needs the person, and whether the pill is compact or expanded. Nothing here
// is a store of its own: the asks are the Needs you items (needsYou/model.ts), which acpmux already
// reports, and the counts are the session list's indicators. An answer leaves the island the moment
// acpmux says it was answered, wherever it was answered.
import type { AcpmuxPermission } from "../model";
import type { NeedsYouItem, WatchedAsk } from "../needsYou/model";
import { activityTime, type AcpmuxSessionEntry } from "../sessionList";

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
  /// The attention item's permission request as acpmux reported it, when it is one: the card reads
  /// its command and title the way the permission card does (permissions/prompt.ts), so a command
  /// carried only in the title is still shown whole above Allow.
  permission?: AcpmuxPermission;
  /// The newest failed chat, shown when no ask is open.
  failure?: IslandFailure;
  /// The pill's mark: an ask outranks a failure, a failure outranks running work.
  tone: IslandTone;
  /// What the card would show, as a stable key: `ask:<item id>`, or `failed:<sessionId>:<when>` for
  /// one failure of a chat (its `activityAt`, which a new run moves and a warm or resume does not).
  /// A new key expands the pill by itself; the key the person collapsed stays collapsed while it
  /// lasts (islandToggle forgets it once it clears).
  focus?: string;
};

const failed = (entry: AcpmuxSessionEntry) =>
  !entry.archived && !entry.side && (entry.indicator === "failed" || entry.indicator === "lost");

export function islandState({
  sessions,
  items,
  asks = [],
}: {
  sessions: readonly AcpmuxSessionEntry[];
  /// The Needs you items, newest first (needsYouItems).
  items: readonly NeedsYouItem[];
  /// The pending permission requests the items were read from (the snapshot's `asks`).
  asks?: readonly WatchedAsk[];
}): IslandState {
  let running = 0;
  let failure: AcpmuxSessionEntry | undefined;
  for (const entry of sessions) {
    if (entry.archived || entry.side) continue;
    if (entry.indicator === "working") running += 1;
    // Newest failure by when the chat last did something (activityTime): a warm or resume moves
    // `updatedAt` and must not pick another failure or reopen the card.
    else if (failed(entry) && (activityTime(entry) ?? 0) >= (failure ? (activityTime(failure) ?? 0) : -1))
      failure = entry;
  }
  const attention = items.find((item) => islandAnswers(item).length > 0) ?? items[0];
  if (attention) {
    const permission = attention.permissionId
      ? asks.find((ask) => ask.permission.permissionId === attention.permissionId)?.permission
      : undefined;
    return {
      running,
      waiting: items.length,
      attention,
      ...(permission ? { permission } : {}),
      tone: "attention",
      focus: `ask:${attention.id}`,
    };
  }
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
      focus: `failed:${failure.sessionId}:${activityTime(failure) ?? ""}`,
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

/// The person's last press, kept only while what it was about is still on show: once the ask is
/// answered or the failure clears (another focus, or none), it is forgotten, so the same chat failing
/// again, even under a key that reads the same, opens its card again.
export function islandToggle(
  toggled: { focus: string; open: boolean } | undefined,
  focus: string | undefined,
): { focus: string; open: boolean } | undefined {
  return toggled && toggled.focus === focus ? toggled : undefined;
}

/// The one-click answers the card draws: an allow and a deny (tones), or a question's choices.
/// The allow comes first, as on the permission card. Held messages (an agent pair's Resume, a
/// guest's prompt to review) are answered on their own card: the island opens it instead.
export function islandAnswers(item: NeedsYouItem): NeedsYouItem["answers"] {
  if (item.kind === "held") return [];
  const rank = { allow: 0, choice: 1, deny: 2 } as const;
  return [...item.answers].sort((a, b) => rank[a.tone] - rank[b.tone]);
}
