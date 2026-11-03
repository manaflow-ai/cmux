// l10n-allow-file: test fixtures, not shipped UI.
// The two lines that say a running turn's tokens, at 35s and 679,900 output tokens: the Codex layout's live
// line at the bottom (Thinking.tsx) and the line over the turn with that layout off (WorkingFor.tsx).
import type { ReactElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Thinking } from "../../src/agent-session/acpmux/conversation/Thinking";
import {
  WorkingCountsContext,
  WorkingFor,
  type WorkingCounts,
} from "../../src/agent-session/acpmux/conversation/WorkingFor";
import type { AcpmuxRow, TurnTokenSplit } from "../../src/agent-session/acpmux/model";

const START = Date.UTC(2026, 9, 21, 9, 0, 0);
const now = () => START + 35_000;
const counts: WorkingCounts = {
  agents: 0,
  commands: 0,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
  tokens: 679_900,
};
const working: AcpmuxRow = { id: "working", kind: "working", version: 1, at: START };

/// The lines that draw the count in their text. The live line at the bottom (Thinking.tsx) keeps it
/// in its hover instead (`thinkingLine`): in the transcript the counts read as debug noise.
export const tokenLines: Record<string, ReactElement> = {
  "the line over the turn (WorkingFor.tsx)": <WorkingFor row={working} now={now} />,
};

/// The Codex layout's live line at the bottom, at 35s.
export const thinkingLine: ReactElement = <Thinking since={START} now={now} below />;

/// A turn's tokens split as acpmux reports them: 12.4K out, 2.1M read.
export const SPLIT: TurnTokenSplit = { output: 12_400, input: 18_000, cacheRead: 2_080_000, cacheWrite: 42_000 };

/// `line` drawn with the turn's tokens: its output alone, or (`split`) that output with what the
/// calls read, the count then being the split's output as direct.ts keeps it.
export const tokenLineMarkup = (line: ReactElement, split?: TurnTokenSplit) =>
  renderToStaticMarkup(
    <WorkingCountsContext.Provider value={split ? { ...counts, tokens: split.output, split } : counts}>
      {line}
    </WorkingCountsContext.Provider>,
  );
