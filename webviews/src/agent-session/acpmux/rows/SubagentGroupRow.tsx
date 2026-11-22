import { memo } from "react";
import { AgentRunTranscriptCard } from "../subagents/AgentRunCard";
import { isRunGroup } from "../subagents/subagentRows";
import { SubagentGroupHeader } from "../subagents/SubagentGroup";
import { type RowProps } from "./rowProps";

/// A batch of subagents (subagents/SubagentGroup.tsx); opening it lists them below.
export const SubagentGroupRow = memo(
  function SubagentGroupRow({ row, onToggleActivity, expanded, sessionId }: RowProps) {
    // An agent a shell call started (`codex exec`) draws as its own card where it started.
    if (isRunGroup(row)) return <AgentRunTranscriptCard agent={row.subagents![0]!} sessionId={sessionId} />;
    return <SubagentGroupHeader row={row} expanded={expanded} onToggle={() => onToggleActivity(row.id)} />;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.expanded === b.expanded &&
    a.onToggleActivity === b.onToggleActivity &&
    a.sessionId === b.sessionId,
);
