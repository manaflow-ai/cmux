// l10n-allow-file: test fixture prompts, not shipped UI.
// A click on a "Needs your input" card sends the ask quoted, then the answer (nextStepAsk.ts
// `answerPrompt`: "> Claude Code: <question>", a blank line, "Yes"). Leo, 2026-11-19, on the queued
// row that showed it as "> Claude Code: [trust] Let our pool's results count for the required clippy
// and React Doctor check…" ("odd looking"): every one-line preview of a prompt shows the answer, the
// question muted after it where there is room, never the raw `>` quote.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ComposerQueue } from "../ComposerQueue";
import { shownText } from "../composerQueueModel";
import type { AcpmuxRow } from "../model";
import { askText } from "../needsYou/needsYouModel";
import type { NeedsYouItem } from "../needsYou/model";
import { minimapTurns } from "../threadMinimap/model";
import { answerPrompt } from "./nextStepAsk";
import { settleReact } from "../../../../test/support/domTeardown";

const QUESTION = "[trust] Let our pool's results count for the required clippy and React Doctor checks?";
const SENT = answerPrompt(QUESTION, "Yes", "Claude Code");
const t = (key: string) => key;

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  const cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame,
    cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await new Promise((resolve) => setTimeout(resolve, 0));
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("a queued answer's row reads as the answer, the question muted after it, no quote mark", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ComposerQueue
        queue={[{ id: "p-answer", prompt: SENT }]}
        chat="c"
        t={t}
        onChange={async () => true}
        onRemove={async () => true}
      />,
    );
  });
  const clamp = container.querySelector('[data-prompt-id="p-answer"] .acpmux-queued-clamp')!;
  expect(clamp.textContent).not.toContain(">");
  expect(clamp.textContent!.startsWith("Yes")).toBe(true);
  const quote = clamp.querySelector(".acpmux-queued-quote");
  expect(quote?.textContent).toBe(`Claude Code: ${QUESTION}`);
  // Its tooltip says the same, answer first.
  expect(shownText({ id: "p-answer", prompt: SENT }, t)).toBe(`Yes\nClaude Code: ${QUESTION}`);
});

test("the thread minimap's card titles an answer's turn by the answer", () => {
  const row: AcpmuxRow = { id: "u-1", version: 1, at: 1, seq: 1, kind: "user", text: SENT };
  expect(minimapTurns([row], "chat").turns[0]!.prompt).toBe("Yes");
});

test("Needs you reads a guest's held answer as the answer", () => {
  const item: NeedsYouItem = {
    id: "guest:s:p",
    kind: "held",
    sessionId: "s",
    ask: answerPrompt(QUESTION, "Not now", "Claude Code"),
    answers: [],
    promptId: "p",
  } as unknown as NeedsYouItem;
  expect(askText(item, t)).toBe("Not now");
});

test("a prompt that quotes nothing, or only quotes, previews as itself", () => {
  expect(shownText({ id: "a", prompt: "Open the PR" }, t)).toBe("Open the PR");
  expect(shownText({ id: "b", prompt: "> Claude Code: Should I?" }, t)).toBe("> Claude Code: Should I?");
});
