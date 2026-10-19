// The chat's viewer (labs chatViewer, Lucas 2026-10-19): a path chip's click goes to the viewer the
// App registers instead of the app's tab over the chat, and the viewer shows the file with a way
// back and the app's own tab or editor one click away.
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

test("a path chip opens in the registered viewer, else through the host", async () => {
  const { openPathChip, setChipHost, setPathViewer } = await import("../src/agent-session/acpmux/chips/host");
  const calls: [string, Record<string, unknown>][] = [];
  setChipHost(async (method, params) => {
    calls.push([method, params]);
    return null;
  });
  const viewed: string[] = [];
  setPathViewer((path) => viewed.push(path));
  openPathChip("src/App.tsx");
  expect(viewed).toEqual(["src/App.tsx"]);
  expect(calls).toEqual([]);
  setPathViewer(undefined);
  openPathChip("src/App.tsx");
  await Promise.resolve();
  await Promise.resolve();
  expect(calls).toEqual([["link.openPath", { path: "src/App.tsx" }]]);
  setChipHost(undefined);
});

test("the viewer shows the file, says when it is cut, and leaves only by an explicit choice", async () => {
  const { createRoot } = await import("react-dom/client");
  const { FileViewer } = await import("../src/agent-session/acpmux/FileViewer");
  const opened: [string, string][] = [];
  let closed = 0;
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <FileViewer
        file={{ path: "/Users/you/src/app/notes.txt", text: "first line\nsecond line", bytes: 2_000_000, truncated: true }}
        onClose={() => (closed += 1)}
        onOpenFile={(path, where) => opened.push([path, where])}
      />,
    ),
  );
  expect(host.querySelector(".acpmux-file-viewer-name")?.textContent).toBe("notes.txt");
  expect(host.textContent).toContain("second line");
  expect(host.querySelector(".acpmux-file-viewer-note")?.textContent).toContain("2000000");
  const [tab, editor] = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-diff-tool")];
  await act(async () => tab!.click());
  await act(async () => editor!.click());
  expect(opened).toEqual([
    ["/Users/you/src/app/notes.txt", "tab"],
    ["/Users/you/src/app/notes.txt", "editor"],
  ]);
  await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-diff-back")!.click());
  expect(closed).toBe(1);
  const section = host.querySelector("section")!;
  await act(async () => {
    section.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(closed).toBe(2);
});

test("files highlight by extension or name, anything else is text", async () => {
  const { fileLanguage } = await import("../src/agent-session/acpmux/FileViewer");
  expect(fileLanguage("/a/App.tsx")).toBe("tsx");
  expect(fileLanguage("/a/main.rs")).toBe("rust");
  expect(fileLanguage("/a/Makefile")).toBe("make");
  expect(fileLanguage("/a/config.yml")).toBe("yml");
  expect(fileLanguage("/a/photo.heic")).toBe("text");
  expect(fileLanguage("/a/README")).toBe("text");
});
