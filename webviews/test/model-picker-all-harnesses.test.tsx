import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

// Leo 2026-10-26: "show all harnesses, all models (pi, opencode, prime intellect, etc…)". The picker
// dropped every catalog harness this machine does not have, so Pi, OpenCode, Gemini and the rest
// never showed. Each now has its rail tab after the installed ones, its catalog models listed but
// not pickable, and an Install… row.
const claude = { id: "claude", name: "Claude Code", models: [{ id: "opus", name: "Opus 5.5" }], pickable: true };
const gemini = {
  id: "gemini",
  name: "Gemini CLI",
  models: [{ id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro" }],
  pickable: false,
  notInstalled: true as const,
};
const pi = { id: "pi", name: "Pi", models: [], pickable: false, notInstalled: true as const };

describe("harnesses this machine does not have", () => {
  test("the picker's face stays on an installed harness", async () => {
    const { pickerFaceHarness } = await import("../src/agent-session/acpmux/ModelPicker");
    expect(pickerFaceHarness([gemini, pi, claude])).toBe("claude");
    expect(pickerFaceHarness([gemini, pi])).toBeUndefined();
  });

  test("the composer's entries flag a catalog harness that is not installed", async () => {
    const { composerPickerEntries } = await import("../src/agent-session/acpmux/composerPickerEntries");
    const harness = (id: string, installed: boolean) => ({
      id,
      name: id,
      brand: id,
      acpmuxHarness: installed ? id : null,
      installed,
      pickable: true,
      models: [],
    });
    const entries = composerPickerEntries({ catalog: [], summary: undefined } as never, {
      harnesses: [harness("claude", true), harness("pi", false)],
      provisional: false,
    });
    expect(entries.map((entry) => [entry.id, entry.pickable, entry.notInstalled])).toEqual([
      ["claude", true, undefined],
      ["pi", false, true],
    ]);
  });

  test("the compact menu lists them with their models and an Install… row", async () => {
    const { createRoot } = await import("react-dom/client");
    const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
    const picked: string[] = [];
    let added = 0;
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <ModelPicker
          catalog={[gemini, claude, pi]}
          harness="claude"
          model="opus"
          label="Opus 5.5"
          efforts={[]}
          recents={[]}
          onLand={(id) => picked.push(id)}
          onCombo={(combo) => picked.push(combo.model)}
          onHarness={(id) => picked.push(id)}
          onEffort={() => {}}
          onAddAgent={() => added++}
          quick={{}}
        />,
      ),
    );
    await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
    await settle();
    const doc = dom.window.document;
    const tabs = [...doc.querySelectorAll<HTMLButtonElement>(".acpmux-quick-rail-tab")].map((tab) => tab.title);
    // Installed first, then the rest in catalog order.
    expect(tabs).toEqual(["Claude Code", "Gemini CLI · Not installed", "Pi · Not installed", "Add harness…"]);
    const geminiTab = doc.querySelector<HTMLButtonElement>('.acpmux-quick-rail-tab[aria-label="Gemini CLI"]')!;
    await act(async () => geminiTab.click());
    await settle();
    const menu = doc.querySelector(".acpmux-quick-menu")!;
    expect(menu.textContent).toContain("Gemini 3.1 Pro");
    expect(menu.textContent).toContain("Not installed");
    const row = [...menu.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find((item) =>
      item.textContent?.includes("Gemini 3.1 Pro"),
    )!;
    expect(row.getAttribute("aria-disabled")).toBe("true");
    await act(async () => row.click());
    expect(picked).toEqual([]);
    const install = [...menu.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
      (item) => item.textContent === "Install…",
    )!;
    await act(async () => install.click());
    expect(added).toBe(1);
  });
});
