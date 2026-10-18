import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderStreamScript } from "../src/agent-session/acpmux/conversation/renderStreamRuntime";
import { LIVE_RENDER_FRAME_DOC, RENDER_POLICY } from "../src/agent-session/acpmux/conversation/renderFrameShell";
import { reactRenderPage } from "../src/agent-session/acpmux/conversation/renderFrameDoc";

function runtime() {
  const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
    runScripts: "outside-only",
  });
  const win = dom.window;
  const parsed: string[] = [];
  const parse = win.DOMParser.prototype.parseFromString;
  win.DOMParser.prototype.parseFromString = function (source, type) {
    parsed.push(String(source));
    return parse.call(this, source, type);
  };
  const parent = {};
  Object.defineProperty(win, "parent", { value: parent });
  const messages: Record<string, unknown>[] = [];
  Object.assign(parent, { postMessage: (data: Record<string, unknown>) => messages.push(data) });
  win.eval(renderStreamScript().slice(8, -9));
  const send = (data: Record<string, unknown>, source: unknown = parent) =>
    win.dispatchEvent(new win.MessageEvent("message", { source: source as Window, data }));
  return {
    dom,
    win,
    parsed,
    messages,
    send,
    html: (html: string, done = false) => send({ type: "cmux-render-stream", html, done }),
  };
}

test("complete appended nodes parse only the suffix and retain existing elements", () => {
  const frame = runtime();
  try {
    frame.html("<p>First</p>");
    const first = frame.win.document.querySelector("p");
    frame.html("<p>First</p><p>Second</p>");
    frame.html("<p>First</p><p>Second</p><p>Third</p>");
    expect(frame.parsed).toEqual(["<p>First</p>", "<p>Second</p>", "<p>Third</p>"]);
    expect(frame.win.document.querySelector("p")).toBe(first);
    expect(frame.win.document.body.innerHTML).toBe("<p>First</p><p>Second</p><p>Third</p>");
  } finally {
    frame.dom.window.close();
  }
});

const cases = [
  ["<p>First</p>", "<p>Second</p>", "<div>Open", " tail</div>", "<hr>"],
  ["<style>p{color:red}</style><p>First</p>", "<p>Second</p>", "<style>p{color:blue}</style>", "<p>Last</p>"],
  ["<main><p>First</p>", "<p>Second</p>", "</main>", "<footer>Last</footer>"],
  ["<p>First</p>", "<!--comment--><img onerror=bad() src=data:x>", '<a href="java&#10;script:bad()">Link</a>'],
  ["<table><tbody><tr><td>First", "<tr><td>Second</table>", "<p>Last</p>"],
  ["<p>First</p>", '<svg><path d="M0 0"></path></svg>', "<p>Last</p>"],
  ["<p>First</p>", "<script>window.bad=true</script>", "<p>Last</p>"],
  ["<p>First</p>", "<template><p>Hidden</p></template>", "<p>Last</p>"],
  ["<!doctype html><html><head><title>Page</title></head><body><p>First</p>", "<p>Second</p>", "</body></html>"],
];

test.each(cases)("append and full parse draw the same DOM: %j", (...chunks) => {
  const frame = runtime();
  let source = "";
  try {
    for (const chunk of chunks) {
      source += chunk;
      frame.html(source);
      const full = runtime();
      try {
        full.html(source);
        expect(frame.win.document.body.innerHTML).toBe(full.win.document.body.innerHTML);
        expect(frame.win.document.head.innerHTML).toBe(full.win.document.head.innerHTML);
        expect(frame.win.document.querySelector("[onerror]")).toBeNull();
      } finally {
        full.dom.window.close();
      }
    }
    frame.html("<h2>Rewritten</h2>");
    expect(frame.win.document.body.innerHTML).toBe("<h2>Rewritten</h2>");
  } finally {
    frame.dom.window.close();
  }
});

test("react prepare fetches all dependencies together, once, and only from the parent", async () => {
  const frame = runtime();
  try {
    frame.send({ type: "cmux-render-react-prepare" }, frame.win);
    expect(frame.win.document.querySelectorAll("script[src]")).toHaveLength(0);
    frame.send({ type: "cmux-render-react-prepare", errorText: "Load failed" });
    const scripts = [...frame.win.document.querySelectorAll<HTMLScriptElement>("script[src]")];
    expect(scripts).toHaveLength(3);
    expect(scripts.map((script) => script.async)).toEqual([false, false, false]);
    expect(scripts.map((script) => script.src)).toEqual([
      "https://unpkg.com/react@18.3.1/umd/react.production.min.js",
      "https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js",
      "https://unpkg.com/@babel/standalone@7.26.4/babel.min.js",
    ]);
    frame.send({ type: "cmux-render-react-prepare" });
    expect(frame.win.document.querySelectorAll("script[src]")).toHaveLength(3);
    scripts.forEach((script) => script.dispatchEvent(new frame.win.Event("load")));
    await Promise.resolve();
  } finally {
    frame.dom.window.close();
  }
});

test("the static shell is ready without a document replacement and keeps the same policy", async () => {
  const messages: Record<string, unknown>[] = [];
  const dom = new JSDOM(LIVE_RENDER_FRAME_DOC, {
    runScripts: "outside-only",
    pretendToBeVisual: true,
    beforeParse(win) {
      Object.defineProperty(win, "parent", {
        value: { postMessage: (data: Record<string, unknown>) => messages.push(data) },
      });
      Object.assign(win, {
        ResizeObserver: class {
          observe() {}
        },
      });
    },
  });
  try {
    for (const script of dom.window.document.querySelectorAll("script")) dom.window.eval(script.textContent!);
    await new Promise((resolve) => dom.window.addEventListener("load", resolve, { once: true }));
    expect(messages.filter((message) => message.type === "cmux-render-stream-ready")).toHaveLength(1);
    expect(messages.some((message) => message.type === "cmux-render-ready")).toBe(false);
    expect(dom.window.document.head.firstElementChild?.getAttribute("content")).toBe(RENDER_POLICY);
    expect(typeof (dom.window as unknown as { cmux: { sendPrompt: unknown } }).cmux.sendPrompt).toBe("function");
  } finally {
    dom.window.close();
  }
});

test("each component page compiles and mounts its source", async () => {
  const frame = runtime();
  try {
    frame.win.document.body.innerHTML = '<div id="root"></div>';
    let transforms = 0;
    let transformedSource = "";
    Object.assign(frame.win, {
      __cmuxReactReady: Promise.resolve(),
      Babel: {
        transform(source: string) {
          transformedSource = source;
          transforms++;
          return { code: 'document.getElementById("root").textContent = "Painted"' };
        },
      },
    });
    const script = new JSDOM(reactRenderPage("function App() { return <svg />; }")).window.document.querySelector(
      "script",
    )!.textContent!;
    frame.win.eval(script);
    await new Promise((resolve) => setTimeout(resolve, 0));
    frame.win.eval(script);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(transforms).toBe(2);
    expect(transformedSource).toContain("}\nReactDOM.createRoot");
    expect(frame.win.document.getElementById("root")?.textContent).toBe("Painted");
  } finally {
    frame.dom.window.close();
  }
});

test("sizing keeps its observer, coalesces mutations, and suppresses unchanged heights", async () => {
  const callbacks: (() => void)[] = [];
  const frames: FrameRequestCallback[] = [];
  const observed: unknown[] = [];
  const messages: { type: string; height?: number }[] = [];
  const dom = new JSDOM(LIVE_RENDER_FRAME_DOC, { runScripts: "outside-only" });
  const win = dom.window;
  Object.defineProperty(win, "parent", {
    value: { postMessage: (data: { type: string; height?: number }) => messages.push(data) },
  });
  win.requestAnimationFrame = (callback) => {
    frames.push(callback);
    return frames.length;
  };
  Object.assign(win, {
    ResizeObserver: class {
      constructor(callback: () => void) {
        callbacks.push(callback);
      }
      observe(node: unknown) {
        observed.push(node);
      }
      disconnect() {
        throw new Error("The observer must stay installed");
      }
    },
  });
  try {
    win.document.body.innerHTML = "<p>Page</p>";
    let height = 200;
    win.document.querySelector("p")!.getBoundingClientRect = () => ({ top: 0, bottom: height, height }) as DOMRect;
    for (const script of win.document.querySelectorAll("script")) win.eval(script.textContent!);
    await new Promise((resolve) => win.addEventListener("load", resolve, { once: true }));
    const flush = () => frames.splice(0).forEach((callback) => callback(0));
    expect(observed).toEqual([win.document.body]);
    expect(frames).toHaveLength(1);
    flush();
    const sizes = () => messages.filter((message) => message.type === "cmux-render-content-size");
    expect(sizes()).toHaveLength(1);
    for (let index = 0; index < 10; index++) callbacks.forEach((callback) => callback());
    expect(frames).toHaveLength(1);
    flush();
    expect(sizes()).toHaveLength(1);
    height = 250;
    win.document.querySelector("p")!.textContent = "More content";
    await Promise.resolve();
    callbacks.forEach((callback) => callback());
    expect(frames).toHaveLength(1);
    flush();
    expect(sizes()).toHaveLength(2);
    expect(sizes()[1]!.height! - sizes()[0]!.height!).toBe(50);
    expect(observed).toEqual([win.document.body, win.document.querySelector("p")]);
  } finally {
    win.close();
  }
});

test.each(["cssom", "class", "details"])(
  "fixed-height bodies resize through ResizeObserver after %s changes",
  async (change) => {
    const dom = new JSDOM(LIVE_RENDER_FRAME_DOC, { runScripts: "outside-only" });
    const win = dom.window;
    const frames: FrameRequestCallback[] = [];
    const targets = new Set<unknown>();
    const messages: { type: string; height?: number }[] = [];
    let resized = () => {};
    Object.defineProperty(win, "parent", {
      value: { postMessage: (data: { type: string; height?: number }) => messages.push(data) },
    });
    win.requestAnimationFrame = (callback) => {
      frames.push(callback);
      return frames.length;
    };
    Object.assign(win, {
      ResizeObserver: class {
        constructor(callback: () => void) {
          resized = callback;
        }
        observe(node: unknown) {
          targets.add(node);
        }
        unobserve(node: unknown) {
          targets.delete(node);
        }
      },
    });
    try {
      win.document.body.style.height = "150px";
      win.document.body.innerHTML = "<details><summary>Page</summary><p>More</p></details>";
      const child = win.document.querySelector("details")!;
      let height = 120;
      child.getBoundingClientRect = () => ({ top: 0, bottom: height, height }) as DOMRect;
      for (const script of win.document.querySelectorAll("script")) win.eval(script.textContent!);
      await new Promise((resolve) => win.addEventListener("load", resolve, { once: true }));
      const flush = () => frames.splice(0).forEach((callback) => callback(0));
      flush();
      const sizes = () => messages.filter((message) => message.type === "cmux-render-content-size");
      expect(sizes()).toHaveLength(1);
      // Attribute churn does not measure; layout growth comes from ResizeObserver.
      child.className = "animated";
      await Promise.resolve();
      expect(frames).toHaveLength(0);
      if (change === "class") child.className = "taller";
      if (change === "details") child.open = true;
      await Promise.resolve();
      expect(frames).toHaveLength(0);
      height = 400;
      if (targets.has(child)) resized();
      flush();
      expect(sizes()).toHaveLength(2);
      expect(sizes()[1]!.height! - sizes()[0]!.height!).toBe(280);
    } finally {
      win.close();
    }
  },
);
