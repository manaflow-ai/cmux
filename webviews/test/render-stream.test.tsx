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
const { Markdown, mergeRenderBlocks, parseMarkdown } = await import("../src/agent-session/acpmux/conversation/Markdown");

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
  expect(posted.at(-1)).toEqual({ type: "cmux-render-stream", html: "<p>First second third</p>", done: true,
  });
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
  expect(host.querySelector("iframe") === null).toBe(true);
  expect(host.querySelector(".acpmux-render-card")).toBeNull();
  expect(host.querySelector("pre")?.textContent).toContain("<h1>Building</h1>");
});

test("a component reserves no space or source while open and runs only when closed", async () => {
  const code = "function App() { return <button>Pick</button>; }";
  draw(code, { lang: "cmux-react" });
  const { frame, posted } = messages();
  expect(host.querySelector<HTMLElement>(".acpmux-render-card")?.style.display).toBe("none");
  expect(host.querySelector("pre")).toBeNull();
  expect(host.textContent).toBe("");
  expect(posted.some((message) => message.type === "cmux-render-react-prepare")).toBe(true);
  expect(posted.some((message) => message.type === "cmux-render-stream")).toBe(false);
  draw(code, { lang: "cmux-react", closed: true });
  expect(host.querySelector("iframe")).toBe(frame);
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
  expect(host.querySelector("iframe") === null).toBe(true);
});

test("stopping an open React fence removes its prepared frame", () => {
  draw("function App() {", { lang: "cmux-react" });
  const { posted } = messages();
  expect(posted.some((message) => message.type === "cmux-render-react-prepare")).toBe(true);
  draw("function App() {", { lang: "cmux-react", streaming: false });
  expect(host.querySelector("iframe") === null).toBe(true);
  expect(host.textContent).toBe("");
});

test.each([
  (page: string) => page,
  (page: string) => page.split("\n").map((line) => `> ${line}`).join("\n"),
  (page: string) => "- Page\n" + page.split("\n").map((line) => `  ${line}`).join("\n"),
])("a stopped React fence stays unmounted while its prose reveal catches up: %#", async (nested) => {
  const { RevealedMarkdown, revealFrames } = await import("../src/agent-session/acpmux/conversation/RevealedMarkdown");
  const saved = { ...revealFrames };
  revealFrames.request = () => 1;
  revealFrames.cancel = () => {};
  try {
    const start = nested("```cmux-react\nfunction App() {");
    act(() => root!.render(<RevealedMarkdown text={start} streaming />));
    expect(host.querySelector("iframe") !== null).toBe(true);
    act(() => root!.render(<RevealedMarkdown text={start + " return null;"} streaming={false} />));
    expect(host.querySelector("iframe") === null).toBe(true);
  } finally {
    Object.assign(revealFrames, saved);
  }
});

test("a completed React fence does not send an eager prepare request", () => {
  draw("function App() { return null; }", { lang: "cmux-react", closed: true, streaming: false });
  const { posted } = messages();
  expect(posted.some((message) => message.type === "cmux-render-react-prepare")).toBe(false);
  expect(posted.at(-1)?.done).toBe(true);
});

test("received renders wait for every preceding block and keep their frame at their turn", () => {
  const received = "First.\n\nSecond.\n\n```cmux-render\n<p>Page</p>\n```";
  const show = (text: string) => act(() =>
    root!.render(<Markdown streaming receivedText={received}>{text}</Markdown>),
  );
  show("First.");
  expect(host.querySelector("iframe") === null).toBe(true);
  show("First.\n\nSecond");
  const frame = host.querySelector("iframe");
  expect(frame).not.toBeNull();
  expect([...host.querySelector(".cv-md")!.children].map((node) => node.tagName)).toEqual(["P", "P", "DIV"]);
  show(received);
  expect(host.querySelector("iframe")).toBe(frame);
});

test("an appended received render leaves the last revealed ordinary fence open", () => {
  const shown = "```js\nconst value = 1";
  const received = shown + "\n```\n\n```cmux-render\n<p>Page</p>";
  act(() => root!.render(<Markdown streaming receivedText={received}>{shown}</Markdown>));
  expect(host.querySelector("iframe")).not.toBeNull();
  expect(host.querySelector(".cv-code-handoff") === null).toBe(true);
  expect(host.querySelector("pre")?.textContent).toContain("const value = 1");
});

test.each([
  "> ```cmux-render\n> <p>Page</p>\n> ```",
  "- Page\n  ```cmux-render\n  <p>Page</p>\n  ```",
])("unchanged nested render merges preserve block and array identity: %s", (text) => {
  const shown = parseMarkdown(text);
  const merged = mergeRenderBlocks(shown, parseMarkdown(text));
  expect(merged).toBe(shown);
  expect(merged[0]).toBe(shown[0]);
});

test.each([
  ["> Intro", "> Intro\n>\n> Earlier.\n>\n> ```cmux-render\n> <p>Page</p>"],
  ["- Intro", "- Intro\n\n  Earlier.\n\n  ```cmux-render\n  <p>Page</p>"],
])("nested renders never skip unrevealed children or leave sparse arrays: %s", (shown, received) => {
  const blocks = mergeRenderBlocks(parseMarkdown(shown), parseMarkdown(received));
  const block = blocks[0]!;
  const children = block.type === "blockquote" ? block.children : block.type === "list" ? block.items[0]!.children : [];
  expect(children.length).toBe(Object.keys(children).length);
  expect(children.some((child) => child.type === "code")).toBe(false);
  act(() => root!.render(<Markdown streaming receivedText={received}>{shown}</Markdown>));
  expect(host.querySelector("iframe") === null).toBe(true);
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
    expect(posted.at(-1)).toEqual({ type: "cmux-render-stream", html: "<p>First second</p>", done: true,
    });
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
    await send(
      '<a href="&#1;java&#10;script:alert(1)">Newline</a><a href="java&#9;scr&#13;ipt:alert(1)">Tabs</a><a href="https://example.com">Safe</a>',
    );
    expect([...win.document.querySelectorAll("a")].map((node) => node.getAttribute("href"))).toEqual([
      null,
      null,
      "https://example.com",
    ]);
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

test("received fences feed immediately while prose still waits for reveal", async () => {
  const { RevealedMarkdown, revealFrames } = await import("../src/agent-session/acpmux/conversation/RevealedMarkdown");
  const saved = { ...revealFrames };
  revealFrames.request = () => 1;
  revealFrames.cancel = () => {};
  try {
    act(() => root!.render(<RevealedMarkdown text="Intro" streaming />));
    const received = "Intro before the page.\n\n```cmux-render\n<p>Received</p>";
    act(() => root!.render(<RevealedMarkdown text={received} streaming />));
    expect(host.querySelector("iframe")).not.toBeNull();
    expect(host.querySelector("p")?.textContent).toBe("Intro");
    const { frame, posted } = messages();
    expect(posted.at(-1)).toEqual({
      type: "cmux-render-stream",
      html: "<p>Received</p>",
      done: false,
    });
    act(() => root!.render(<RevealedMarkdown text={received + "\n```\n\nLater prose"} streaming />));
    await wait(85);
    expect(host.querySelector("iframe")).toBe(frame);
    expect(posted.at(-1)).toEqual({
      type: "cmux-render-stream",
      html: "<p>Received</p>",
      done: true,
    });
    expect(host.textContent).not.toContain("Later prose");
  } finally {
    Object.assign(revealFrames, saved);
  }
});

test.each([
  ["> Intro", "> Intro before the page.\n>\n> ```cmux-render\n> <p>Quoted</p>"],
  ["- Intro", "- Intro before the page.\n\n  ```cmux-render\n  <p>Listed</p>"],
])("received nested fences bypass reveal without exposing nested prose: %s", async (initial, received) => {
  const { RevealedMarkdown, revealFrames } = await import("../src/agent-session/acpmux/conversation/RevealedMarkdown");
  const saved = { ...revealFrames };
  revealFrames.request = () => 1;
  revealFrames.cancel = () => {};
  try {
    act(() => root!.render(<RevealedMarkdown text={initial} streaming />));
    act(() => root!.render(<RevealedMarkdown text={received} streaming />));
    expect(host.querySelector("iframe")).not.toBeNull();
    expect(host.textContent).not.toContain("before the page");
    expect(host.textContent).toContain("Intro");
    const { posted } = messages();
    expect(posted.at(-1)?.html).toMatch(/<p>(Quoted|Listed)<\/p>/);
  } finally {
    Object.assign(revealFrames, saved);
  }
});

test.each(["cmux-render", "cmux-react"])(
  "partial closing delimiters never enter the received %s page",
  async (lang) => {
    const { RevealedMarkdown, revealFrames } =
      await import("../src/agent-session/acpmux/conversation/RevealedMarkdown");
    const saved = { ...revealFrames };
    revealFrames.request = () => 1;
    revealFrames.cancel = () => {};
    const code = lang === "cmux-render" ? "<p>Page</p>" : "function App() { return <svg />; }";
    try {
      const prefix = "```" + lang + "\n" + code;
      act(() => root!.render(<RevealedMarkdown text={prefix} streaming />));
      const { frame, posted } = messages();
      for (const ticks of ["`", "``"]) {
        act(() => root!.render(<RevealedMarkdown text={prefix + "\n" + ticks} streaming />));
        await wait(85);
        expect(
          posted
            .filter((message) => message.type === "cmux-render-stream")
            .some((message) => message.html.endsWith("`")),
        ).toBe(false);
        expect(host.querySelector("iframe")).toBe(frame);
      }
      act(() => root!.render(<RevealedMarkdown text={prefix + "\n```"} streaming />));
      await wait(85);
      expect(posted.at(-1)?.done).toBe(true);
      expect(host.querySelector("iframe")).toBe(frame);
    } finally {
      Object.assign(revealFrames, saved);
    }
  },
);
