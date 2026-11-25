// l10n-allow-file: test fixtures.
// The #41892 follow-ups (#43915): a streaming output box never takes a reader's place (a `!` shell
// run that starts with no output, a background task card), a very long output's cut start can be
// drawn, and a diff body lets go of its element on unmount.
import { afterEach, beforeAll, beforeEach, expect, mock, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "NodeFilter",
  "HTMLElement",
  "Element",
  "MutationObserver",
  "customElements",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;
let host: HTMLElement;

/// What the background card's reader returns now.
let read: { output?: string; running?: boolean } = {};
const BG = "../src/agent-session/acpmux/conversation/backgroundTaskOutput";

beforeAll(async () => {
  const real = await import(BG);
  void mock.module(BG, () => ({ ...real, useLiveBackgroundTaskOutput: () => read }));
});

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    NodeFilter: dom.window.NodeFilter,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    customElements: dom.window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // jsdom lays nothing out: a 100 px box over 1,000 px of text, and a scrollTop that holds what is set.
  const tops = new WeakMap<object, number>();
  const proto = dom.window.HTMLElement.prototype;
  Object.defineProperty(proto, "scrollHeight", { configurable: true, get: () => 1000 });
  Object.defineProperty(proto, "clientHeight", { configurable: true, get: () => 100 });
  Object.defineProperty(proto, "scrollTop", {
    configurable: true,
    get(this: object) {
      return tops.get(this) ?? 0;
    },
    set(this: object, value: number) {
      tops.set(this, value);
    },
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
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

const show = async (node: React.ReactNode) => {
  await act(async () => {
    root ??= createRoot(host);
    root.render(node);
  });
};

/// The reader scrolls the box: to `top`, then the browser's scroll event.
const scrollTo = async (box: Element, top: number) => {
  (box as HTMLElement).scrollTop = top;
  await act(async () => {
    box.dispatchEvent(new dom!.window.Event("scroll"));
  });
};

test("a `!` shell run that starts with no output keeps a reader who scrolled up where they are", async () => {
  const { ShellRow } = await import("../src/agent-session/acpmux/shell/ShellRow");
  const row = (output: string): AcpmuxRow => ({
    id: "shell-1",
    kind: "userShell",
    at: 1,
    version: 1,
    shell: { id: "1", command: "make", startedAt: 1, status: "running", output, truncated: false, version: 1 },
  });
  await show(<ShellRow row={row("")} />);
  expect(host.querySelector("pre")).toBeNull();
  // The first output makes the box; a reader who has not scrolled is at its end.
  await show(<ShellRow row={row("one\ntwo")} />);
  const box = host.querySelector("pre")!;
  expect(box.scrollTop).toBe(1000);
  // Scrolled up from the end: a new chunk leaves them there.
  await scrollTo(box, 200);
  await show(<ShellRow row={row("one\ntwo\nthree")} />);
  expect(host.querySelector("pre")!.scrollTop).toBe(200);
  // Back at the end (900 + 100 of 1,000): it follows again.
  await scrollTo(box, 900);
  await show(<ShellRow row={row("one\ntwo\nthree\nfour")} />);
  expect(host.querySelector("pre")!.scrollTop).toBe(1000);
});

test("a background task card keeps a reader who scrolled up where they are", async () => {
  const { BackgroundTaskBody } = await import("../src/agent-session/acpmux/backgroundTasks/BackgroundTaskCard");
  const body = () => <BackgroundTaskBody command="tail -f log" toolCallId="t" open />;
  read = { output: "a\nb", running: true };
  await show(body());
  const box = host.querySelector("pre")!;
  expect(box.scrollTop).toBe(1000);
  await scrollTo(box, 200);
  read = { output: "a\nb\nc", running: true };
  await show(body());
  expect(host.querySelector("pre")!.scrollTop).toBe(200);
  await scrollTo(box, 900);
  read = { output: "a\nb\nc\nd", running: true };
  await show(body());
  expect(host.querySelector("pre")!.scrollTop).toBe(1000);
});

test("the leading … of a cut output draws all of it, its start included", async () => {
  const { ToolOutput } = await import("../src/agent-session/acpmux/conversation/ToolOutputBody");
  const text = Array.from({ length: 2_500 }, (_, index) => `line ${index + 1}`).join("\n");
  await show(<ToolOutput result={{ text, lang: "text" }} />);
  const cut = host.querySelector<HTMLButtonElement>("button.cv-output-cut")!;
  expect(cut).not.toBeNull();
  expect(cut.getAttribute("aria-label")).toBe("Show earlier output");
  expect(host.textContent).not.toContain("line 1\n");
  expect(host.textContent).toContain("line 2500");
  await act(async () => cut.click());
  expect(host.querySelector("button.cv-output-cut")).toBeNull();
  expect(host.textContent).toContain("line 1");
  expect(host.querySelectorAll(".cv-line").length).toBeGreaterThan(2_000);
});

test("a diff body's ref lets go of the element on unmount", async () => {
  const { heldNode } = await import("../src/agent-session/acpmux/conversation/EditDiff");
  const held: { current: HTMLDivElement | null } = { current: null };
  const node = dom!.window.document.createElement("div");
  const release = heldNode(held, node, true);
  expect(held.current).toBe(node);
  release();
  expect(held.current).toBeNull();
});
