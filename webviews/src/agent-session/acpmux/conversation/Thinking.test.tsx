// l10n-allow-file: the status copy is supplied by the pane's string table.
// The first streamed answer token replaces the live line in the same frame. The line must hide
// before that frame paints, or "Thinking" flashes underneath the answer for one frame.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { Thinking } from "./Thinking";
import { WorkingFor } from "./WorkingFor";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
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
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

test("hides the live line before the first streamed answer token paints", () => {
  act(() => root!.render(<Thinking quietKey={undefined} />));
  expect(container.querySelector(".cv-worked")?.classList.contains("is-quiet")).toBe(false);

  act(() => root!.render(<Thinking quietKey="assistant:1" />));
  expect(container.querySelector(".cv-worked")?.classList.contains("is-quiet")).toBe(true);
});

test("a send in flight names who it goes to, on either live line", () => {
  act(() => root!.render(<Thinking doing="acpmux send coord 'hi'" doingShell sendTo="coord" />));
  expect(container.querySelector(".cv-worked")?.textContent).toContain("Sending message to coord");
  expect(container.textContent).not.toContain("acpmux send");
  const row: AcpmuxRow = {
    id: "working",
    version: 1,
    at: Date.now(),
    kind: "working",
    doing: "acpmux send coord 'hi'",
    doingCommand: true,
    doingSendTo: "coord",
  };
  act(() => root!.render(<WorkingFor row={row} />));
  expect(container.querySelector(".cv-worked")?.textContent).toContain("Sending message to coord");
  expect(container.textContent).not.toContain("acpmux send");
  expect(container.querySelector(".cv-worked__glyph")).toBeNull();
});
