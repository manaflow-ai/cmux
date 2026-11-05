import { createContext } from "react";
import { type Translate } from "../i18n";
import type { TurnTokenSplit } from "../model";
import { TurnTokens } from "./TurnTokens";
import { formatDuration } from "./turns";

export const workingLabel = (t: Translate, at: number, now: number) =>
  t("turn.working", { time: formatDuration(Math.max(0, now - at)) });

/// What the running turn's line counts (App.tsx): the subagents, background commands and started
/// chats still running, and what opens each.
export type WorkingCounts = {
  agents: number;
  commands: number;
  sessions: number;
  openAgents: () => void;
  openCommands: () => void;
  openSessions: () => void;
  /// The turn's generated output tokens so far (snapshot `turnTokens`), when the harness reports them.
  tokens?: number;
  /// Those tokens split into output and what the calls read (snapshot `turnTokenSplit`), when known.
  split?: TurnTokenSplit;
};

export { workingTokens } from "./TurnTokens";

/// The running line's counts, each opening what it counts: the subagents and the chats the agent
/// started are one count, "3 subagents" (the tray's word, subagents/SubagentTray.tsx), then the
/// commands.
export function workingParts(t: Translate, counts: WorkingCounts): { key: string; label: string; open: () => void }[] {
  const subagents = counts.agents + counts.sessions;
  const parts = [
    subagents > 0 && {
      key: "agents",
      label: t("subagents.count", { n: subagents }),
      open: counts.agents > 0 ? counts.openAgents : counts.openSessions,
    },
    counts.commands > 0 && {
      key: "commands",
      label: t("turn.working.commands", { n: counts.commands }),
      open: counts.openCommands,
    },
  ];
  return parts.filter((part) => part !== false);
}

export const WorkingCountsContext = createContext<WorkingCounts | undefined>(undefined);
