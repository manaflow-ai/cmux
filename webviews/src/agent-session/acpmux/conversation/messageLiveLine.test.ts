// l10n-allow-file: test fixtures.
// A run of messages in a running turn: the one still going out is on the live line (turns.ts
// `codexRuns`), so the line, not a group, says who it goes to. The finished one draws no row while
// the turn runs (liveTurnWork.experiment.ts `line`, as chatgpt.com draws a running turn).
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";

const sendMessage = (id: string, to: string, status: string) => ({
  kind: "tool",
  text: "SendMessage",
  tool: { id, title: "SendMessage", kind: "other", status, inputSummary: JSON.stringify({ to, message: "go" }) },
});

test("the live line names the recipient of a SendMessage in flight", () => {
  const rows: AcpmuxRow[] = [
    { id: "p1", version: 1, at: 1_000, kind: "user", text: "Brief the picker lane" },
    {
      id: "a1",
      version: 1,
      at: 2_000,
      kind: "activity",
      items: [sendMessage("m1", "picker", "completed"), sendMessage("m2", "picker", "in_progress")],
    } as AcpmuxRow,
  ];
  const view = turnView(rows, new Set(), { now: 10_000, working: true });
  const line = view.find((row) => row.doingSendTo !== undefined);
  expect(line?.doingSendTo).toBe("picker");
  // Neither draws a row: the one in flight is only on the line, the finished one under Worked for
  // once the turn ends.
  const items = view.flatMap((row) => (row.kind === "activity" ? (row.items ?? []) : []));
  expect(items.map((item) => item.tool?.id)).toEqual([]);
});
