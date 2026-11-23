// l10n-allow-file: test fixtures.
// A turn summary (the agent's wrap-up recap, NextStepCard.tsx with no question) closes with its × or
// Esc and stays closed for that chat and turn on this device (#51353, the Mac's side): before, the
// card had no way to close it.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { NextStepCard } from "./NextStepCard";
import type { NextStepAsk } from "./nextStepAsk";
import { NEXT_STEP } from "./turns";
import {
  dismissedWrapUpKeys,
  rememberWrapUpDismissed,
  subscribeWrapUpDismissals,
  withoutDismissedWrapUps,
} from "./wrapUpDismissed";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "KeyboardEvent", "localStorage", "IS_REACT_ACT_ENVIRONMENT"];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

const recapOnly: NextStepAsk = {
  tag: "wrap_up",
  recap: "I resolved the merge conflict and updated the PR. It is MERGEABLE.",
  question: "",
  options: [],
} as unknown as NextStepAsk;
const withQuestion: NextStepAsk = {
  ...recapOnly,
  question: "Merge it?",
  options: [{ label: "Merge" }],
} as unknown as NextStepAsk;

const card = (id: string, ask: NextStepAsk): AcpmuxRow => ({ id, version: 1, at: 1, kind: NEXT_STEP, nextStep: { ask } });
const reply = (id: string): AcpmuxRow => ({ id, version: 1, at: 1, kind: "assistant", text: "Done." });

test("a summary with nothing to answer draws a × that closes it", async () => {
  let closed = 0;
  const container = await render(<NextStepCard ask={recapOnly} onDismiss={() => (closed += 1)} />);
  const close = container.querySelector<HTMLButtonElement>(".acpmux-next-step__close");
  expect(close).not.toBeNull();
  expect(close!.getAttribute("aria-label")).toBeTruthy();
  await act(async () => close!.click());
  expect(closed).toBe(1);
});

test("Esc closes the summary while it has focus", async () => {
  let closed = 0;
  const container = await render(<NextStepCard ask={recapOnly} onDismiss={() => (closed += 1)} />);
  const box = container.querySelector<HTMLElement>(".acpmux-next-step--closable")!;
  await act(async () => {
    box.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(closed).toBe(1);
  await act(async () => {
    box.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(closed).toBe(1);
});

test("a read-only summary and a card with a question draw no ×", () => {
  expect(renderToStaticMarkup(<NextStepCard ask={recapOnly} />)).not.toContain("acpmux-next-step__close");
  expect(renderToStaticMarkup(<NextStepCard ask={withQuestion} onDismiss={() => {}} />)).not.toContain(
    "acpmux-next-step__close",
  );
});

test("a closed summary is kept for its chat and turn, and leaves no row", () => {
  installDom();
  let heard = 0;
  const stop = subscribeWrapUpDismissals(() => (heard += 1));
  const rows = [reply("a1"), card("nextStep-u1", recapOnly), reply("a2"), card("nextStep-u2", recapOnly)];
  expect(withoutDismissedWrapUps(rows, "chat-1", dismissedWrapUpKeys())).toBe(rows);

  rememberWrapUpDismissed("chat-1", "nextStep-u1");
  stop();
  expect(heard).toBe(1);
  // Read back from storage, as a reopened pane reads it.
  const kept = JSON.parse(localStorage.getItem("cmux.agentPane.wrapUpDismissed") ?? "[]") as string[];
  expect(kept).toHaveLength(1);
  const shown = withoutDismissedWrapUps(rows, "chat-1", dismissedWrapUpKeys());
  // The newer turn's summary still shows; another chat's rows with the same id keep theirs.
  expect(shown.map((row) => row.id)).toEqual(["a1", "a2", "nextStep-u2"]);
  expect(withoutDismissedWrapUps(rows, "chat-2", dismissedWrapUpKeys())).toBe(rows);
});

test("a card that still asks is never dropped by a dismissal", () => {
  installDom();
  rememberWrapUpDismissed("chat-1", "nextStep-u1");
  const rows = [card("nextStep-u1", withQuestion)];
  expect(withoutDismissedWrapUps(rows, "chat-1", dismissedWrapUpKeys())).toBe(rows);
});
