// Lucas 2026-10-19: the header's Files opened the file tree in a new column that scrolled the chat
// and its tabs out of view. With the chat's viewer it opens beside the transcript: the chat's
// folder, folders open in place, a file opens in the viewer, and search uses the session host's.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "customElements",
  "ShadowRoot",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "Event",
  "KeyboardEvent",
  "MouseEvent",
  "CustomEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    customElements: window.customElements,
    ShadowRoot: window.ShadowRoot,
    CSSStyleSheet: window.CSSStyleSheet,
    DocumentFragment: window.DocumentFragment,
    SVGElement: window.SVGElement,
    HTMLTemplateElement: window.HTMLTemplateElement,
    Event: window.Event,
    KeyboardEvent: window.KeyboardEvent,
    MouseEvent: window.MouseEvent,
    CustomEvent: window.CustomEvent,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const ROOT = "/Users/you/src/app";
const LIST: Record<string, { name: string; kind: string }[]> = {
  [ROOT]: [
    { name: "src", kind: "directory" },
    { name: "README.md", kind: "file" },
  ],
  [`${ROOT}/src`]: [{ name: "main.ts", kind: "file" }],
};

async function show(props: { folder?: string; outside?: boolean } = {}) {
  const { createRoot } = await import("react-dom/client");
  const { FilesView } = await import("../src/agent-session/acpmux/FilesView");
  const events: string[] = [];
  const source = {
    list: async (folder: string) => {
      if (props.outside) throw new Error(`${folder} is not in a git repository`);
      return { entries: LIST[folder] ?? [] };
    },
    search: async (query: string) => ({ search_root: ROOT, results: query === "mai" ? [{ path: "src/main.ts" }] : [] }),
  };
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <FilesView
        root={ROOT}
        folder={props.folder ?? ROOT}
        source={source}
        onFolder={(folder) => events.push(`folder ${folder}`)}
        onOpen={(path) => events.push(`open ${path}`)}
        onClose={() => events.push("close")}
      />,
    ),
  );
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const rows = () => [...host.querySelectorAll<HTMLButtonElement>(".acpmux-files-row")];
  return { events, rows, names: () => rows().map((row) => row.textContent) };
}

test("the chat's folder lists its entries; a folder opens in place, a file in the viewer", async () => {
  const { events, rows, names } = await show();
  expect(names()).toEqual(["src", "README.md"]);
  await act(async () => rows()[0]!.click());
  await act(async () => rows()[1]!.click());
  expect(events).toEqual([`folder ${ROOT}/src`, `open ${ROOT}/README.md`]);
});

test("inside a subfolder .. goes up, never above the chat's folder", async () => {
  const { events, rows, names } = await show({ folder: `${ROOT}/src` });
  expect(names()).toEqual(["..", "main.ts"]);
  await act(async () => rows()[0]!.click());
  expect(events).toEqual([`folder ${ROOT}`]);
});

test("search opens a result at its full path, and Escape clears it before closing", async () => {
  const { events, rows, names } = await show();
  const input = host.querySelector<HTMLInputElement>("input[type=search]")!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, "mai");
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(names()).toEqual(["src/main.ts"]);
  await act(async () => rows()[0]!.click());
  expect(events).toEqual([`open ${ROOT}/src/main.ts`]);
  const section = host.querySelector("section")!;
  await act(async () => section.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
  expect(events).toEqual([`open ${ROOT}/src/main.ts`]);
  expect(names()).toEqual(["src", "README.md"]);
  await act(async () => section.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
  expect(events.at(-1)).toBe("close");
});

test("a folder in no git repository says so", async () => {
  await show({ outside: true });
  expect(host.querySelector(".acpmux-file-viewer-note")?.textContent).toBe("This folder isn't in a git repository");
});

// Lucas 2026-10-19: the open viewer needs a plain way out besides Back: an X at the header's end.
test("the viewer's X closes it", async () => {
  const { events } = await show();
  await act(async () => host.querySelector<HTMLButtonElement>('.acpmux-diff-header button[aria-label="Close"]')!.click());
  expect(events).toEqual(["close"]);
});
