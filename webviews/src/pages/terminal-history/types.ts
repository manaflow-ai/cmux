import type { PageClient } from "../shared/pageClient";

export type TranscriptTool = { title: string };

export type TranscriptTurn = {
  prompt: string;
  answer: string;
  promptAt?: number;
  answerAt?: number;
  tools: TranscriptTool[];
  truncated?: boolean;
  promptMore?: number;
  answerMore?: number;
  pageEnd?: number;
};

export type TranscriptPage = {
  key: string;
  title: string;
  createdMs: number;
  updatedMs: number;
  turns: TranscriptTurn[];
  before: number | null;
  pageEnd?: number;
};

export type TranscriptHit = {
  pageEnd: number;
  turn: number;
  role: "user" | "assistant" | "tool";
  snippet: string;
};

export type TranscriptFindResult = { hits: TranscriptHit[]; before: number | null };

export type TranscriptProvider = Pick<PageClient, "call">;

export const TERMINAL_HISTORY_PAGE = "cmux.terminal_history.page";
export const TERMINAL_HISTORY_FIND = "cmux.terminal_history.find";
