// l10n-allow-file: test fixture prompts, not shipped UI.
// A prompt the Chief sent a subagent says so, and a long task opens on its first lines with Show
// all (Lawrence 2026-10-19: every prompt shows, attributed, long Chief tasks collapsed).
import { afterEach, expect, test } from "bun:test";
import React, { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ChiefPromptBubble } from "./ChiefPromptBubble";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function render(text: string, actions?: React.ReactNode): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
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
  const host = dom.window.document.getElementById("root")!;
  act(() => {
    root = createRoot(host);
    root.render(<ChiefPromptBubble text={text} actions={actions} />);
  });
  return host;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("a short Chief prompt shows whole, marked as from the Chief", () => {
  const host = render("Fix the prompt bubble");
  expect(host.querySelector(".cv-user__from")?.textContent).toBe("From the Chief");
  expect(host.querySelector(".cv-user__bubble")?.textContent).toBe("Fix the prompt bubble");
  expect(host.querySelector(".cv-user__bubble--collapsed")).toBeNull();
  expect(host.querySelector(".cv-user__expand")).toBeNull();
});

test("a long Chief task opens collapsed and Show all opens it", () => {
  const task = Array.from({ length: 20 }, (_, index) => `Step ${index + 1}: do the thing.`).join("\n");
  const host = render(task);
  const bubble = () => host.querySelector(".cv-user__bubble")!;
  const toggle = () => host.querySelector<HTMLButtonElement>(".cv-user__expand")!;
  expect(bubble().classList.contains("cv-user__bubble--collapsed")).toBe(true);
  // The whole text stays in the bubble (select and copy take all of it); only its height is clamped.
  expect(bubble().textContent).toBe(task);
  expect(toggle().textContent).toBe("Show all");
  expect(toggle().getAttribute("aria-expanded")).toBe("false");
  act(() => {
    toggle().dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  });
  expect(bubble().classList.contains("cv-user__bubble--collapsed")).toBe(false);
  expect(toggle().textContent).toBe("Show less");
  expect(toggle().getAttribute("aria-expanded")).toBe("true");
});

// Leo 2026-10-31: Show all sat on its own row at the right and pushed the time/copy/retry row down.
// It leads that row on the left instead, so a collapsed task adds no extra row.
test("Show all leads the action row instead of taking a row of its own", () => {
  const task = Array.from({ length: 20 }, (_, index) => `Step ${index + 1}.`).join("\n");
  const host = render(task, <div className="cv-user__actions">actions</div>);
  const toggle = host.querySelector<HTMLButtonElement>(".cv-user__expand")!;
  const row = toggle.parentElement!;
  expect(row.classList.contains("cv-user__chief-footer")).toBe(true);
  expect(row.firstElementChild).toBe(toggle);
  expect(row.querySelector(".cv-user__actions")).not.toBeNull();
  // A short prompt has no toggle, and its action row stays where it was.
  act(() => root?.render(<ChiefPromptBubble text="Short" actions={<div className="cv-user__actions">a</div>} />));
  expect(host.querySelector(".cv-user__expand")).toBeNull();
  expect(host.querySelector(".cv-user__chief-footer")).toBeNull();
  expect(host.querySelector(".cv-user__actions")).not.toBeNull();
});

// Leo 2026-10-31: the collapsed bubble showed half of the next line under its last one. The clamp
// is on an inner box, so the bubble's bottom padding never shows clipped text.
test("a collapsed task clamps an inner box, inside the bubble's padding", () => {
  const task = Array.from({ length: 20 }, (_, index) => `Step ${index + 1}.`).join("\n");
  const host = render(task);
  const clamp = host.querySelector(".cv-user__bubble--collapsed > .cv-user__clamp");
  expect(clamp?.textContent).toBe(task);
});
