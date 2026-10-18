/// <reference types="bun-types" />
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement, useState } from "react";
import { useSummaryCard, useSummaryColumn, resetSummaryCards } from "../src/agent-session/acpmux/summary/cardState";

const scope = globalThis as Record<string, unknown>;
const globalKeys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "ResizeObserver",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const savedGlobals = globalKeys.map((key) => [key, key in scope, scope[key]] as const);

let dom: JSDOM;
let host: HTMLElement;
let createRoot: typeof import("react-dom/client").createRoot;
let resize: (() => void) | undefined;

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  class TestResizeObserver {
    constructor(callback: () => void) {
      resize = callback;
    }
    observe() {}
    disconnect() {}
  }
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: TestResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: (run: FrameRequestCallback) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  ({ createRoot } = await import("react-dom/client"));
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  host.replaceChildren();
  resetSummaryCards();
  resize = undefined;
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of savedGlobals) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function setMetric(element: HTMLElement, name: "clientWidth" | "offsetWidth", value: number) {
  Object.defineProperty(element, name, { configurable: true, value });
}

function ColumnProbe({ shell, blocked }: { shell: HTMLElement; blocked: boolean }) {
  const column = useSummaryColumn(shell, blocked);
  return createElement("output", { "data-column": column ? "inline" : "popover" }, column ? "inline" : "popover");
}

function CardProbe({ column, hasContent }: { column: boolean; hasContent: boolean }) {
  const card = useSummaryCard(column, hasContent);
  return createElement(
    "div",
    { "data-shown": card.shown ? "true" : "false", "data-reserve": card.reserve ? "true" : "false" },
    createElement("button", { onClick: card.toggle }, "toggle"),
    createElement("button", { onClick: card.close }, "close"),
  );
}

test("summary column stays inline only when the chat and summary fit", async () => {
  const root = createRoot(host);
  const shell = dom.window.document.createElement("section");
  const sidebar = dom.window.document.createElement("aside");
  const rail = dom.window.document.createElement("aside");
  sidebar.className = "acpmux-sidebar";
  rail.className = "acpmux-rail";
  shell.append(sidebar, rail);
  setMetric(sidebar, "offsetWidth", 120);
  setMetric(rail, "offsetWidth", 80);
  // Standard chat width needs 1,056px of active measure (the 660px floor divided by its 0.625
  // share), plus the 300px summary column and the 200px sidebar/rail.
  setMetric(shell, "clientWidth", 1_556);
  host.append(shell);
  try {
    await act(async () => root.render(createElement(ColumnProbe, { shell, blocked: false })));
    expect(host.querySelector("output")?.dataset.column).toBe("inline");

    setMetric(shell, "clientWidth", 1_555);
    await act(async () => resize?.());
    expect(host.querySelector("output")?.dataset.column).toBe("popover");

    await act(async () => root.render(createElement(ColumnProbe, { shell, blocked: true })));
    expect(host.querySelector("output")?.dataset.column).toBe("popover");
  } finally {
    await act(async () => root.unmount());
  }
});

test("empty inline summaries reserve their rail, then hide and show persists globally", async () => {
  const root = createRoot(host);
  try {
    await act(async () => root.render(createElement(CardProbe, { column: true, hasContent: false })));
    const state = () => ({
      shown: host.firstElementChild?.getAttribute("data-shown"),
      reserve: host.firstElementChild?.getAttribute("data-reserve"),
    });
    expect(state()).toEqual({ shown: "false", reserve: "true" });

    await act(async () => (host.querySelectorAll("button")[0] as HTMLButtonElement).click());
    expect(state()).toEqual({ shown: "true", reserve: "false" });

    await act(async () => (host.querySelectorAll("button")[1] as HTMLButtonElement).click());
    expect(state()).toEqual({ shown: "false", reserve: "false" });

    await act(async () => root.render(createElement(CardProbe, { column: true, hasContent: true })));
    expect(host.firstElementChild?.getAttribute("data-shown")).toBe("false");
  } finally {
    await act(async () => root.unmount());
  }
});
