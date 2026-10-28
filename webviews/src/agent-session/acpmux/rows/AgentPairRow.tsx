// The `agentPair` row: a paused agent pair.
import { memo } from "react";
import { AgentPairNote } from "../conversation/AgentPairNote";
import { resumeAgentPair } from "./rowActions";
import type { RowProps } from "./rowProps";

export const AgentPairRow = memo(
  function AgentPairRow({ row }: RowProps) {
    return row.agentPair ? <AgentPairNote pair={row.agentPair} onResume={resumeAgentPair} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
