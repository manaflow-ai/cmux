import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

// The streaming reply (R104): blocks that are done never render again, new text flows in over
// display frames, and blocks that appear while the reply streams enter with the shared motion.
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "customElements",
  "Node",
  "MutationObserver",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved = Object.fromEntries(keys.map((key) => [key, globals[key]]));
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  // Code cards load @pierre/diffs, which defines its web component at import.
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IS_REACT_ACT_ENVIRONMENT: true,
});
// Code cards render @pierre/diffs, which reaches for DOM classes by their global names.
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(async () => {
  // React finishes scheduled work on a timer; let it run before the DOM globals go away.
  await new Promise((resolve) => setTimeout(resolve, 20));
  Object.assign(globals, saved);
  for (const key of domClasses) delete globals[key];
});

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Markdown } = await import("./Markdown");
const { RevealedMarkdown, revealFrames } = await import("./RevealedMarkdown");

/// A manual display: frames run only when the test steps them.
const frames: ((now: number) => void)[] = [];
let clock = 0;
revealFrames.request = (callback) => frames.push(callback);
revealFrames.cancel = (handle) => {
  frames[handle - 1] = () => {};
};
const step = (count = 1) =>
  act(() => {
    for (let index = 0; index < count; index += 1) {
      clock += 1000 / 120;
      for (const callback of frames.splice(0)) callback(clock);
    }
  });

function mount() {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  return { host, render: (node: React.ReactElement) => act(() => root.render(node)), root };
}

describe("streaming Markdown", () => {
  test("a block that is done keeps its DOM node while the reply grows", () => {
    const view = mount();
    view.render(createElement(Markdown, null, "First paragraph.\n\nSecond is streaming"));
    const first = view.host.querySelector("p");
    view.render(createElement(Markdown, null, "First paragraph.\n\nSecond is streaming more text"));
    expect(view.host.querySelector("p")).toBe(first);
    expect(view.host.textContent).toContain("Second is streaming more text");
    view.root.unmount();
  });

  test("blocks there at mount do not animate; blocks that appear while streaming do", () => {
    const view = mount();
    view.render(<Markdown streaming>{"Already here.\n\nTail"}</Markdown>);
    expect(view.host.querySelectorAll(".cv-enter")).toHaveLength(0);
    view.render(<Markdown streaming>{"Already here.\n\nTail\n\n# New heading"}</Markdown>);
    const entered = [...view.host.querySelectorAll(".cv-enter")].map((node) => node.textContent);
    expect(entered).toEqual(["New heading"]);
    view.root.unmount();
  });
});

describe("revealed reply", () => {
  test("a reply that is not streaming shows all of its text at once", () => {
    const view = mount();
    view.render(createElement(RevealedMarkdown, { text: "Done reply.", streaming: false }));
    expect(view.host.textContent).toBe("Done reply.");
    view.root.unmount();
  });

  test("new streamed text flows in over frames and then shows in full", () => {
    const view = mount();
    view.render(createElement(RevealedMarkdown, { text: "Hi", streaming: true }));
    const more = "Hi there, this reply keeps arriving in one burst of many words at once.";
    view.render(createElement(RevealedMarkdown, { text: more, streaming: true }));
    expect(view.host.textContent).toBe("Hi");
    step(2);
    const partial = view.host.textContent ?? "";
    expect(partial.length).toBeGreaterThan(2);
    expect(partial.length).toBeLessThan(more.length);
    expect(more.startsWith(partial)).toBe(true);
    // A live stream trails by its lag; once nothing arrives for a moment the rest drains.
    step(90);
    expect(view.host.textContent).toBe(more);
    view.root.unmount();
  });

  test("when the stream ends, the same element keeps showing the reply (no remount)", () => {
    const view = mount();
    view.render(createElement(RevealedMarkdown, { text: "Para one.\n\nTwo", streaming: true }));
    step(20);
    const first = view.host.querySelector("p");
    view.render(createElement(RevealedMarkdown, { text: "Para one.\n\nTwo", streaming: false }));
    step(5);
    expect(view.host.querySelector("p")).toBe(first);
    view.root.unmount();
  });
});

/// Code cards (acp-streaming.md "Code"): an open fence draws plain lines with the card's metrics,
/// and highlighting runs once, when the fence closes, instead of on every delta.
describe("streaming code", () => {
  test("an open fence draws plain lines and no highlighter", () => {
    const view = mount();
    view.render(<Markdown streaming>{"Look:\n\n```ts\nconst a = 1;\nconst b"}</Markdown>);
    const plain = view.host.querySelector(".cv-codeblock--plain");
    expect(plain?.textContent).toContain("const a = 1;");
    expect(plain?.textContent).toContain("const b");
    expect(view.host.querySelectorAll("diffs-container")).toHaveLength(0);
    view.root.unmount();
  });

  test("a fence that closes while streaming is highlighted once, and later text does not touch it", () => {
    const view = mount();
    view.render(<Markdown streaming>{"```ts\nconst a = 1;\n"}</Markdown>);
    view.render(<Markdown streaming>{"```ts\nconst a = 1;\n```\n\nAfter"}</Markdown>);
    const host = view.host.querySelector(".cv-code-handoff diffs-container");
    expect(host).not.toBeNull();
    view.render(<Markdown streaming>{"```ts\nconst a = 1;\n```\n\nAfter the code, more text"}</Markdown>);
    expect(view.host.querySelector(".cv-code-handoff diffs-container")).toBe(host);
    view.root.unmount();
  });

  test("a finished reply's fence draws the highlighted card directly", () => {
    const view = mount();
    view.render(<Markdown>{"```ts\nconst a = 1;\n```"}</Markdown>);
    expect(view.host.querySelectorAll(".cv-codeblock--plain, .cv-code-handoff")).toHaveLength(0);
    expect(view.host.querySelectorAll("diffs-container")).toHaveLength(1);
    view.root.unmount();
  });
});
