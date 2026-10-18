// The live-render lab keeps page requests inside the card until the reader confirms.
import { afterAll, expect, test } from "bun:test";
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

const sent: string[] = [];
const prefilled: string[] = [];
const opened: string[] = [];
const PAGE = "<title>Interactive page</title><p>Ready</p>";

async function draw(live = true, markdown = `\`\`\`cmux-render\n${PAGE}\n\`\`\``) {
  act(() => root?.unmount());
  document.documentElement.toggleAttribute("data-lab-live-render", false);
  if (live) document.documentElement.setAttribute("data-lab-live-render", "on");
  sent.length = prefilled.length = opened.length = 0;
  const { createRoot } = await import("react-dom/client");
  const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
  const { RenderBridgeContext } = await import("../src/agent-session/acpmux/conversation/RenderBridgeContext");
  root = createRoot(host);
  act(() =>
    root!.render(
      <RenderBridgeContext.Provider
        value={{
          prefill: (text) => {
            prefilled.push(text);
          },
          send: (text) => {
            sent.push(text);
          },
          openLink: (url) => {
            opened.push(url);
          },
        }}
      >
        <Markdown>{markdown}</Markdown>
      </RenderBridgeContext.Provider>,
    ),
  );
  const frame = host.querySelector("iframe");
  const replies: Record<string, unknown>[] = [];
  const target = frame?.contentWindow;
  if (target)
    target.postMessage = (message) => {
      replies.push(message);
    };
  const request = (method: string, params: unknown, source: unknown = target, id = "1") => {
    void act(() =>
      dom.window.dispatchEvent(
        new dom.window.MessageEvent("message", {
          source: source as Window,
          data: { type: "cmux-render-request", id, method, params },
        }),
      ),
    );
  };
  return { frame, target, replies, request };
}

function click(text: string) {
  const button = [...host.querySelectorAll("button")].find((button) => button.textContent === text)!;
  expect(button).toBeDefined();
  act(() => button.click());
}

test("lab off keeps dev fences as source, lab on auto-runs an opaque srcdoc frame with Stop", async () => {
  await draw(false);
  expect(host.querySelector("iframe")).toBeNull();
  expect(host.querySelector(".acpmux-render-card")).toBeNull();
  const { frame } = await draw();
  expect(frame!.getAttribute("sandbox")).toBe("allow-scripts");
  expect(frame!.getAttribute("src")).toBeNull();
  const doc = new JSDOM(frame!.srcdoc).window.document;
  expect(doc.head.firstElementChild?.getAttribute("http-equiv")).toBe("Content-Security-Policy");
  expect([...host.querySelectorAll("button")].some((button) => button.textContent === "Run")).toBe(false);
  click("Stop");
  expect(host.querySelector("iframe")).toBeNull();
  click("Run");
  expect(host.querySelector("iframe")).not.toBeNull();
});

test("another window cannot forge requests, ready or height messages", async () => {
  const { request, replies, frame } = await draw();
  request("sendPrompt", { text: "Forged" }, dom.window);
  request("prefill", { text: "Forged" }, dom.window);
  void act(() =>
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: dom.window as unknown as Window,
        data: { type: "cmux-render-ready" },
      }),
    ),
  );
  expect(host.querySelector(".acpmux-render-confirm")).toBeNull();
  expect(prefilled).toEqual([]);
  expect(replies).toEqual([]);
  expect(frame!.style.height).toBe("120px");
});

test("sendPrompt waits for Send in the pane; Edit prefills without sending", async () => {
  let card = await draw();
  card.request("sendPrompt", { text: "Use sage" });
  expect(host.querySelector(".acpmux-render-confirm")?.textContent).toContain("Use sage");
  expect(sent).toEqual([]);
  click("Send");
  expect(sent).toEqual(["Use sage"]);
  card = await draw();
  card.request("sendPrompt", { text: "Use amber" });
  click("Edit");
  expect(prefilled).toEqual(["Use amber"]);
  expect(sent).toEqual([]);
});

test("a new request replaces the pending confirmation; Stop cancels it", async () => {
  const { request, replies } = await draw();
  request("sendPrompt", { text: "Old" }, undefined, "old");
  request("sendPrompt", { text: "New" }, undefined, "new");
  expect(replies).toContainEqual({ type: "cmux-render-reply", id: "old", ok: false, error: "replaced" });
  click("Stop");
  expect(host.querySelector(".acpmux-render-confirm")).toBeNull();
  expect(replies).toContainEqual({ type: "cmux-render-reply", id: "new", ok: false, error: "cancelled" });
  expect(sent).toEqual([]);
});

test("text, URLs, method names and request rate are bounded", async () => {
  const { request, replies } = await draw();
  request("sendPrompt", { text: "x".repeat(4001) });
  request("prefill", { text: 42 });
  request("browser.open", { url: "https://example.com" });
  request("openLink", { url: "javascript:alert(1)" });
  request("openLink", { url: "http://example.com" });
  request("prefill", { text: "Too fast" });
  expect(replies).toHaveLength(6);
  expect(replies.every((reply) => reply.ok === false)).toBe(true);
  expect(replies.at(-1)?.error).toBe("rate limit");
  expect(prefilled).toEqual([]);
  expect(opened).toEqual([]);
});

test("https links wait for Open, and prefill calls the pane hook", async () => {
  const { request } = await draw();
  request("prefill", { text: "Before the draft" });
  expect(prefilled).toEqual(["Before the draft"]);
  request("openLink", { url: "https://example.com/path" });
  expect(opened).toEqual([]);
  click("Open");
  expect(opened).toEqual(["https://example.com/path"]);
});

test("state round-trips across virtualization and refuses JSON above 64 KB", async () => {
  let card = await draw();
  card.request("state.set", { value: { color: "sage", count: 2 } });
  card = await draw();
  card.request("state.get", {});
  expect(card.replies.at(-1)).toEqual({
    type: "cmux-render-reply",
    id: "1",
    ok: true,
    value: { color: "sage", count: 2 },
  });
  card.request("state.set", { value: "界".repeat(22000) });
  expect(card.replies.at(-1)?.ok).toBe(false);
  card.request("state.get", {});
  expect(card.replies.at(-1)?.value).toEqual({ color: "sage", count: 2 });
});

test("component fences and marked tool HTML compile inside the frame with pinned scripts", async () => {
  const { target, replies } = await draw(true, "```cmux-react\nfunction App() { return <button>+</button>; }\n```");
  void act(() =>
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", { source: target, data: { type: "cmux-render-ready" } }),
    ),
  );
  const html = replies[0]!.html as string;
  const page = new JSDOM(html).window.document;
  expect(page.querySelector("#root")).not.toBeNull();
  expect(html).toContain("react@18.3.1/umd/react.production.min.js");
  expect(html).toContain("react-dom@18.3.1/umd/react-dom.production.min.js");
  expect(html).toContain("@babel/standalone@7.26.4/babel.min.js");
  expect(html.indexOf("window.cmux")).toBeLessThan(html.indexOf("Babel.transform"));
  const { artifactKind } = await import("../src/agent-session/acpmux/conversation/artifactPreview");
  expect(artifactKind("cmux-react", "function App() {}")).toBe("react");
  await draw(false, "```cmux-react\nfunction App() {}\n```");
  expect(artifactKind("cmux-react", "function App() {}")).toBeUndefined();
  expect(host.querySelector("iframe")).toBeNull();
});

test("theme changes are posted without replacing the frame", async () => {
  const { frame, replies } = await draw();
  await act(async () => {
    document.body.style.colorScheme = "dark";
  });
  expect(host.querySelector("iframe")).toBe(frame);
  expect(replies.at(-1)?.type).toBe("cmux-render-theme");
  expect(replies.at(-1)?.theme).toBe("dark");
});

test("the side panel uses the same opaque dev frame for markup and components", async () => {
  await draw();
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  for (const artifact of [
    { kind: "html" as const, lang: "html", code: PAGE },
    { kind: "react" as const, lang: "cmux-react", code: "function App() { return <button>+</button>; }" },
  ]) {
    act(() => root!.render(<ArtifactPanel key={artifact.kind} artifact={artifact} onClose={() => {}} />));
    const frame = host.querySelector("iframe")!;
    expect(frame.srcdoc).toContain("Content-Security-Policy");
    expect(frame.getAttribute("sandbox")).toBe("allow-scripts");
    expect(frame.className).toBe("acpmux-artifact-frame");
    expect([...host.querySelectorAll("button")].some((button) => button.textContent === "Stop")).toBe(true);
  }
});

test("the native frame URL stays in use and receives the bridge before marked component HTML", async () => {
  dom.reconfigure({ url: "cmux-agent://pane/index.html" });
  try {
    const { target, frame, replies } = await draw(
      true,
      "```cmux-react\nfunction App() { return <output>1</output>; }\n```",
    );
    expect(frame!.getAttribute("src")).toBe("cmux-agent://render/frame");
    expect(frame!.getAttribute("srcdoc")).toBeNull();
    void act(() =>
      dom.window.dispatchEvent(
        new dom.window.MessageEvent("message", { source: target, data: { type: "cmux-render-ready" } }),
      ),
    );
    expect((replies[0]!.html as string).startsWith("<!doctype html><script>")).toBe(true);
    expect((replies[0]!.html as string).indexOf("window.cmux")).toBeLessThan(
      (replies[0]!.html as string).indexOf("Babel.transform"),
    );
  } finally {
    dom.reconfigure({ url: "http://127.0.0.1:4276/" });
  }
});

test("copy uses the pane clipboard helper and reports success", async () => {
  const card = await draw();
  const clipboard = Object.getOwnPropertyDescriptor(navigator, "clipboard");
  const copies: string[] = [];
  Object.defineProperty(navigator, "clipboard", {
    configurable: true,
    value: {
      writeText: async (text: string) => {
        copies.push(text);
      },
    },
  });
  try {
    await act(async () => {
      card.request("copy", { text: "A copied choice" });
    });
    expect(copies).toEqual(["A copied choice"]);
    expect(host.querySelector(".acpmux-render-note")?.textContent).toBe("Copied");
    expect(card.replies.at(-1)?.ok).toBe(true);
  } finally {
    if (clipboard) Object.defineProperty(navigator, "clipboard", clipboard);
    else Reflect.deleteProperty(navigator, "clipboard");
  }
});

test("the injected bridge resolves replies and updates its theme style in place", async () => {
  const { renderBridgeScript } = await import("../src/agent-session/acpmux/conversation/renderFrameDoc");
  const child = new JSDOM(renderBridgeScript("light", "body{color:red}"));
  try {
    const win = child.window;
    const requests: Record<string, unknown>[] = [];
    win.postMessage = (data) => {
      requests.push(data);
    };
    // Bun cannot run jsdom's vm context. Execute the emitted script against its real DOM instead.
    // oxlint-disable-next-line typescript/no-implied-eval -- Execute the emitted frame script with explicit DOM bindings in this harness.
    new Function("window", "document", "parent", "addEventListener", win.document.querySelector("script")!.textContent)(
      win,
      win.document,
      win,
      win.addEventListener.bind(win),
    );
    let seen = "";
    win.cmux.onTheme((theme: { mode: string }) => {
      seen = theme.mode;
    });
    const result = win.cmux.state.get();
    expect(requests[0]?.method).toBe("state.get");
    win.dispatchEvent(
      new win.MessageEvent("message", {
        source: win as unknown as Window,
        data: { type: "cmux-render-reply", id: requests[0]!.id, ok: true, value: { count: 3 } },
      }),
    );
    expect(await result).toEqual({ count: 3 });
    const style = win.document.querySelector("style");
    win.dispatchEvent(
      new win.MessageEvent("message", {
        source: win as unknown as Window,
        data: { type: "cmux-render-theme", theme: "dark", css: "body{color:white}" },
      }),
    );
    expect(seen).toBe("dark");
    expect(win.cmux.theme.mode).toBe("dark");
    expect(win.document.querySelector("style")).toBe(style);
    expect(style?.textContent).toBe("body{color:white}");
  } finally {
    child.window.close();
  }
});
