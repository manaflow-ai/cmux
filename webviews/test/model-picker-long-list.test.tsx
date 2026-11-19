import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "ShadowRoot",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    ShadowRoot: dom.window.ShadowRoot,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    CSSStyleSheet: dom.window.CSSStyleSheet,
    DocumentFragment: dom.window.DocumentFragment,
    SVGElement: dom.window.SVGElement,
    HTMLTemplateElement: dom.window.HTMLTemplateElement,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const popup of dom.window.document.querySelectorAll(".acpmux-quick-menu")) popup.remove();
});

afterAll(async () => {
  // A checkbox indicator's last update lands a task after the final test: let it run on this window.
  await settle();
  await teardownDom(saved, { window: dom.window, scope });
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

// Idea 3 of the speed work (Leo: "would next's ideas make sense for our app? since we're already
// using react..."): a list that can pass ~100 rows draws only the rows in view. A harness that
// lists a whole provider's catalog put 1,000 rows in the full picker's More models fold and its
// search, every one a DOM row on each key; test/latency/actions.ts "chat flows 1000 models" times it.
const lab = Array.from({ length: 1000 }, (_, index) => ({
  id: `lab-model-${String(index + 1).padStart(4, "0")}`,
  name: `Lab Model ${String(index + 1).padStart(4, "0")}`,
}));
const opus = { id: "claude-opus-5-5", name: "Opus 5.5" };

async function open(models: { id: string; name: string }[]) {
  const { createRoot } = await import("react-dom/client");
  const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ModelPicker
        catalog={[{ id: "claude", name: "Claude Code", models, pickable: true }]}
        harness="claude"
        model={opus.id}
        label={opus.name}
        efforts={[]}
        recents={[]}
        onLand={() => {}}
        onCombo={() => {}}
        onHarness={() => {}}
        onEffort={() => {}}
      />,
    ),
  );
  await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-picker-button")!.click());
  await settle();
  const doc = dom.window.document;
  const more = doc.querySelector<HTMLButtonElement>(".acpmux-mp-older");
  if (more) await act(async () => more.click());
  await settle();
  return doc;
}

const rows = (doc: Document) => [...doc.querySelectorAll<HTMLElement>('.acpmux-mp-models [role="option"]')];

describe("the full model picker with 1,000 models", () => {
  test("More models draws only the rows in view, and the highlighted row is always drawn", async () => {
    const doc = await open([opus, ...lab]);
    expect(doc.querySelector(".acpmux-mp-older")?.getAttribute("aria-expanded")).toBe("true");
    const drawn = rows(doc).length;
    expect(drawn).toBeGreaterThan(0);
    expect(drawn).toBeLessThan(100);
    // Each key moves the highlight through the 1,001 rows: the row it lands on is drawn, and the
    // search names it, though the list draws only the rows in view.
    const search = doc.querySelector<HTMLInputElement>(".acpmux-mp-search input")!;
    const names: string[] = [];
    for (let press = 0; press < 3; press++) {
      await act(async () =>
        search.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true })),
      );
      await settle();
      const active = search.getAttribute("aria-activedescendant");
      names.push(doc.getElementById(active ?? "")?.textContent ?? "(not drawn)");
    }
    expect(new Set(names).size).toBe(3);
    expect(names).not.toContain("(not drawn)");
    expect(rows(doc).length).toBeLessThan(100);
  });

  test("a short list still draws every row", async () => {
    const doc = await open([opus, ...lab.slice(0, 20)]);
    expect(rows(doc).length).toBe(21);
  });
});

describe("the model menu the chip opens, with 1,000 models", () => {
  async function openMenu(models: { id: string; name: string }[]) {
    const { createRoot } = await import("react-dom/client");
    const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <ModelPicker
          catalog={[{ id: "claude", name: "Claude Code", models, pickable: true }]}
          harness="claude"
          model={opus.id}
          label={opus.name}
          efforts={[]}
          recents={[]}
          onLand={() => {}}
          onCombo={() => {}}
          onHarness={() => {}}
          onEffort={() => {}}
          quick={{}}
        />,
      ),
    );
    await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
    await settle();
    return dom.window.document;
  }
  const options = (doc: Document) => [...doc.querySelectorAll('.acpmux-cols-list [role="option"]')];

  test("opens drawing only the rows in view, with the highlighted row among them", async () => {
    const doc = await openMenu([opus, ...lab]);
    const drawn = options(doc).length;
    expect(drawn).toBeGreaterThan(0);
    expect(drawn).toBeLessThan(100);
    const field = doc.querySelector<HTMLInputElement>(".acpmux-cols-search input")!;
    const active = field.getAttribute("aria-activedescendant");
    expect(active).toBeTruthy();
    expect(doc.getElementById(active!)).not.toBeNull();
  });

  test("a short tab still draws every row", async () => {
    const doc = await openMenu([opus, ...lab.slice(0, 20)]);
    expect(options(doc).length).toBe(21);
  });
});
