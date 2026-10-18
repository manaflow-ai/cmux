// Partial pages stay inert until their fence closes (Lucas 2026-10-18).
import { afterAll, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://127.0.0.1:4276/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  addEventListener: dom.window.addEventListener.bind(dom.window),
  removeEventListener: dom.window.removeEventListener.bind(dom.window),
  document: dom.window.document,
  location: dom.window.location,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// The code card's highlighter (@pierre/diffs) defines its elements, which read DOM constructors, on import.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const { createRoot } = await import("react-dom/client");
const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");

beforeEach(() => {
  act(() => root?.unmount());
  root = createRoot(host);
  document.documentElement.setAttribute("data-lab-live-render", "on");
});

function draw(html: string, { closed = false, live = true, lang = "cmux-render", streaming = true } = {}) {
  document.documentElement.setAttribute("data-lab-live-render", live ? "on" : "off");
  act(() =>
    root!.render(<Markdown streaming={streaming}>{"```" + lang + "\n" + html + (closed ? "\n```" : "")}</Markdown>),
  );
}

const wait = (ms = 180) =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, ms));
  });

function messages() {
  const frame = host.querySelector("iframe")!;
  const posted: { type: string; html: string; done?: boolean }[] = [];
  frame.contentWindow!.postMessage = (data) => posted.push(data);
  const receive = (type: string) =>
    act(() => {
      dom.window.dispatchEvent(new dom.window.MessageEvent("message", { source: frame.contentWindow, data: { type } }));
    });
  receive("cmux-render-ready");
  receive("cmux-render-stream-ready");
  return { frame, posted, receive };
}

test("one frame posts growing HTML, coalesces tokens, and finalizes once without chrome", async () => {
  draw("<p>First");
  const { frame, posted, receive } = messages();
  expect(posted[0]?.type).toBe("cmux-render");
  expect(posted[0]?.html).toContain("window.cmux");
  expect(posted[0]?.html).not.toContain("<p>First");
  expect(host.querySelector(".acpmux-render-card-head")).toBeNull();
  expect(host.querySelector("button")).toBeNull();
  await wait(65);
  expect(posted.at(-1)).toEqual({ type: "cmux-render-stream", html: "<p>First", done: false });
  draw("<p>First second");
  draw("<p>First second third");
  await wait(65);
  expect(posted.filter((msg) => msg.type === "cmux-render-stream")).toHaveLength(2);
  expect(posted.at(-1)?.html).toBe("<p>First second third");
  draw("<p>First second third</p>", { closed: true });
  await wait(65);
  expect(host.querySelector("iframe")).toBe(frame);
  expect(posted.at(-1)).toEqual({ type: "cmux-render-stream", html: "<p>First second third</p>", done: true });
  const count = posted.filter((msg) => msg.type !== "cmux-render-theme").length;
  receive("cmux-render-ready");
  draw("<p>First second third</p>", { closed: true });
  await wait(65);
  expect(posted.filter((msg) => msg.type !== "cmux-render-theme")).toHaveLength(count);
});

test("a rewrite sends the whole replacement into the same frame", async () => {
  draw("<p>Old");
  const { frame, posted } = messages();
  await wait(65);
  draw("<h2>New");
  await wait(65);
  expect(posted.at(-1)?.html).toBe("<h2>New");
  expect(host.querySelector("iframe")).toBe(frame);
});

test("a whole tool page posts done immediately after the runtime is ready", async () => {
  const { RenderCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  act(() => root!.render(<RenderCard call={{ html: "<p>Whole</p>" }} />));
  const { posted } = messages();
  await wait(65);
  expect(posted.at(-1)).toEqual({ type: "cmux-render-stream", html: "<p>Whole</p>", done: true });
});

test("with the lab off the same open fence stays code", () => {
  draw("<h1>Building</h1>", { live: false });
  expect(host.querySelector("iframe")).toBeNull();
  expect(host.querySelector(".acpmux-render-card")).toBeNull();
  expect(host.querySelector("pre")?.textContent).toContain("<h1>Building</h1>");
});

test("a component reserves no space or source while open and runs only when closed", async () => {
  const code = "function App() { return <button>Pick</button>; }";
  draw(code, { lang: "cmux-react" });
  expect(host.querySelector("iframe")).toBeNull();
  expect(host.querySelector(".acpmux-render-card")).toBeNull();
  expect(host.querySelector("pre")).toBeNull();
  expect(host.textContent).toBe("");
  draw(code, { lang: "cmux-react", closed: true });
  const { posted } = messages();
  await wait(65);
  expect(posted.at(-1)?.html).toContain("Babel.transform");
  expect(posted.at(-1)?.done).toBe(true);
});

test("ordinary fences keep code, interrupted render fences keep their partial page", () => {
  draw("const count = 1", { lang: "js" });
  expect(host.querySelector(".acpmux-render-card")).toBeNull();
  draw("<p>Interrupted", { streaming: false });
  expect(host.querySelector("iframe") !== null).toBe(true);
  draw("function App() {", { streaming: false, lang: "cmux-react" });
  expect(host.textContent).toBe("");
});

test("the transport ending before reveal catches up retains the streaming frame", async () => {
  const { RevealedMarkdown, revealFrames } = await import("../src/agent-session/acpmux/conversation/RevealedMarkdown");
  const saved = { ...revealFrames };
  const callbacks = new Map<number, (now: number) => void>();
  let id = 0;
  revealFrames.request = (callback) => {
    callbacks.set(++id, callback);
    return id;
  };
  revealFrames.cancel = (handle) => {
    callbacks.delete(handle);
  };
  try {
    const start = "```cmux-render\n<p>First";
    act(() => root!.render(<RevealedMarkdown text={start} streaming />));
    const { frame, posted } = messages();
    const final = start + " second</p>\n```";
    act(() => root!.render(<RevealedMarkdown text={final} streaming={false} />));
    expect(host.querySelector("iframe")).toBe(frame);
    expect(host.querySelector("pre")).toBeNull();
    for (let now = 0; now < 1000; now += 20) {
      const pending = [...callbacks.values()];
      callbacks.clear();
      act(() => pending.forEach((callback) => callback(now)));
      expect(host.querySelector("iframe")).toBe(frame);
    }
    await wait(65);
    expect(posted.at(-1)).toEqual({ type: "cmux-render-stream", html: "<p>First second</p>", done: true });
  } finally {
    Object.assign(revealFrames, saved);
  }
});

test("dev frames use the other loopback host with the same port", async () => {
  const { devRenderFrameURL } = await import("../src/agent-session/acpmux/conversation/renderFrameShell");
  expect(devRenderFrameURL("http://127.0.0.1:4276/?mock#tail")).toBe("http://localhost:4276/__cmux-render-frame");
  expect(devRenderFrameURL("http://localhost:4276/?mock")).toBe("http://127.0.0.1:4276/__cmux-render-frame");
});

test("the runtime preserves growing nodes, strips partial scripts, then executes each once in order", async () => {
  const { renderStreamScript } = await import("../src/agent-session/acpmux/conversation/renderStreamRuntime");
  const child = new JSDOM("<!doctype html><html><head></head><body></body></html>");
  const win = child.window;
  const parent = { postMessage() {} };
  const order: string[] = [];
  const script = renderStreamScript().slice("<script>".length, -"</script>".length);
  const appended = win.Element.prototype.append;
  const replaced = win.Element.prototype.replaceWith;
  const run = (node: unknown) => {
    if (!(node instanceof win.HTMLScriptElement) || node.type === "application/cmux-inert") return;
    if (node.src) {
      order.push(node.src);
      queueMicrotask(() => node.dispatchEvent(new win.Event("load")));
    } else {
      // oxlint-disable-next-line typescript/no-implied-eval -- Execute the final agent script on insertion, as a browser does.
      new Function("order", "document", node.textContent!)(order, win.document);
    }
  };
  win.Element.prototype.append = function (...nodes) {
    appended.apply(this, nodes);
    nodes.forEach(run);
  };
  win.Element.prototype.replaceWith = function (...nodes) {
    replaced.apply(this, nodes);
    nodes.forEach(run);
  };
  try {
    // oxlint-disable-next-line typescript/no-implied-eval -- Run the emitted runtime against JSDOM with explicit browser bindings.
    new Function("window", "document", "parent", "addEventListener", "DOMParser", "Event", script)(
      win,
      win.document,
      parent,
      win.addEventListener.bind(win),
      win.DOMParser,
      win.Event,
    );
    const send = async (html: string, done = false, source: unknown = parent) => {
      win.dispatchEvent(
        new win.MessageEvent("message", {
          source: source as Window,
          data: { type: "cmux-render-stream", html, done },
        }),
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    };
    await send("<p>Forged</p>", false, win);
    expect(win.document.body.innerHTML).toBe("");
    await send('<style>p{color:red}</style><p>First</p><script>order.push("partial")</script>');
    const paragraph = win.document.querySelector("p");
    const style = win.document.querySelector("style");
    expect(order).toEqual([]);
    expect(win.document.body.querySelector("script")).toBeNull();
    await send('<style>p{color:red}</style><p>First second</p><img onerror="bad()">');
    expect(win.document.querySelector("p")).toBe(paragraph);
    expect(paragraph?.textContent).toBe("First second");
    expect(win.document.querySelector("style")).toBe(style);
    expect(win.document.querySelector("img")?.hasAttribute("onerror")).toBe(false);
    await send("<h2>Rewritten</h2>");
    expect(win.document.querySelector("p")).toBeNull();
    const final =
      '<script>order.push("head"); document.addEventListener("DOMContentLoaded", () => order.push("ready"))</script><h2>Final</h2><script src="https://unpkg.com/example.js"></script><script>order.push("body")</script>';
    await send(final, true);
    expect(order).toEqual(["head", "https://unpkg.com/example.js", "body", "ready"]);
    await send(final, true);
    expect(order).toHaveLength(4);
  } finally {
    child.window.close();
  }
});
