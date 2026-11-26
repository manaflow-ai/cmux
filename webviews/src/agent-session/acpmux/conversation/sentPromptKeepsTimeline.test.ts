// l10n-allow-file: test fixture text, not shipped UI.
// A prompt just sent sorts into the ended turn before it until acpmux accepts it, and the chat reads as
// working from the send: that turn is shaped as live for the window. Its footer keeps its Timeline
// through it, so the footer's buttons hold still when Enter goes (Leo, 2026-11-25: "layout shifts and
// awkward looking animations").
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});

const ended = (): AcpmuxRow[] => {
  at = 0;
  return [
    row("prompt", "user", { text: "Look at the helper" }),
    row("work", "activity", {
      items: [{ kind: "thought", text: "Reading it first.", startedAt: 1_500, endedAt: 2_500 }],
    }),
    row("reply", "assistant", { text: "Done." }),
    row("summary", "turnSummary", { status: "completed", durationMs: 3_000 }),
  ];
};

const footerWork = (rows: AcpmuxRow[], working: boolean) =>
  turnView(rows, new Set(), { working }).find((entry) => entry.id === "summary")?.turnWork?.length ?? 0;

test("an ended turn's footer keeps its Timeline while a prompt sent after it waits to be accepted", () => {
  const rows = ended();
  const settled = footerWork(rows, false);
  expect(settled).toBeGreaterThan(0);
  const sent = [...rows, row("next", "user", { text: "Now fix it", pending: true })];
  expect(footerWork(sent, true)).toBe(settled);
  const accepted = [...rows, { ...sent.at(-1)!, pending: undefined }];
  expect(footerWork(accepted, true)).toBe(settled);
});
