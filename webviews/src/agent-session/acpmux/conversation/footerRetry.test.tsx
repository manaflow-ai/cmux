// l10n-allow-file: test fixture replies and model names, not shipped UI.
// Retry, with its model switch, on the last turn's reply footer (TurnRows.tsx TurnFooter). Leo,
// 2026-11-04: "Today Retry is on your prompt bubble, and appears on the reply only after a failure.
// Put it, with the model switch, in the last turn's footer." The last turn's footer offers Retry
// after Copy whether the turn failed or not; an earlier turn's footer does not, and the prompt bubble
// draws none (test/user-message-actions.test.tsx).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { MARK_FOOTER_ROW, rowMark } from "../transcriptGrid";
import { TurnFooter } from "./TurnRows";
import { isEmptyFooter } from "./turns";
import { TurnActionsContext, type TurnActions } from "./turnActions";

const last: AcpmuxRow = {
  id: "summary",
  version: 1,
  at: 1_000,
  kind: "turnSummary",
  status: "completed",
  text: "Done.",
  answerId: "reply",
  retryable: true,
  prompt: "Cover it",
  retryRowId: "user-4",
};

const actions = (sent: unknown[][] = []): TurnActions => ({
  retry: (rowId, prompt) => sent.push(["retry", rowId, prompt]),
  retryWith: {
    models: [
      { id: "model-a", name: "Model A" },
      { id: "model-b", name: "Model B" },
    ],
    current: "model-a",
    retry: (rowId, prompt, model) => sent.push(["retryWith", rowId, prompt, model]),
  },
});

const draw = (row: AcpmuxRow, value: TurnActions = actions()) =>
  renderToStaticMarkup(
    <TurnActionsContext.Provider value={value}>
      <TurnFooter row={row} />
    </TurnActionsContext.Provider>,
  );

test("the last turn's footer offers Retry and its model switch right after Copy", () => {
  const markup = draw(last);
  const copy = markup.indexOf('aria-label="Copy"');
  const retry = markup.indexOf('aria-label="Retry"');
  const models = markup.indexOf("cv-turn-retry-menu");
  expect(copy).toBeGreaterThan(-1);
  expect(retry).toBeGreaterThan(copy);
  expect(models).toBeGreaterThan(retry);
  // One split control: Retry and its chevron in one group.
  expect(markup).toMatch(/<span class="cv-turn-retry"><button[^>]*aria-label="Retry"/);
});

test("an earlier turn's footer offers no Retry", () => {
  const markup = draw({ ...last, retryable: undefined, prompt: undefined, retryRowId: undefined });
  expect(markup).not.toContain('aria-label="Retry"');
  expect(markup).not.toContain("cv-turn-retry");
});

test("a chat that cannot send draws no Retry on its last footer", () => {
  expect(draw(last, {})).not.toContain('aria-label="Retry"');
});

test("one model draws Retry without the model switch", () => {
  const markup = draw(last, { ...actions(), retryWith: { models: [{ id: "a", name: "A" }], retry: () => {} } });
  expect(markup).toContain('aria-label="Retry"');
  expect(markup).not.toContain("cv-turn-retry-menu");
});

test("a failed last turn keeps its Retry and model switch in the same place", () => {
  const markup = draw({ ...last, status: "failed", error: "boom" });
  expect(markup).toMatch(/<span class="cv-turn-retry"><button[^>]*aria-label="Retry"/);
  expect(markup).toContain("cv-turn-retry-menu");
});

// A last turn of tool calls alone has nothing to copy, but it offers Retry, so its footer is a row
// of its own, not the hidden empty footer: else the chat would offer no Retry anywhere (cmux#34779).
test("a tool-only last turn's footer shows to carry its Retry", () => {
  const toolsOnly: AcpmuxRow = { ...last, text: undefined, answerId: undefined };
  expect(isEmptyFooter(toolsOnly)).toBe(false);
  expect(rowMark(toolsOnly)).toBe(MARK_FOOTER_ROW);
  const markup = draw(toolsOnly);
  expect(markup).not.toContain("cv-turn-actions--empty");
  expect(markup).toContain('aria-label="Retry"');
  // With nothing to send again (an earlier turn), it stays the hover-only empty footer.
  expect(isEmptyFooter({ ...toolsOnly, retryable: undefined, prompt: undefined, retryRowId: undefined })).toBe(true);
});
