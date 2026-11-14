import { memo } from "react";
import { AgentPairNote } from "../conversation/AgentPairNote";
import { type RowProps } from "./rowProps";

export const ReadOnlyAgentPairRow = memo(
  function ReadOnlyAgentPairRow({ row }: RowProps) {
    return row.agentPair ? <AgentPairNote pair={row.agentPair} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
