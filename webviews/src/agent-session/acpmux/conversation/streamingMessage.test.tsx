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
  "requestAnimationFrame",
  "cancelAnimationFrame",
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
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
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

const { act, createElement, Profiler } = await import("react");
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
/// Runs `count` display frames at 120 Hz, each in its own act(), as a browser commits per frame.
const step = (count = 1) => {
  for (let index = 0; index < count; index += 1)
    act(() => {
      clock += 1000 / 120;
      for (const callback of frames.splice(0)) callback(clock);
    });
};

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
    // Commits run at 60 Hz: the first frame starts the clock, the next commit moves the text.
    step(4);
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

/// Soft reveal (acp-streaming.md "Reveal animation"): text revealed in the last moment fades in,
/// in spans the compositor animates; older text merges back into plain text.
describe("soft reveal", () => {
  test("the newest revealed characters sit in fading spans at the end, and the text reads the same", () => {
    const view = mount();
    view.render(<RevealedMarkdown text="Hi" streaming />);
    const more = "Hi there, this reply keeps arriving in one burst of many words.";
    view.render(<RevealedMarkdown text={more} streaming />);
    step(6);
    const fresh = [...view.host.querySelectorAll(".cv-fresh")];
    expect(fresh.length).toBeGreaterThan(0);
    expect(fresh.length).toBeLessThanOrEqual(24);
    const shown = view.host.textContent ?? "";
    expect(more.startsWith(shown)).toBe(true);
    expect(shown.endsWith(fresh.map((node) => node.textContent).join(""))).toBe(true);
    // Once the reveal settles and the fades have run, no span is left.
    step(200);
    expect(view.host.querySelectorAll(".cv-fresh")).toHaveLength(0);
    expect(view.host.textContent).toBe(more);
    view.root.unmount();
  });
});

/// The live edge and the commit rate (acp-streaming.md "Reveal animation").
describe("live edge", () => {
  test("a soft caret follows the newest character while the reply streams, and leaves when it ends", () => {
    const view = mount();
    view.render(<RevealedMarkdown text="Para one.\n\nStreaming now" streaming />);
    step(2);
    const caret = view.host.querySelector(".cv-caret");
    expect(caret?.getAttribute("aria-hidden")).toBe("true");
    expect(caret?.parentElement?.textContent).toContain("Streaming now");
    // Caught up and waiting for more: the edge pulses.
    step(100);
    expect(view.host.querySelector(".cv-md.is-waiting")).not.toBeNull();
    view.render(<RevealedMarkdown text="Para one.\n\nStreaming now" streaming={false} />);
    step(2);
    expect(view.host.querySelector(".cv-caret")).toBeNull();
    view.root.unmount();
  });

  test("the reveal commits at most 60 times a second on a 120 Hz display", () => {
    const view = mount();
    let commits = 0;
    const draw = (text: string) => (
      <Profiler id="reveal" onRender={() => (commits += 1)}>
        <RevealedMarkdown text={text} streaming />
      </Profiler>
    );
    view.render(draw("Hi"));
    view.render(draw("word ".repeat(200)));
    commits = 0;
    step(60);
    // 60 frames at 120 Hz is 0.5 s: about 30 commits, not 60.
    expect(commits).toBeGreaterThan(10);
    expect(commits).toBeLessThanOrEqual(32);
    view.root.unmount();
  });
});
