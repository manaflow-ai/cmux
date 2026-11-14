// The Agent Board page's ops (`AgentBoardPageProvider.swift`, namespace `cmux.agentBoard.`).
export const AgentBoardOps = {
  state: "cmux.agentBoard.state",
  setEnabled: "cmux.agentBoard.setEnabled",
  evidence: "cmux.agentBoard.evidence",
  open: "cmux.agentBoard.open",
  changes: "cmux.agentBoard.changes",
} as const;

/** One ledger file as the host reads it: newest first. */
export interface LedgerFile {
  file: string;
  modifiedMs: number;
  text: string;
  /** The file is larger than the host reads; the board shows its first part. */
  truncated: boolean;
}

export interface BoardState {
  enabled: boolean;
  /** The ledger folder, for the empty state. */
  folder: string;
  ledgers: LedgerFile[];
}

/** `cmux.agentBoard.evidence`: an image as a data URL, or too large to show. */
export type EvidenceImage = { dataURL: string } | { tooLarge: true; size: number };
