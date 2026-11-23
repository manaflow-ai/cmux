// l10n-allow-file: test fixtures, not shipped UI.
// Both live-line layouts receive nonzero usage data but display elapsed time without token amounts.
import type { ReactElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Thinking } from "../../src/agent-session/acpmux/conversation/Thinking";
import { WorkingFor } from "../../src/agent-session/acpmux/conversation/WorkingFor";
import { WorkingCountsContext, type WorkingCounts } from "../../src/agent-session/acpmux/conversation/workingForModel";
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
const working: AcpmuxRow = { id: "working", kind: "working", version: 1, at: START, below: true };

export const tokenLines: Record<string, ReactElement> = {
  "the live line at the bottom (Thinking.tsx)": <Thinking since={START} now={now} below />,
  "the line under the work (WorkingFor.tsx)": <WorkingFor row={working} now={now} />,
};

/// A turn's tokens split as acpmux reports them: 12.4K out, 2.1M read.
export const SPLIT: TurnTokenSplit = { output: 12_400, input: 18_000, cacheRead: 2_080_000, cacheWrite: 42_000 };

/// Supply live usage data to verify it does not add a token counter to either line.
export const tokenLineMarkup = (line: ReactElement, split?: TurnTokenSplit) =>
  renderToStaticMarkup(
    <WorkingCountsContext.Provider value={split ? { ...counts, tokens: split.output, split } : counts}>
      {line}
    </WorkingCountsContext.Provider>,
  );
