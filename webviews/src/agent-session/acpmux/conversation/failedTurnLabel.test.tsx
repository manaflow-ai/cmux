// l10n-allow-file: test fixture error text, not shipped UI.
// A turn that ended on an API error reads as failed, never as "Worked for Ns" (Leo's coordinator
// looped on 429s for hours and every dead turn said "Worked for"; acpmux records the turn as
// `status: "failed"` with its `errorText`, so the pane has everything it needs).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { translate, type Translate } from "../i18n";
import { footerLabel, isFailed, turnTimeKey, workedLabel } from "./turns";
import { TurnFooter, WorkedFor } from "./TurnRows";

const t: Translate = (key, values) => translate(key, values, "en");

/// A turn acpmux ended on the 429 Leo's coordinator hit, as it records it (`turn_result` with
/// status "failed", its `errorText` the harness's words).
const RATE_LIMIT =
  "API Error: Request rejected (429) · This request would exceed your account's rate limit. Please try again later.";

const row = (fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: "summary",
  version: 1,
  at: 1_000,
  kind: "turnSummary",
  status: "failed",
  durationMs: 15_000,
  error: RATE_LIMIT,
  ...fields,
});

test("a failed turn's line says it failed, not that it worked", () => {
  const failed = row();
  expect(isFailed(failed)).toBe(true);
  expect(workedLabel(t, failed)).not.toContain("Worked for");
  expect(footerLabel(t, failed)).not.toContain("Worked for");
  // The time is still there: how long it ran before it died is the news.
  expect(workedLabel(t, failed)).toContain("15s");
});

test("every turn end reads as what it was", () => {
  expect(workedLabel(t, row({ status: "completed" }))).toContain("Worked for 15s");
  expect(workedLabel(t, row({ status: "cancelled" }))).toContain("You stopped after 15s");
  expect(workedLabel(t, row({ status: "error" }))).not.toContain("Worked for");
});

test("the disclosure a reader sees over a failed turn does not say Worked for", () => {
  const markup = renderToStaticMarkup(<WorkedFor row={row()} expanded={false} onToggle={() => {}} />);
  expect(markup).not.toContain("Worked for");
});

test("a failed turn shows its error text as the turn's result", () => {
  const markup = renderToStaticMarkup(<TurnFooter row={row()} />);
  // The card names the cause in its own words; the agent's raw line is reachable under Details.
  expect(markup).toContain("429");
});

/// The gallery state that shows the symptom has to actually show it. A first version of
/// `failed-run` held only prompts and summaries, and the time's line draws only over a turn with
/// work to fold, so the state rendered no "Failed after" at all (caught in review of #44475).
test("the failed-run gallery state's turns each have work to fold, so the label draws", async () => {
  const entry = (await import("./turnErrorCard.gallery")).default;
  const rows = entry.variants["failed-run"]?.snapshot?.rows ?? [];
  const failedTurns = rows.filter((r) => r.kind === "turnSummary");
  expect(failedTurns.length).toBeGreaterThan(1);
  for (const turn of failedTurns) {
    expect(turnTimeKey(turn)).toBe("turn.failedAfter");
    // What makes the disclosure draw at all: the turn folds work.
    expect(turn.toolCount ?? 0).toBeGreaterThan(0);
  }
  expect(rows.some((r) => r.kind === "activity")).toBe(true);
});
