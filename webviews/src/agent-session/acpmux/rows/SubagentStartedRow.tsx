import { SubagentStartedLine } from "../subagents/SubagentStartedLine";
import type { RowProps } from "./rowProps";

export function SubagentStartedRow({ row }: RowProps) {
  return <SubagentStartedLine row={row} />;
}
