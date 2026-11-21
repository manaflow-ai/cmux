// l10n-allow-file: transcript fixture text.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { layoutConversation, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { TurnFooter } from "../src/agent-session/acpmux/conversation/TurnRows";
import { TurnActionsContext } from "../src/agent-session/acpmux/conversation/turnActions";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

const footer = (fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: "end",
  kind: "turnSummary",
  at: 1000,
  version: 1,
  status: "completed",
  seq: 2,
  toolCount: 0,
  ...fields,
});
const render = (row: AcpmuxRow) =>
  renderToStaticMarkup(
    <TurnActionsContext.Provider value={{ fork: () => {}, forkAny: true, retryFailed: async () => undefined }}>
      <TurnFooter row={row} />
    </TurnActionsContext.Provider>,
  );

test("two Continue prompts with no agent output leave no orphan footer actions", () => {
  const rows: AcpmuxRow[] = [
    { id: "continue-1", kind: "user", at: 0, version: 1, text: "Continue" },
    footer({ id: "end-1" }),
    { id: "continue-2", kind: "user", at: 2000, version: 1, text: "Continue" },
    footer({ id: "end-2", at: 3000, seq: 4, status: "cancelled" }),
  ];
  const view = turnView(rows, new Set(), { agentFamily: "claude", now: 4000 });
  const summaries = view.filter((row) => row.kind === "turnSummary");
  expect(summaries).toHaveLength(2);
  for (const row of summaries) expect(render(row)).toBe("");
  expect(summaries.at(-1)?.resumable).toBe(true);
  const layout = layoutConversation(view, 760);
  for (const row of summaries) expect(layout.heights[view.indexOf(row)]).toBe(0);
});

test("reply and work-only turns retain their fork action", () => {
  const cases: Partial<AcpmuxRow>[] = [
    { text: "Done." },
    { toolCount: 1 },
    { changedFiles: true },
    { toolCount: undefined },
  ];
  for (const fields of cases) expect(render(footer(fields))).toContain('aria-label="Fork from here"');
});

test("an empty failed turn retains recovery", () => {
  expect(render(footer({ status: "failed", error: "network timeout", retryable: true }))).toContain(
    'aria-label="Retry"',
  );
});
