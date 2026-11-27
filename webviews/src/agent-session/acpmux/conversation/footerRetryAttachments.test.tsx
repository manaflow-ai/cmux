// l10n-allow-file: test fixture replies, not shipped UI.
// Attachment-only prompts retain row identity for safe resend; failed recovery restores their
// attachments, while unsafe attachments have no fallback.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { TurnFooter } from "./TurnRows";
import { offersRetry, retryTargetIn, turnView } from "./turns";
import { RetryTargetContext, TurnActionsContext, type TurnActions } from "./turnActions";
import { UserBubble } from "./UserBubble";

const actions: TurnActions = { retry: () => {} };
const image = { id: "image-1", mimeType: "image/png", name: "screenshot.png" };
const imageOnly: AcpmuxRow = { id: "p1", version: 1, at: 10, kind: "user", images: [image] };
const unsendable: AcpmuxRow = {
  id: "p1",
  version: 1,
  at: 10,
  kind: "user",
  inlineParts: [{ kind: "file", name: "notes.txt", mimeType: "text/plain", size: 12 }],
};
const A = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "assistant", text });
const S = (id: string, at: number, status = "completed"): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "turnSummary",
  status,
});

/// Where each drawn row shows a Retry button in the transcript: "footer:<id>" or "prompt:<id>".
function retries(source: AcpmuxRow[]): { shown: string[]; rows: AcpmuxRow[] } {
  const rows = turnView(source, new Set(), { now: 1_000 });
  const target = retryTargetIn(rows);
  const shown: string[] = [];
  for (const row of rows) {
    const node =
      row.kind === "turnSummary" ? (
        <TurnFooter row={row} />
      ) : row.kind === "user" ? (
        <UserBubble row={row} text={row.text ?? ""} />
      ) : undefined;
    if (!node) continue;
    const markup = renderToStaticMarkup(
      <TurnActionsContext.Provider value={actions}>
        <RetryTargetContext.Provider value={target}>{node}</RetryTargetContext.Provider>
      </TurnActionsContext.Provider>,
    );
    if (markup.includes('aria-label="Retry"')) shown.push(`${row.kind === "user" ? "prompt" : "footer"}:${row.id}`);
  }
  return { shown, rows };
}

test("an attachment-only completed prompt retains the resend target without inline Retry", () => {
  const { shown, rows } = retries([imageOnly, A("a1", 20, "It shows a chart."), S("s1", 30)]);
  expect(shown).toEqual([]);
  const footer = rows.find((row) => row.kind === "turnSummary")!;
  expect(offersRetry(footer)).toBe(true);
  expect(footer.retryRowId).toBe("p1");
  expect(footer.prompt).toBe("");
});

test("an attachment-only last prompt whose attachments cannot be resent offers no Retry", () => {
  const { shown, rows } = retries([unsendable, A("a1", 20, "Read it."), S("s1", 30)]);
  expect(shown).toEqual([]);
  const footer = rows.find((row) => row.kind === "turnSummary")!;
  expect(offersRetry(footer)).toBe(false);
  expect(footer.prompt).toBeUndefined();
});

test("a failed attachment-only turn keeps its attachment-aware footer recovery", () => {
  const { shown, rows } = retries([imageOnly, A("a1", 20, "Partial."), S("s1", 30, "failed")]);
  const footer = rows.find((row) => row.kind === "turnSummary")!;
  expect(footer.prompt).toBe("");
  expect(footer.retryRowId).toBe("p1");
  expect(shown).toEqual(["footer:s1"]);
});
