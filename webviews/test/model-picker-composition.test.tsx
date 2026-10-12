import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
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
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;
let originalRect: typeof HTMLElement.prototype.getBoundingClientRect;

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
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  originalRect = dom.window.HTMLElement.prototype.getBoundingClientRect;
  dom.window.HTMLElement.prototype.getBoundingClientRect = function () {
    if (this.classList.contains("acpmux-mp")) {
      return {
        bottom: 520,
        height: 180,
        left: 24,
        right: 420,
        top: 340,
        width: 396,
        x: 24,
        y: 340,
        toJSON: () => ({}),
      };
    }
    if (this.classList.contains("acpmux-picker-button")) {
      return {
        bottom: 548,
        height: 28,
        left: 24,
        right: 144,
        top: 520,
        width: 120,
        x: 24,
        y: 520,
        toJSON: () => ({}),
      };
    }
    return originalRect.call(this);
  };
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.HTMLElement.prototype.getBoundingClientRect = originalRect;
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const catalog = [
  {
    id: "codex",
    name: "Codex",
    models: [
      { id: "gpt-6.1-sol", name: "GPT-6.1 Sol" },
      { id: "gpt-5.5", name: "GPT-5.5" },
    ],
  },
];

async function mount() {
  const { createRoot } = await import("react-dom/client");
  const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
  const picks: string[] = [];
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <ModelPicker
        catalog={catalog}
        harness="codex"
        model="gpt-6.1-sol"
        label="GPT-6.1 Sol"
        efforts={[]}
        recents={[]}
        onLand={(model) => picks.push(model)}
        onEffort={() => undefined}
      />,
    );
  });
  await act(async () => {
    host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click();
  });
  return {
    picks,
    search: host.querySelector<HTMLInputElement>('.acpmux-mp input[role="combobox"]')!,
  };
}

for (const composition of [{ isComposing: true }, { keyCode: 229 }]) {
  test(`Enter stays with the IME (${"isComposing" in composition ? "isComposing" : "keyCode 229"})`, async () => {
    const { picks, search } = await mount();
    const composing = new dom.window.KeyboardEvent("keydown", {
      bubbles: true,
      cancelable: true,
      key: "Enter",
      ...composition,
    });
    await act(async () => {
      search.dispatchEvent(composing);
    });
    expect(composing.defaultPrevented).toBe(false);
    expect(picks).toHaveLength(0);
    expect(host.querySelector(".acpmux-mp")).not.toBeNull();
  });
}

test("numeric model search input is not treated as a row shortcut", async () => {
  const { picks, search } = await mount();
  await act(async () => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(search, "gpt");
    search.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  const digit = new dom.window.KeyboardEvent("keydown", {
    bubbles: true,
    cancelable: true,
    key: "1",
  });
  await act(async () => {
    search.dispatchEvent(digit);
  });
  expect(digit.defaultPrevented).toBe(false);
  expect(picks).toHaveLength(0);
  expect(host.querySelector(".acpmux-mp")).not.toBeNull();
});
