// The header's panel toggle draws the same glyph on and off: the open panel shows through the
// square behind it and the lit ink, never a heavier glyph (Leo 2026-11-06: "Why is it bolded after
// I click on it to get it toggled? ... the symbol itself is getting bolded for some reason.").
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PanelToggle } from "./PanelToggle";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
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
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  act(() => root?.unmount());
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

// One DOM per test: both renders share it, so cleanup restores the real globals and closes it.
function glyph(container: HTMLElement, shown: boolean): string {
  act(() => root!.render(<PanelToggle label="Session Info" shown={shown} onToggle={() => {}} />));
  return container.querySelector("svg")!.innerHTML;
}

test("an open panel's toggle draws the same glyph, at the same weight, as a closed one", () => {
  const container = installDom();
  root = createRoot(container);
  const off = glyph(container, false);
  const on = glyph(container, true);
  expect(off).toContain("stroke-width");
  expect(on).toBe(off);
});
