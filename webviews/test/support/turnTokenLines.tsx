// l10n-allow-file: test fixtures, not shipped UI.
// The two lines that say a running turn's tokens, at 35s and 679,900 tokens: the Codex layout's live
// line at the bottom (Thinking.tsx) and the line over the turn with that layout off (WorkingFor.tsx).
import type { ReactElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Thinking } from "../../src/agent-session/acpmux/conversation/Thinking";
import {
  WorkingCountsContext,
  WorkingFor,
  type WorkingCounts,
} from "../../src/agent-session/acpmux/conversation/WorkingFor";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";

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

export const tokenLines: Record<string, ReactElement> = {
  "the live line at the bottom (Thinking.tsx)": <Thinking since={START} now={now} below />,
  "the line over the turn (WorkingFor.tsx)": <WorkingFor row={working} now={now} />,
};

export const tokenLineMarkup = (line: ReactElement) =>
  renderToStaticMarkup(<WorkingCountsContext.Provider value={counts}>{line}</WorkingCountsContext.Provider>);
