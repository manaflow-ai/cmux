import type { PageClient } from "../shared/pageClient";

export type RawRange = { start: number; end: number; position: "before" | "after" };
export type RawSection = RawRange & { pageEnd: number; completeThrough?: number };
export type RawChunk = { text: string; nextOffset: number | null };

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
  turnIndex?: number;
  raw?: RawSection;
};

export type TranscriptPage = {
  key: string;
  title: string;
  createdMs: number;
  updatedMs: number;
  turns: TranscriptTurn[];
  rawRanges?: RawRange[];
  completeThrough?: number;
  before: number | null;
  pageEnd?: number;
};

type TextHit = {
  pageEnd: number;
  turn: number;
  role: "user" | "assistant" | "tool";
  snippet: string;
};

export type TranscriptHit =
  | TextHit
  | {
      pageEnd: number;
      role: "raw";
      rawStart: number;
      rawEnd: number;
      rawOffset: number;
      completeThrough?: number;
      snippet: string;
    };

export function hitTurn(hit: TranscriptHit): number {
  return hit.role === "raw" ? -1 - hit.rawStart : hit.turn;
}

export type TranscriptFindResult = {
  hits: TranscriptHit[];
  before: number | null;
  completeThrough?: number;
};

export type TranscriptProvider = Pick<PageClient, "call">;

export const TERMINAL_HISTORY_PAGE = "cmux.terminal_history.page";
export const TERMINAL_HISTORY_FIND = "cmux.terminal_history.find";
