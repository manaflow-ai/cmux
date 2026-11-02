// l10n-allow-file: sample chat names in fixtures.
// The banner over a chat the Chief or another chat's agent runs (ManagedBanner.tsx). Its Take over
// button must carry a visible, accessible label: #30765 painted it as a solid pill whose text colour
// was --agent-page-bg, which is transparent in the agent pane, so the label never showed (Leo,
// 2026-11-01: "this needs to be a better button tell the coordinator").
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { ManagedBanner } from "./ManagedBanner";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
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

test("Take over is a button with a readable label, and clicking it takes the chat over", async () => {
  const container = installDom();
  let takenOver = 0;
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <ManagedBanner
        manager={{ kind: "agent", name: "claude-sr2-coord", sessionId: "s-coord" }}
        onTakeOver={() => takenOver++}
        onOpenManager={() => undefined}
      />,
    ),
  );
  expect(container.textContent).toContain("claude-sr2-coord is managing this chat");
  const button = container.querySelector<HTMLButtonElement>("button.acpmux-managed-take-over");
  expect(button).not.toBeNull();
  // Its accessible name is its text: no empty pill, no icon-only control.
  expect(button!.textContent?.trim()).toBe("Take over");
  expect(button!.getAttribute("aria-label") ?? button!.textContent?.trim()).toBe("Take over");
  await act(async () => button!.click());
  expect(takenOver).toBe(1);
});

test("the Take over label is painted in the transcript's text colour on a quiet button, never a transparent token", () => {
  const css = readFileSync(new URL("./managedBanner.css", import.meta.url), "utf8");
  const rule = css.match(/\.acpmux-managed-take-over\{([^}]*)\}/)?.[1] ?? "";
  expect(rule).not.toBe("");
  // --agent-page-bg is transparent in the agent pane (shared/styles.css): as a text colour it hides
  // the label, and as the fill of a solid --agent-text block it made the oversized blank pill.
  expect(rule).not.toMatch(/(^|;)color:var\(--agent-page-bg\)/);
  expect(rule).toMatch(/(^|;)color:var\(--agent-text\)/);
  expect(rule).not.toMatch(/background:var\(--agent-text\)/);
  expect(rule).toMatch(/border:1px solid var\(--agent-border\)/);
});
