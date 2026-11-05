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
import { isEmptyFooter, offersRetry, turnViewFrom } from "./turns";
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
  retryTarget: true,
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

// A turn a notification started has no prompt to send again, so Retry stays with the person's last
// prompt, on its own turn's footer, as the prompt's Retry stayed under it before (cmux#34779). Once
// the person sends another prompt, Retry moves to that turn, also when the view builds on the last.
test("Retry stays on the person's last prompt's footer when a notification's turn follows", () => {
  const prompt = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "user", text });
  const reply = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "assistant", text });
  const summary = (id: string, at: number): AcpmuxRow => ({
    id,
    version: 1,
    at,
    kind: "turnSummary",
    status: "completed",
  });
  const notice: AcpmuxRow = {
    id: "n",
    version: 1,
    at: 40,
    kind: "user",
    text: "<task-notification>done</task-notification>",
    incoming: { kind: "notice", text: "Build finished" },
  };
  const rows = [
    prompt("p1", 10, "Fix the grid"),
    reply("a1", 20, "Fixed."),
    summary("s1", 30),
    notice,
    reply("a2", 50, "The build is done."),
    summary("s2", 60),
  ];
  const view = turnViewFrom(rows, new Set(), { now: 100 });
  const footers = view.rows.filter((row) => row.kind === "turnSummary");
  expect(footers.map(offersRetry)).toEqual([true, false]);
  expect(footers[0]!.prompt).toBe("Fix the grid");
  const next = [...rows, prompt("p2", 70, "Now the header"), reply("a3", 80, "Done."), summary("s3", 90)];
  const built = turnViewFrom(next, new Set(), { now: 100 }, view);
  expect(built.rows.filter((row) => row.kind === "turnSummary").map(offersRetry)).toEqual([false, false, true]);
});

// A suggested task's result acpmux sent into the chat (`received`) is not the person's prompt
// (direct.ts), so its turn's footer never resends it: Retry stays with the person's last prompt.
test("a task result's turn offers no Retry; the person's last prompt keeps it", () => {
  const rows: AcpmuxRow[] = [
    { id: "p1", version: 1, at: 10, kind: "user", text: "Fix the grid" },
    { id: "a1", version: 1, at: 20, kind: "assistant", text: "Fixed." },
    { id: "s1", version: 1, at: 30, kind: "turnSummary", status: "completed" },
    {
      id: "r",
      version: 1,
      at: 40,
      kind: "user",
      text: "Task result: the header is done.",
      received: { offerId: "o1", childSessionId: "child-1", title: "Header" },
    },
    { id: "a2", version: 1, at: 50, kind: "assistant", text: "Merged the header." },
    { id: "s2", version: 1, at: 60, kind: "turnSummary", status: "completed" },
  ];
  const footers = turnViewFrom(rows, new Set(), { now: 100 }).rows.filter((row) => row.kind === "turnSummary");
  expect(footers.map(offersRetry)).toEqual([true, false]);
  expect(footers[0]!.prompt).toBe("Fix the grid");
});
