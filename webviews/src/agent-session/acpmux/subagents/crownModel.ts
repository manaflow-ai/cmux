// Pure grouping and lead-selection model for the Leading Pair composer crown (SubagentTray.tsx).
// Filters out finished silent turns, separates subagents (and subagent sessions) from background
// commands, picks the longest-running active item as lead so bursts never thrash the header title,
// caps corner icon sub-badges at 9+, and flattens the open list with no divider between groups.
import { itemStart, type TrayItem } from "./runningTray";
import type { TrayCard } from "./trayAttention";

export type CrownGroups = {
  /** Subagents and started chats, running first. */
  readonly agents: readonly TrayCard[];
  /** Background commands and active turns, running first. */
  readonly commands: readonly TrayCard[];
  /** Currently running (non-finished) subagents and started chats. */
  readonly agentsRunning: number;
  /** Currently running (non-finished) background commands. */
  readonly commandsRunning: number;
  /** Lead subagent for the subagent icon sub-badge (longest-running active, else first). */
  readonly leadAgent: TrayCard | undefined;
  /** Lead command for the command icon sub-badge (longest-running active, else first). */
  readonly leadCommand: TrayCard | undefined;
  /** Lead item whose title and clock appear in the crown bar. */
  readonly lead: TrayCard | undefined;
  /** Flat open list: subagents then commands, no divider between them. */
  readonly flatList: readonly TrayCard[];
  /** Whether any item in the crown is still running. */
  readonly anyRunning: boolean;
  /** True when exactly one visible item exists: renders the direct-click single-item crown. */
  readonly isSingle: boolean;
  /** False when empty or only finished silent turns (e.g. compaction). */
  readonly hasVisibleWork: boolean;
};

/** Caps corner sub-badge counts at 9+ so the 14px pill stays compact. */
export function formatCrownBadge(count: number): string {
  return count > 9 ? "9+" : String(count);
}

export function isCommandGroupItem(item: TrayItem): boolean {
  return item.kind === "command" || item.kind === "turn";
}

/** Longest-running active card (earliest start timestamp), falling back to the first card. */
function longestRunningLead(cards: readonly TrayCard[]): TrayCard | undefined {
  let best: TrayCard | undefined;
  let bestStart = Number.POSITIVE_INFINITY;
  for (const card of cards) {
    if (card.finished) continue;
    const start = itemStart(card.item);
    if (best === undefined) {
      best = card;
      bestStart = start ?? Number.POSITIVE_INFINITY;
      continue;
    }
    if (start !== undefined && start < bestStart) {
      best = card;
      bestStart = start;
    }
  }
  return best ?? cards[0];
}

/**
 * Splits `cards` (already ordered running-before-finished) into the Leading Pair crown's groups.
 * Finished silent turns (e.g. background compaction) are excluded so they never produce a stray
 * terminal badge or empty hat. `lead` selects the longest-running active subagent (or command) so
 * newly spawned items never thrash the header's title and clock.
 */
export function crownGroups(cards: readonly TrayCard[]): CrownGroups {
  const agents: TrayCard[] = [];
  const commands: TrayCard[] = [];
  let agentsRunning = 0;
  let commandsRunning = 0;

  for (const card of cards) {
    if (card.item.kind === "turn" && card.finished) continue;
    if (isCommandGroupItem(card.item)) {
      commands.push(card);
      if (!card.finished) commandsRunning += 1;
    } else {
      agents.push(card);
      if (!card.finished) agentsRunning += 1;
    }
  }

  const leadAgent = longestRunningLead(agents);
  const leadCommand = longestRunningLead(commands);
  const lead = agentsRunning > 0 ? leadAgent : commandsRunning > 0 ? leadCommand : (leadAgent ?? leadCommand);
  const visibleCount = agents.length + commands.length;

  return {
    agents,
    commands,
    agentsRunning,
    commandsRunning,
    leadAgent,
    leadCommand,
    lead,
    flatList: [...agents, ...commands],
    anyRunning: agentsRunning + commandsRunning > 0,
    isSingle: visibleCount === 1,
    hasVisibleWork: visibleCount > 0,
  };
}
