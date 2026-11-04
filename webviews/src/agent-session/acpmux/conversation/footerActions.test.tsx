// Nothing in a reply's footer may shift its Copy, Fork, Read aloud and More buttons (Leo,
// 2026-10-31, on PR chips drawn into that row: "DON'T F***ING SHIFT THE F***ING COPY/FORK/WHATEVER
// F***ING BUTTONS"). The action row holds the buttons and the age only, whatever the turn did: a
// reply that opened pull requests draws the same row as one that did not, and no PR link joins it.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { ReplyActions } from "./MessageActions";
import { TurnFooter } from "./TurnRows";
import { TurnActionsContext } from "./turnActions";

const summary: AcpmuxRow = { id: "summary", version: 1, at: 1_000, kind: "turnSummary", status: "completed" };
const reply = (text: string) => ({ id: "reply", version: 1, at: 1_000, kind: "assistant", text }) as AcpmuxRow;
const withPrs = "Opened https://github.com/acme/app/pull/12 and https://github.com/acme/app/pull/13.";

test("a turn's footer row holds only its footer line, never PR links", () => {
  const markup = renderToStaticMarkup(<TurnFooter row={summary} />);
  expect(markup).toMatch(/<div class="cv-turn-actions[^"]*"[^>]*><span class="cv-message-footer-row/);
  expect(markup).not.toContain("/pull/");
  expect(markup).not.toContain("acpmux-pr");
});

test("a reply's action row starts with its buttons and draws the same whatever the reply names", () => {
  const plain = renderToStaticMarkup(<ReplyActions row={reply("Done.")} />);
  const named = renderToStaticMarkup(<ReplyActions row={reply(withPrs)} />);
  // The row's own attributes (its blank-gap target, gutterSelect.ts) may follow the class.
  expect(named).toMatch(/^<div class="cv-turn-actions cv-reply-actions"[^>]*><span class="cv-turn-action-group">/);
  expect(named).not.toContain("/pull/");
  expect(named).not.toContain("acpmux-pr");
  expect(named.replace(/>[^<]*</g, "><")).toBe(plain.replace(/>[^<]*</g, "><"));
});

test("the latest completed turn keeps Retry beside its reply", () => {
  const row: AcpmuxRow = {
    ...summary,
    text: "Done.",
    prompt: "Finish the task",
    retryRowId: "prompt-1",
    retryable: true,
  };
  const markup = renderToStaticMarkup(
    <TurnActionsContext.Provider value={{ retry: () => undefined }}>
      <TurnFooter row={row} />
    </TurnActionsContext.Provider>,
  );
  expect(markup).toContain(`aria-label="${translate("turn.retry")}"`);
});

test("Retry calls out a known file change without changing the action", () => {
  const row: AcpmuxRow = {
    ...summary,
    text: "Done.",
    prompt: "Finish the task",
    retryRowId: "prompt-1",
    retryable: true,
    changedFiles: true,
  };
  const markup = renderToStaticMarkup(
    <TurnActionsContext.Provider value={{ retry: () => undefined }}>
      <TurnFooter row={row} />
    </TurnActionsContext.Provider>,
  );
  expect(markup).toContain(`title="${translate("turn.retryChangedFiles")}"`);
});

test("an earlier completed turn does not gain the latest-turn Retry", () => {
  const row: AcpmuxRow = { ...summary, text: "Done.", prompt: "Finish the task", retryRowId: "prompt-1" };
  const markup = renderToStaticMarkup(
    <TurnActionsContext.Provider value={{ retry: () => undefined }}>
      <TurnFooter row={row} />
    </TurnActionsContext.Provider>,
  );
  expect(markup).not.toContain(`aria-label="${translate("turn.retry")}"`);
});

test("a failed turn keeps its Retry and Retry with model actions", () => {
  const retryWith = {
    models: [
      { id: "claude-sonnet", name: "Claude Sonnet" },
      { id: "claude-opus", name: "Claude Opus" },
    ],
    retry: () => undefined,
  };
  const row: AcpmuxRow = {
    ...summary,
    status: "failed",
    error: "The request failed",
    prompt: "Finish the task",
    retryRowId: "prompt-1",
    retryable: true,
  };
  const markup = renderToStaticMarkup(
    <TurnActionsContext.Provider value={{ retry: () => undefined, retryWith }}>
      <TurnFooter row={row} />
    </TurnActionsContext.Provider>,
  );
  expect(markup).toContain(`aria-label="${translate("turn.retry")}"`);
  expect(markup).toContain(`aria-label="${translate("turn.retryWith")}"`);
});
