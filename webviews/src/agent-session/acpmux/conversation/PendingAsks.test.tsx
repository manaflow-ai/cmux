// l10n-allow-file: test fixtures.
// A question still waiting on the person, pinned above the composer (PendingAsks.tsx): its answer
// goes as the person's message, a send that fails says so and keeps the buttons, and Dismiss is
// kept for the chat across a reload (waitingAskStore.ts).
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { nextStepAsk } from "./nextStepAsk";
import { PendingAsks } from "./PendingAsks";
import { askKey, dismissAsk, dismissedAsks, shownAsks } from "./waitingAskStore";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
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

const card = (at: number, text: string): AcpmuxRow =>
  ({ id: `nextStep-${at}`, version: 1, at, kind: "nextStep", nextStep: { ask: nextStepAsk(text)! } }) as AcpmuxRow;
const asked = card(1_000, "[taste] Which look should ship?\n- Box\n- Inline");

const buttons = (container: HTMLElement) => [...container.querySelectorAll("button")];
const named = (container: HTMLElement, text: string) => buttons(container).find((b) => b.textContent?.includes(text))!;

test("an answer goes as the person's message", async () => {
  const sent: string[] = [];
  const container = await render(
    <PendingAsks
      asks={[asked]}
      onAnswer={(text) => (sent.push(text), Promise.resolve())}
      onDismiss={() => undefined}
    />,
  );
  expect(container.textContent).toContain("Which look should ship?");
  await act(async () => named(container, "Inline").click());
  expect(sent).toEqual(["Inline"]);
});

test("a send that fails says so and keeps the answers", async () => {
  const container = await render(
    <PendingAsks asks={[asked]} onAnswer={() => Promise.reject(new Error("refused"))} onDismiss={() => undefined} />,
  );
  await act(async () => named(container, "Box").click());
  expect(container.querySelector("output")).not.toBeNull();
  expect(named(container, "Box").disabled).toBe(false);
});

test("Dismiss names the card, and the chat keeps it across a reload", async () => {
  const dismissed: string[] = [];
  const container = await render(
    <PendingAsks asks={[asked]} onAnswer={() => Promise.resolve()} onDismiss={(key) => dismissed.push(key)} />,
  );
  const dismiss = container.querySelector<HTMLButtonElement>(".acpmux-pending-ask__dismiss")!;
  await act(async () => dismiss.click());
  expect(dismissed).toEqual([askKey(asked)]);
  dismissAsk("s1", askKey(asked));
  // Read back as a reload reads it: the card leaves the pinned list in that chat only.
  expect(shownAsks([asked], dismissedAsks("s1"))).toEqual([]);
  expect(shownAsks([asked], dismissedAsks("s2"))).toEqual([asked]);
});
