// The live-render lab keeps page requests inside the card until the reader confirms.
import { afterAll, beforeEach, expect, spyOn, test } from "bun:test";
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
const { ChatSessionContext, RenderLiveContext } = await import("../src/agent-session/acpmux/conversation/viewIdentity");
const { ranRenders } = await import("../src/agent-session/acpmux/conversation/RenderCard");
const PAGE = "<title>Interactive page</title><p>Ready</p>";

let testSession = 0;
let now = Date.now();
const clock = spyOn(Date, "now").mockImplementation(() => now);
afterAll(() => clock.mockRestore());
beforeEach(() => {
  testSession++;
  ranRenders.clear();
});

async function draw(
  live = true,
  markdown = `\`\`\`cmux-render\n${PAGE}\n\`\`\``,
  sessionId = `live-test-${testSession}`,
  turnStreaming = true,
  openResult: () => boolean | Promise<boolean> = () => true,
  renderLive: boolean | { attachment: number } = turnStreaming,
) {
  act(() => root?.unmount());
  document.documentElement.setAttribute("data-lab-live-render", live ? "on" : "off");
  sent.length = prefilled.length = opened.length = 0;
  const { createRoot } = await import("react-dom/client");
  const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
  const { renderAttachment } = await import("../src/agent-session/acpmux/conversation/renderExecution");
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
            return openResult();
          },
        }}
      >
        <ChatSessionContext.Provider value={sessionId}>
          <RenderLiveContext.Provider
            value={
              typeof renderLive === "object"
                ? renderLive
                : renderLive
                  ? { attachment: renderAttachment(sessionId) }
                  : false
            }
          >
            <Markdown turnStreaming={turnStreaming}>{markdown}</Markdown>
          </RenderLiveContext.Provider>
        </ChatSessionContext.Provider>
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

function click(text: string, settled = true) {
  if (settled) now += 501;
  const button = [...host.querySelectorAll("button")].find((button) => button.textContent === text)!;
  expect(button).toBeDefined();
  act(() => button.click());
}

test("lab off keeps dev fences as source, lab on embeds an opaque frame without controls", async () => {
  await draw(false);
  expect(host.querySelector("iframe")).toBeNull();
  expect(host.querySelector(".acpmux-render-card")).toBeNull();
  const { frame } = await draw();
  expect(frame!.getAttribute("sandbox")).toBe("allow-scripts");
  expect(frame!.getAttribute("src")).toBeNull();
  const doc = new JSDOM(frame!.srcdoc).window.document;
  expect(doc.head.firstElementChild?.getAttribute("http-equiv")).toBe("Content-Security-Policy");
  expect([...host.querySelectorAll("button")].some((button) => button.textContent === "Show visualization")).toBe(
    false,
  );
  expect(host.querySelector(".acpmux-render-card-head")).toBeNull();
  expect(
    [...host.querySelectorAll("button")].some((button) =>
      ["Stop", "Open preview", "Show visualization"].includes(button.textContent!),
    ),
  ).toBe(false);
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
  expect(frame!.style.height).toBe("0px");
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
  click("Edit in prompt");
  expect(prefilled).toEqual(["Use amber"]);
  expect(sent).toEqual([]);
});

test("a pending confirmation rejects replacements and keeps the original text", async () => {
  const { request, replies } = await draw();
  request("sendPrompt", { text: "Old" }, undefined, "old");
  request("sendPrompt", { text: "New" }, undefined, "new");
  expect(replies).toContainEqual({ type: "cmux-render-reply", id: "new", ok: false, error: "confirmation pending" });
  expect(host.querySelector(".acpmux-render-confirm-text")?.textContent).toBe("Old");
  click("Cancel");
  expect(host.querySelector(".acpmux-render-confirm") === null).toBe(true);
  expect(replies).toContainEqual({ type: "cmux-render-reply", id: "old", ok: false, error: "cancelled" });
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

test("https links and prefill wait for their pane confirmation", async () => {
  const { request } = await draw();
  request("prefill", { text: "Before the draft" });
  expect(prefilled).toEqual([]);
  expect(host.querySelector(".acpmux-render-confirm")?.textContent).toContain("Before the draft");
  expect([...host.querySelectorAll("button")].map((button) => button.textContent)).toEqual([
    "Edit in prompt",
    "Cancel",
  ]);
  click("Edit in prompt");
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
  void act(() =>
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", { source: target, data: { type: "cmux-render-stream-ready" } }),
    ),
  );
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 65));
  });
  const html = replies.find((message) => message.type === "cmux-render-stream")!.html as string;
  const page = new JSDOM(html).window.document;
  expect(page.querySelector("#root")).not.toBeNull();
  expect(html).toContain("react@18.3.1/umd/react.production.min.js");
  expect(html).toContain("react-dom@18.3.1/umd/react-dom.production.min.js");
  expect(html).toContain("@babel/standalone@7.26.4/babel.min.js");
  expect(replies[0]!.html as string).toContain("window.cmux");
  expect(replies[0]!.html as string).not.toContain("Babel.transform");
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
    await draw(
      true,
      "```" + (artifact.kind === "html" ? "cmux-render" : "cmux-react") + "\n" + artifact.code + "\n```",
    );
    act(() => root!.render(<ArtifactPanel key={artifact.kind} artifact={artifact} onClose={() => {}} />));
    click("Show visualization");
    const frame = host.querySelector("iframe")!;
    expect(frame.srcdoc).toContain("Content-Security-Policy");
    expect(frame.getAttribute("sandbox")).toBe("allow-scripts");
    expect(frame.className).toBe("acpmux-artifact-frame");
    expect(host.querySelector(".acpmux-render-card-head")).toBeNull();
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
    expect((replies[0]!.html as string).startsWith("<!doctype html><html><head><script>")).toBe(true);
    expect(replies[0]!.html as string).toContain("window.cmux");
    expect(replies[0]!.html as string).not.toContain("Babel.transform");
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
    expect(copies).toEqual([]);
    expect(host.querySelector(".acpmux-render-confirm")?.textContent).toContain("A copied choice");
    await act(async () => click("Copy"));
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
  const child = new JSDOM(renderBridgeScript("light", "body{color:red}"), { pretendToBeVisual: true });
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
    win.dispatchEvent(
      new win.MessageEvent("message", {
        source: win as unknown as Window,
        data: { type: "cmux-render-ping", id: "health-check" },
      }),
    );
    expect(requests.at(-1)).toEqual({ type: "cmux-render-pong", id: "health-check" });
  } finally {
    child.window.close();
  }
});

test("card state stays in its session across remounts", async () => {
  const page = "```cmux-render\n<p>session state</p>\n```";
  const first = await draw(true, page, "state-a");
  first.request("state.set", { value: { chosen: "B" } });
  const second = await draw(true, page, "state-b");
  second.request("state.get", {});
  expect(second.replies.at(-1)?.value).toBeNull();
  const remounted = await draw(true, page, "state-a");
  remounted.request("state.get", {});
  expect(remounted.replies.at(-1)?.value).toEqual({ chosen: "B" });
});

test("a live frame follows short content and caps tall pages at 1600px", async () => {
  const card = await draw(true, "```cmux-render\n<p>short page</p>\n```");
  expect(card.frame!.style.height).toBe("0px");
  void act(() =>
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: card.target,
        data: { type: "cmux-render-content-size", height: 32 },
      }),
    ),
  );
  expect(card.frame!.style.height).toBe("32px");
  void act(() =>
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: card.target,
        data: { type: "cmux-render-content-size", height: 5000 },
      }),
    ),
  );
  expect(card.frame!.style.height).toBe("1600px");
});

// The frame's name is for assistive tech only: a `title` attribute also shows as a native
// hover tooltip ("Preview" for an untitled render) over the whole render (Lucas 2026-10-19).
test("embedded frames retain accessible titles without a visible heading or hover tooltip", async () => {
  await draw();
  const { RenderCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  for (const [html, title] of [
    ["<title>Plan &amp; effort</title><p>Choose</p>", "Plan & effort"],
    ["<!-- cmux-react -->\n// title: Plan picker\nfunction App() { return null; }", "Plan picker"],
  ]) {
    act(() =>
      root!.render(
        <RenderLiveContext.Provider value>
          <RenderCard turnStreaming call={{ html }} />
        </RenderLiveContext.Provider>,
      ),
    );
    expect(host.querySelector(".acpmux-render-card-title")).toBeNull();
    expect(host.querySelector("iframe")?.getAttribute("aria-label")).toBe(title);
    expect(host.querySelector("iframe")?.hasAttribute("title")).toBe(false);
  }
});

test.each([
  ["top level", (page: string) => page + "\n\n" + page],
  [
    "quote",
    (page: string) =>
      (page + "\n\n" + page)
        .split("\n")
        .map((line) => `> ${line}`)
        .join("\n"),
  ],
  [
    "list item",
    (page: string) =>
      "- Pages\n" +
      (page + "\n" + page)
        .split("\n")
        .map((line) => `  ${line}`)
        .join("\n"),
  ],
  [
    "list items",
    (page: string) =>
      ["First", "Second"]
        .map(
          (name) =>
            `- ${name}\n` +
            page
              .split("\n")
              .map((line) => `  ${line}`)
              .join("\n"),
        )
        .join("\n"),
  ],
  [
    "quote in list",
    (page: string) =>
      "- Pages\n" +
      (page + "\n" + page)
        .split("\n")
        .map((line) => `  > ${line}`)
        .join("\n"),
  ],
])("identical cards at %s keep separate state", async (name, nested) => {
  await draw();
  const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
  const { TranscriptRowContext } = await import("../src/agent-session/acpmux/conversation/viewIdentity");
  const page = "```cmux-render\n<p>identical</p>\n```";
  const mount = (html: string) =>
    act(() =>
      root!.render(
        <ChatSessionContext.Provider value={`two-cards-${name}`}>
          <TranscriptRowContext.Provider value="reply">
            <RenderLiveContext.Provider value>
              <Markdown turnStreaming>{nested(html)}</Markdown>
            </RenderLiveContext.Provider>
          </TranscriptRowContext.Provider>
        </ChatSessionContext.Provider>,
      ),
    );
  mount(page);
  const frames = [...host.querySelectorAll("iframe")];
  expect(frames).toHaveLength(2);
  const replies: Record<string, unknown>[] = [];
  for (const frame of frames) frame.contentWindow!.postMessage = (data) => replies.push(data);
  const request = (index: number, method: string, params: unknown) =>
    void act(() =>
      dom.window.dispatchEvent(
        new dom.window.MessageEvent("message", {
          source: frames[index]!.contentWindow,
          data: { type: "cmux-render-request", id: "1", method, params },
        }),
      ),
    );
  request(0, "state.set", { value: "first" });
  request(1, "state.get", {});
  expect(replies.at(-1)?.value).toBeNull();
  act(() => root!.unmount());
  const { createRoot } = await import("react-dom/client");
  root = createRoot(host);
  mount(page.replace("identical", "updated"));
  expect(host.querySelectorAll("iframe")).toHaveLength(2);
  const remounted = host.querySelector("iframe")!;
  remounted.contentWindow!.postMessage = (data) => replies.push(data);
  void act(() =>
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: remounted.contentWindow,
        data: { type: "cmux-render-request", id: "2", method: "state.get", params: {} },
      }),
    ),
  );
  expect(replies.at(-1)?.value).toBe("first");
});

test("a tool card keeps its frame and state when its HTML changes under the same row id", async () => {
  await draw();
  const { RenderCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  const { TranscriptRowContext } = await import("../src/agent-session/acpmux/conversation/viewIdentity");
  const card = (html: string) => (
    <ChatSessionContext.Provider value="tool-identity">
      <TranscriptRowContext.Provider value="tool-call-1">
        <RenderLiveContext.Provider value>
          <RenderCard turnStreaming call={{ html }} />
        </RenderLiveContext.Provider>
      </TranscriptRowContext.Provider>
    </ChatSessionContext.Provider>
  );
  const mount = (html: string) => {
    act(() => root!.render(card(html)));
    const target = host.querySelector("iframe")!.contentWindow;
    const replies: Record<string, unknown>[] = [];
    target!.postMessage = (data) => replies.push(data);
    return (method: string, params: unknown) => {
      void act(() =>
        dom.window.dispatchEvent(
          new dom.window.MessageEvent("message", {
            source: target,
            data: { type: "cmux-render-request", id: "1", method, params },
          }),
        ),
      );
      return replies.at(-1);
    };
  };
  mount("<p>version one</p>")("state.set", { value: { chosen: "B" } });
  expect(mount("<p>version two</p>")("state.get", {})?.value).toEqual({ chosen: "B" });
});

test("saved card values evict the oldest entry after 200 cards", async () => {
  const { renderState, saveRenderState } = await import("../src/agent-session/acpmux/conversation/renderState");
  for (let index = 0; index < 200; index++) saveRenderState(`bounded-${index}`, index);
  expect(renderState("bounded-0")).toBe(0);
  saveRenderState("bounded-200", 200);
  expect(renderState("bounded-0")).toBeNull();
  expect(renderState("bounded-1")).toBe(1);
  expect(renderState("bounded-200")).toBe(200);
});

test("the live frame reports body content height even when the root has a tall viewport", async () => {
  const { renderBridgeScript } = await import("../src/agent-session/acpmux/conversation/renderFrameDoc");
  const child = new JSDOM(
    renderBridgeScript("light", "body{margin:12px;padding:3px}") +
      '<p>First</p><p>Second</p><aside style="position:absolute">Overlay</aside>',
  );
  try {
    const win = child.window;
    win.requestAnimationFrame = (callback) => {
      callback(0);
      return 1;
    };
    const messages: Record<string, unknown>[] = [];
    const observers: (() => void)[] = [];
    let height = 220;
    Object.defineProperty(win.document.documentElement, "scrollHeight", { get: () => 600 });
    Object.defineProperty(win.document.body, "scrollHeight", { get: () => 600 });
    win.document.querySelector("p")!.getBoundingClientRect = () =>
      ({ top: 15, bottom: 15 + height / 2, height: height / 2 }) as DOMRect;
    win.document.querySelectorAll("p")[1]!.getBoundingClientRect = () =>
      ({ top: 15 + height / 2 - 2, bottom: 15 + height, height: height / 2 + 2 }) as DOMRect;
    win.document.querySelector("aside")!.getBoundingClientRect = () =>
      ({ top: 0, bottom: 5000, height: 5000 }) as DOMRect;
    const observe = class {
      constructor(callback: () => void) {
        observers.push(callback);
      }
      observe() {}
      unobserve() {}
      disconnect() {}
    };
    // oxlint-disable-next-line typescript/no-implied-eval -- Execute the generated frame bridge against its DOM.
    new Function(
      "window",
      "document",
      "parent",
      "addEventListener",
      "ResizeObserver",
      "getComputedStyle",
      win.document.querySelector("script")!.textContent,
    )(
      win,
      win.document,
      { postMessage: (data: Record<string, unknown>) => messages.push(data) },
      win.addEventListener.bind(win),
      observe,
      win.getComputedStyle.bind(win),
    );
    win.dispatchEvent(new win.Event("DOMContentLoaded"));
    expect(messages.at(-1)).toEqual({ type: "cmux-render-content-size", height: 250 });
    height = 24;
    observers.forEach((callback) => callback());
    expect(messages.at(-1)).toEqual({ type: "cmux-render-content-size", height: 54 });
  } finally {
    child.window.close();
  }
});

test("the approach demo restores its choice and sends the chosen direction", async () => {
  const { liveRenderTurn } = await import("../src/agent-session/acpmux/mockFixture");
  const tool = liveRenderTurn().find((step) => "update" in step && step.update.rawInput)!;
  const html = ("update" in tool ? (tool.update.rawInput as { html: string }) : undefined)!.html;
  const child = new JSDOM(html);
  const choices: unknown[] = [];
  const prompts: string[] = [];
  try {
    // oxlint-disable-next-line typescript/no-implied-eval -- Exercise the agent-authored mock page against its DOM.
    new Function("document", "cmux", child.window.document.querySelector("script")!.textContent)(
      child.window.document,
      {
        state: {
          get: async () => ({ chosen: "B" }),
          set: async (value: unknown) => {
            choices.push(value);
          },
        },
        sendPrompt: async (text: string) => {
          prompts.push(text);
        },
      },
    );
    await Promise.resolve();
    expect(child.window.document.querySelector('[data-option="B"]')?.getAttribute("aria-pressed")).toBe("true");
    child.window.document.querySelector<HTMLButtonElement>('[data-option="C"]')!.click();
    expect(choices).toEqual([{ chosen: "C" }]);
    expect(prompts).toEqual(["Go with option C: Add a job queue."]);
    expect(child.window.document.querySelector('[data-option="B"]')?.getAttribute("aria-pressed")).toBe("false");
  } finally {
    child.window.close();
  }
});

test("the backoff demo slider updates its chart and prefills the chosen values", async () => {
  await draw();
  const React = await import("react");
  const { liveRenderTurn } = await import("../src/agent-session/acpmux/mockFixture");
  const step = liveRenderTurn().find((step) => "update" in step && step.update.content)!;
  const markdown = ("update" in step ? (step.update.content as { text: string }) : undefined)!.text;
  const code = markdown.split("```cmux-react\n")[1]!.split("```")[0]!;
  const compiled = new Bun.Transpiler({ loader: "jsx", tsconfig: { compilerOptions: { jsx: "react" } } }).transformSync(
    code,
  );
  const drafts: string[] = [];
  // oxlint-disable-next-line typescript/no-implied-eval -- Exercise the mock component with the pane's actual React runtime.
  const Demo = new Function("React", "cmux", compiled + "\nreturn App;")(React, {
    prefill: async (text: string) => {
      drafts.push(text);
    },
  });
  act(() => root!.render(<Demo />));
  const bars = () => [...host.querySelectorAll<HTMLElement>('[role="img"] span span')].map((bar) => bar.style.width);
  const before = bars();
  const slider = host.querySelector<HTMLInputElement>('input[type="range"]')!;
  act(() => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(slider, "600");
    slider.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    slider.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
  });
  expect(host.querySelector("output")?.textContent).toBe("600 ms");
  expect(bars()).not.toEqual(before);
  click("Use these values");
  expect(drafts).toEqual([
    "Use exponential retry backoff with a base of 600 ms and delays of 600, 1200, 2400, 4800 ms.",
  ]);
});

test("render confirmation labels the draft and Cancel or Escape rejects it without sending", async () => {
  const card = await draw();
  card.request("sendPrompt", { text: "A draft" }, undefined, "cancel-button");
  expect(host.querySelector(".acpmux-render-confirm-label")?.textContent).toBe("Send to chat?");
  click("Cancel");
  expect(host.querySelector(".acpmux-render-confirm") === null).toBe(true);
  expect(card.replies.at(-1)).toEqual({
    type: "cmux-render-reply",
    id: "cancel-button",
    ok: false,
    error: "cancelled",
  });
  card.request("sendPrompt", { text: "Another draft" }, undefined, "cancel-key");
  const edit = [...host.querySelectorAll("button")].find((button) => button.textContent === "Edit in prompt")!;
  act(() => {
    edit.focus();
    edit.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(host.querySelector(".acpmux-render-confirm") === null).toBe(true);
  expect(card.replies.at(-1)?.error).toBe("cancelled");
  expect(sent).toEqual([]);
  expect(prefilled).toEqual([]);
});

test.each(["sendPrompt", "prefill", "copy"])("%s confirmations expose the full scrollable payload", async (method) => {
  const style = document.createElement("style");
  style.textContent = await Bun.file(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
  ).text();
  document.head.append(style);
  try {
    const card = await draw();
    const payload = "Summarize" + "\n".repeat(40) + "Hidden instruction";
    card.request(method, { text: payload });
    const text = host.querySelector<HTMLElement>(".acpmux-render-confirm-text")!;
    const css = getComputedStyle(text);
    expect(text.textContent).toBe("Summarize\n[Blank lines: 39]\nHidden instruction");
    expect(css.overflowY).toBe("auto");
    expect(css.display).not.toBe("-webkit-box");
    expect(css.getPropertyValue("-webkit-line-clamp")).toBe("");
    expect([...host.querySelectorAll("button")].some((button) => button.textContent === "Show all")).toBe(false);
  } finally {
    style.remove();
  }
});

test.each(["sendPrompt", "prefill", "copy"])(
  "%s marks bidi and invisible characters while preserving the confirmed bytes",
  async (method) => {
    const card = await draw();
    const controls = "\u200B\u200C\u200D\u200E\u200F\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069\uFEFF";
    const payload = "Safe " + controls + " payload";
    card.request(method, { text: payload });
    const preview = host.querySelector(".acpmux-render-confirm-text")!.textContent!;
    for (const control of controls) {
      expect(preview).toContain("[U+" + control.codePointAt(0)!.toString(16).toUpperCase().padStart(4, "0") + "]");
      expect(preview).not.toContain(control);
    }
    if (method === "sendPrompt") {
      click("Send");
      expect(sent).toEqual([payload]);
    } else if (method === "prefill") {
      click("Edit in prompt");
      expect(prefilled).toEqual([payload]);
    } else {
      const previous = Object.getOwnPropertyDescriptor(navigator, "clipboard");
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
        await act(async () => click("Copy"));
        expect(copies).toEqual([payload]);
      } finally {
        if (previous) Object.defineProperty(navigator, "clipboard", previous);
        else Reflect.deleteProperty(navigator, "clipboard");
      }
    }
  },
);

test("a refused replacement does not restart the 500ms click guard", async () => {
  const card = await draw();
  card.request("sendPrompt", { text: "Draft A" }, undefined, "original");
  click("Send", false);
  expect(sent).toEqual([]);
  now += 499;
  click("Edit in prompt", false);
  click("Cancel", false);
  expect(prefilled).toEqual([]);
  expect(host.querySelector(".acpmux-render-confirm") !== null).toBe(true);
  now += 1;
  card.request("sendPrompt", { text: "Draft B" }, undefined, "replacement");
  click("Send", false);
  expect(sent).toEqual(["Draft A"]);
  expect(card.replies).toContainEqual({
    type: "cmux-render-reply",
    id: "replacement",
    ok: false,
    error: "confirmation pending",
  });
});

test.each([false, true])("a pending request freezes frame height, panel=%s", async (panel) => {
  await draw();
  const { RenderCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  act(() =>
    root!.render(
      <RenderLiveContext.Provider value>
        <RenderCard turnStreaming call={{ html: PAGE }} panel={panel} />
      </RenderLiveContext.Provider>,
    ),
  );
  const frame = host.querySelector("iframe")!;
  const receive = (data: Record<string, unknown>) =>
    act(() => {
      dom.window.dispatchEvent(new dom.window.MessageEvent("message", { source: frame.contentWindow, data }));
    });
  receive({ type: "cmux-render-content-size", height: 240 });
  receive({ type: "cmux-render-request", id: "freeze", method: "copy", params: { text: "Keep still" } });
  receive({ type: "cmux-render-content-size", height: 800 });
  expect(frame.style.height).toBe("240px");
  click("Cancel");
  expect(frame.style.height).toBe("800px");
});

test("turning live on replaces a frame already running under the Run gate", async () => {
  dom.reconfigure({ url: "cmux-agent://pane/index.html" });
  try {
    await draw(false);
    const { RenderCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
    document.documentElement.setAttribute("data-lab-live-render", "off");
    act(() => root!.render(<RenderCard turnStreaming call={{ html: PAGE }} />));
    click("Show visualization");
    const old = host.querySelector("iframe")!;
    document.documentElement.setAttribute("data-lab-live-render", "on");
    act(() => root!.render(<RenderCard turnStreaming call={{ html: PAGE }} />));
    const frame = host.querySelector("iframe")!;
    expect(frame === old).toBe(false);
    expect(frame.src).toBe(old.src);
    const messages: { html: string }[] = [];
    frame.contentWindow!.postMessage = (data) => messages.push(data);
    void act(() =>
      dom.window.dispatchEvent(
        new dom.window.MessageEvent("message", {
          source: frame.contentWindow,
          data: { type: "cmux-render-ready" },
        }),
      ),
    );
    expect(messages[0]?.html).toContain("cmux-render-stream-ready");
  } finally {
    dom.reconfigure({ url: "http://127.0.0.1:4276/" });
  }
});

test("pane updates keep the bridge identity and invoke the latest callbacks", async () => {
  await draw();
  const { memo, useContext } = await import("react");
  const { RenderBridgeContext, useRenderBridge } =
    await import("../src/agent-session/acpmux/conversation/RenderBridgeContext");
  let renders = 0;
  let bridge: NonNullable<React.ContextType<typeof RenderBridgeContext>>;
  const calls: string[] = [];
  const Consumer = memo(function Consumer() {
    renders++;
    bridge = useContext(RenderBridgeContext)!;
    return null;
  });
  function Pane({ version }: { version: string }) {
    const value = useRenderBridge({
      prefill: (text) => {
        calls.push(version + ":prefill:" + text);
      },
      send: (text) => {
        calls.push(version + ":send:" + text);
      },
      openLink: (url) => {
        calls.push(version + ":open:" + url);
        return true;
      },
    });
    return (
      <RenderBridgeContext.Provider value={value}>
        <Consumer />
      </RenderBridgeContext.Provider>
    );
  }
  act(() => root!.render(<Pane version="old" />));
  const original = bridge!;
  act(() => root!.render(<Pane version="new" />));
  expect(renders).toBe(1);
  expect(bridge! === original).toBe(true);
  bridge!.prefill("draft");
  void bridge!.send("prompt");
  void bridge!.openLink("https://example.com");
  expect(calls).toEqual(["new:prefill:draft", "new:send:prompt", "new:open:https://example.com"]);
});

test.each(["body{min-height:100vh}", "html,body{height:100%}", "canvas{position:absolute}"])(
  "viewport pages stay visible without margin feedback: %s",
  async (css) => {
    const { renderBridgeScript } = await import("../src/agent-session/acpmux/conversation/renderFrameDoc");
    const child = new JSDOM(renderBridgeScript("light", "body{margin:4px 0}" + css) + "<canvas></canvas>");
    child.window.requestAnimationFrame = (callback) => {
      callback(0);
      return 1;
    };
    try {
      const win = child.window;
      const messages: { height: number }[] = [];
      const observers: (() => void)[] = [];
      let viewport = 0;
      Object.defineProperty(win, "innerHeight", { get: () => viewport });
      Object.defineProperty(win.document.body, "scrollHeight", { get: () => viewport });
      win.document.body.getBoundingClientRect = () => ({ top: 4, bottom: viewport + 4, height: viewport }) as DOMRect;
      const canvas = win.document.querySelector("canvas")!;
      canvas.getBoundingClientRect = () => ({ top: 4, bottom: viewport + 4, height: viewport }) as DOMRect;
      // oxlint-disable-next-line typescript/no-implied-eval -- Run the frame's actual measurement with modeled viewport geometry.
      new Function(
        "window",
        "document",
        "parent",
        "addEventListener",
        "ResizeObserver",
        "getComputedStyle",
        win.document.querySelector("script")!.textContent,
      )(
        win,
        win.document,
        { postMessage: (data: { height: number }) => messages.push(data) },
        win.addEventListener.bind(win),
        class {
          constructor(callback: () => void) {
            observers.push(callback);
          }
          observe() {}
          unobserve() {}
          disconnect() {}
        },
        win.getComputedStyle.bind(win),
      );
      win.dispatchEvent(new win.Event("DOMContentLoaded"));
      expect(messages.at(-1)?.height).toBe(120);
      for (let round = 0; round < 10; round++) {
        viewport = messages.at(-1)!.height;
        observers.forEach((callback) => callback());
      }
      expect(messages.at(-1)?.height).toBe(120);
    } finally {
      child.window.close();
    }
  },
);

test("kit configuration reaches the frame before the first streamed chunk, and follows its lab", async () => {
  for (const kit of [true, false]) {
    document.documentElement.setAttribute("data-lab-render-kit", kit ? "on" : "off");
    const card = await draw();
    act(() =>
      dom.window.dispatchEvent(
        new dom.window.MessageEvent("message", { source: card.target, data: { type: "cmux-render-stream-ready" } }),
      ),
    );
    const config = card.replies.findIndex((m) => m.type === "cmux-render-kit");
    const chunk = card.replies.findIndex((m) => m.type === "cmux-render-stream");
    expect(config).toBeGreaterThanOrEqual(0);
    expect(chunk).toBeGreaterThan(config);
    expect(card.replies[config]!.enabled).toBe(kit);
  }
  document.documentElement.setAttribute("data-lab-render-kit", "on");
});

test("render repair uses only the first normalized bounded error and names the render", async () => {
  const card = await draw();
  const report = (source: unknown, error: unknown) =>
    act(() =>
      dom.window.dispatchEvent(
        new dom.window.MessageEvent("message", {
          source: source as Window,
          data: { type: "cmux-render-error", error },
        }),
      ),
    );
  report(dom.window, "Forged");
  report(card.target, "   ");
  expect(host.querySelector('[role="status"]')).toBeNull();
  const error = "Chart failed " + "x".repeat(187);
  report(card.target, "  Chart\n failed\t " + "x".repeat(1000));
  report(card.target, "Replacement injection");
  const note = host.querySelector('[role="status"] span')!;
  expect(note.textContent).toBe("Render error: " + error);
  expect(note.hasAttribute("title")).toBe(false);
  expect((note as HTMLElement).style.webkitLineClamp).toBe("2");
  click("Ask to fix");
  expect(prefilled).toEqual([`Please fix the chat render "Interactive page". Render error: ${error}`]);
  expect(sent).toEqual([]);
});

test("kit toggles and frame remounts reset the first-error limit and note", async () => {
  await draw();
  const { RenderCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  const render = (key: string) =>
    act(() =>
      root!.render(
        <RenderLiveContext.Provider value>
          <RenderCard turnStreaming key={key} call={{ html: PAGE }} />
        </RenderLiveContext.Provider>,
      ),
    );
  const report = (error: string) =>
    act(() =>
      dom.window.dispatchEvent(
        new dom.window.MessageEvent("message", {
          source: host.querySelector("iframe")!.contentWindow,
          data: { type: "cmux-render-error", error },
        }),
      ),
    );
  render("first");
  report("First failure");
  expect(host.textContent).toContain("First failure");
  const old = host.querySelector("iframe");
  document.documentElement.setAttribute("data-lab-render-kit", "off");
  render("first");
  document.documentElement.setAttribute("data-lab-render-kit", "on");
  render("first");
  expect(host.querySelector("iframe") === old).toBe(false);
  expect(host.querySelector('[role="status"]')).toBeNull();
  report("Second failure");
  expect(host.textContent).toContain("Second failure");
  render("second");
  expect(host.querySelector('[role="status"]')).toBeNull();
  report("Third failure");
  expect(host.textContent).toContain("Third failure");
});

test("render expansion uses an accessible dialog and its lab can remove the control", async () => {
  document.documentElement.setAttribute("data-lab-render-expand", "on");
  await draw();
  const button = host.querySelector<HTMLButtonElement>(".acpmux-render-enlarge")!;
  expect(button.getAttribute("aria-label")).toBe("Open preview");
  await act(async () => button.click());
  const dialog = document.querySelector<HTMLElement>('[role="dialog"]')!;
  expect(dialog).not.toBeNull();
  expect(dialog.getAttribute("aria-label")).toBe("Interactive page");

  expect(dialog.querySelectorAll("iframe").length).toBe(1);
  expect(dialog.querySelector(".acpmux-render-enlarge")).toBeNull();
  await act(async () => dialog.querySelector<HTMLButtonElement>("button")!.click());
  expect(document.querySelector('[role="dialog"]')).toBeNull();
  expect(document.activeElement).toBe(button);
  document.documentElement.setAttribute("data-lab-render-expand", "off");
  await draw();
  expect(host.querySelector(".acpmux-render-enlarge")).toBeNull();
  document.documentElement.setAttribute("data-lab-render-expand", "on");
});

test("history waits for Run and run pages survive remounts in the pane", async () => {
  const markdown = "```cmux-render\n<p>History</p>\n```";
  await draw(true, markdown, "history", false);
  expect(host.querySelectorAll("iframe").length).toBe(0);
  click("Show visualization");
  expect(host.querySelectorAll("iframe").length).toBe(1);
  await draw(true, markdown, "history", false);
  expect(host.querySelectorAll("iframe").length).toBe(1);
  await draw(true, markdown, "active", true);
  expect(host.querySelectorAll("iframe").length).toBe(1);
  await draw(true, markdown, "active", false);
  expect(host.querySelectorAll("iframe").length).toBe(1);
});

test("a watchdog removes an unresponsive frame without waiting in real time", async () => {
  const timers = new Map<number, () => void>();
  let next = 100000;
  const original = globalThis.setTimeout;
  const timeout = spyOn(globalThis, "setTimeout").mockImplementation(((callback: () => void, delay?: number) => {
    if (delay === 5000 || delay === 2000) {
      const id = next++;
      timers.set(id, callback);
      return id;
    }
    return original(callback, delay);
  }) as typeof setTimeout);
  const clear = spyOn(globalThis, "clearTimeout").mockImplementation((id) => {
    timers.delete(Number(id));
  });
  try {
    await draw();
    expect(timers.size).toBeGreaterThan(0);
    act(() => {
      const callbacks = [...timers.values()];
      timers.clear();
      callbacks.forEach((callback) => callback());
    });
    expect(host.querySelectorAll("iframe").length).toBe(0);
    expect(host.querySelector('[role="status"]')?.textContent).toContain("Render error:");
  } finally {
    act(() => root?.unmount());
    root = undefined;
    timeout.mockRestore();
    clear.mockRestore();
  }
});

test.each(["no acknowledgement", "false", "rejection"])("openLink rejects host %s", async (result) => {
  const card = await draw(true, undefined, undefined, true, () => {
    if (result === "rejection") return Promise.reject(new Error("host refused browser.open"));
    if (result === "false") return false;
    return undefined as unknown as boolean;
  });
  card.request("openLink", { url: "https://example.com/public" });
  await act(async () => click("Open"));
  expect(card.replies.at(-1)).toEqual({ type: "cmux-render-reply", id: "1", ok: false, error: "unavailable" });
});

test.each(["sendPrompt", "prefill", "copy", "openLink"])("%s confirmation names its page origin", async (method) => {
  const card = await draw();
  card.request(method, method === "openLink" ? { url: "https://example.com" } : { text: "Approve this" });
  expect(host.querySelector(".acpmux-render-confirm-origin")?.textContent).toBe("From a page in this chat");
  expect(host.querySelector(".acpmux-render-confirm")?.getAttribute("aria-label")).toContain(
    "From a page in this chat",
  );
});

test("an attached unfinished reply stays gated even when its row says streaming", async () => {
  await draw();
  const { RenderCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  const { RenderLiveContext } = await import("../src/agent-session/acpmux/conversation/viewIdentity");
  act(() =>
    root!.render(
      <RenderLiveContext.Provider value={false}>
        <RenderCard call={{ html: "<p>Unfinished history</p>" }} turnStreaming />
      </RenderLiveContext.Provider>,
    ),
  );
  expect(host.querySelectorAll("iframe").length).toBe(0);
  click("Show visualization");
  expect(host.querySelectorAll("iframe").length).toBe(1);
});

test.each([4, 40])("blank-line padding with %s newlines is counted beside the hidden instruction", async (newlines) => {
  const card = await draw();
  const text = "Summarize" + "\n".repeat(newlines) + "Hidden instruction";
  card.request("sendPrompt", { text });
  const shown = host.querySelector(".acpmux-render-confirm-text")!;
  expect(shown.textContent).toBe(`Summarize\n[Blank lines: ${newlines - 1}]\nHidden instruction`);
  click("Send");
  expect(sent).toEqual([text]);
});

test("all invisible spacing and annotation characters are named in the confirmation", async () => {
  const card = await draw();
  const codes = [
    ...Array.from({ length: 11 }, (_, i) => 0x2000 + i),
    0x3000,
    0x2028,
    0x2029,
    0x180e,
    0xfff9,
    0xfffa,
    0xfffb,
  ];
  card.request("sendPrompt", { text: "Start" + String.fromCodePoint(...codes) + "End" });
  expect(host.querySelector(".acpmux-render-confirm-text")?.textContent).toBe(
    "Start" + codes.map((code) => `[U+${code.toString(16).toUpperCase().padStart(4, "0")}]`).join("") + "End",
  );
});

test("confirmation stays disabled until the full payload has been scrolled into view", async () => {
  const prototype = dom.window.HTMLElement.prototype;
  const height = Object.getOwnPropertyDescriptor(prototype, "clientHeight");
  const scroll = Object.getOwnPropertyDescriptor(prototype, "scrollHeight");
  Object.defineProperty(prototype, "clientHeight", { configurable: true, get: () => 240 });
  Object.defineProperty(prototype, "scrollHeight", { configurable: true, get: () => 1200 });
  try {
    const card = await draw();
    const text = "First line\n".repeat(80) + "Hidden instruction";
    card.request("sendPrompt", { text });
    const box = host.querySelector<HTMLElement>(".acpmux-render-confirm-text")!;
    const send = [...host.querySelectorAll("button")].find((button) => button.textContent === "Send")!;
    expect(box.textContent).toContain("Hidden instruction");
    expect(send.disabled).toBe(true);
    click("Send");
    expect(sent).toEqual([]);
    act(() => {
      box.scrollTop = 500;
      box.dispatchEvent(new dom.window.Event("scroll", { bubbles: true }));
    });
    expect(send.disabled).toBe(true);
    act(() => {
      box.scrollTop = 960;
      box.dispatchEvent(new dom.window.Event("scroll", { bubbles: true }));
    });
    expect(send.disabled).toBe(false);
    click("Send");
    expect(sent).toEqual([text]);
    card.request("sendPrompt", { text: "Another long payload" }, undefined, "second");
    expect([...host.querySelectorAll("button")].find((button) => button.textContent === "Send")!.disabled).toBe(true);
  } finally {
    if (height) Object.defineProperty(prototype, "clientHeight", height);
    else Reflect.deleteProperty(prototype, "clientHeight");
    if (scroll) Object.defineProperty(prototype, "scrollHeight", scroll);
    else Reflect.deleteProperty(prototype, "scrollHeight");
  }
});

test("live fences run after a burst or delayed text reveal, even after streaming ends", async () => {
  const markdown = "```cmux-render\n<p>Complete burst</p>\n```";
  await draw(true, markdown, "burst", false, undefined, true);
  expect(host.querySelectorAll("iframe")).toHaveLength(1);

  await draw(true, markdown, "burst", false, undefined, false);
  expect(host.querySelectorAll("iframe")).toHaveLength(1);
});

test.each([false, true])("tool renders use their live provenance through the transcript: %s", async (renderLive) => {
  await draw(false);
  document.documentElement.setAttribute("data-lab-live-render", "on");
  const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
  const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
  const rows = turnView(
    [
      { id: "prompt", kind: "user", version: 1, at: 1, text: "Make a page" },
      {
        id: "tool",
        kind: "activity",
        version: 1,
        at: 2,
        renderLive,
        items: [
          {
            kind: "tool",
            text: "Page",
            tool: {
              id: "page",
              title: "mcp__cmux__render",
              status: "completed",
              inputSummary: JSON.stringify({ html: `<p>Tool ${renderLive}</p>` }),
            },
          },
        ],
      },
      { id: "end", kind: "turnSummary", version: 1, at: 3, status: "completed" },
    ],
    new Set(),
  );
  act(() =>
    root!.render(
      <RenderLiveContext.Provider value={false}>
        <VirtualTranscript rows={rows} onToggleActivity={() => {}} expanded={new Set()} />
      </RenderLiveContext.Provider>,
    ),
  );
  expect(host.querySelectorAll("iframe")).toHaveLength(renderLive ? 1 : 0);
  if (!renderLive) {
    click("Show visualization");
    expect(host.querySelectorAll("iframe")).toHaveLength(1);
  }
});

test("a card with no live provider fails closed even when the turn is streaming", async () => {
  await draw(false);
  document.documentElement.setAttribute("data-lab-live-render", "on");
  const { RenderCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  act(() => root!.render(<RenderCard turnStreaming call={{ html: "<p>No provenance</p>" }} />));
  expect(host.querySelectorAll("iframe")).toHaveLength(0);
  click("Show visualization");
  expect(host.querySelectorAll("iframe")).toHaveLength(1);
});

test("a page that loses its heartbeat after loading reports a hang after the longer grace", async () => {
  const timers = new Map<number, { delay: number; run: () => void }>();
  let next = 100000;
  const original = globalThis.setTimeout;
  const timeout = spyOn(globalThis, "setTimeout").mockImplementation(((run: () => void, delay?: number) => {
    if (delay === 5000 || delay === 2000 || delay === 30000) {
      const id = next++;
      timers.set(id, { delay, run });
      return id;
    }
    return original(run, delay);
  }) as typeof setTimeout);
  const clear = spyOn(globalThis, "clearTimeout").mockImplementation((id) => {
    timers.delete(Number(id));
  });
  const fire = (delay: number) => {
    const task = [...timers].find(([, task]) => task.delay === delay);
    if (!task) return;
    timers.delete(task[0]);
    act(() => task[1].run());
  };
  try {
    const card = await draw();
    const receive = (data: unknown) =>
      void act(() => dom.window.dispatchEvent(new dom.window.MessageEvent("message", { source: card.target, data })));
    receive({ type: "cmux-render-ready" });
    const challenge = card.replies.find((message) => message.type === "cmux-render-ping")!;
    receive({ type: "cmux-render-pong", id: challenge.id });
    // A loaded page replaces its document and never answers the next challenge.
    receive({ type: "cmux-render-content-size", height: 200 });
    fire(2000);
    fire(5000);
    expect(host.querySelectorAll("iframe")).toHaveLength(1);
    expect(host.querySelector('[role="status"]')).toBeNull();
    fire(30000);
    expect(host.querySelectorAll("iframe")).toHaveLength(0);
    expect(host.querySelector('[role="status"]')?.textContent).toContain("The page stopped responding");
    expect(host.textContent).not.toContain("Could not load the page");
    await draw();
    expect(host.querySelectorAll("iframe")).toHaveLength(0);
    expect(host.querySelector('[role="status"]')?.textContent).toContain("The page stopped responding");
    click("Ask to fix");
    expect(prefilled.at(-1)).toContain("Render error: The page stopped responding");
    click("Show visualization");
    expect(host.querySelectorAll("iframe")).toHaveLength(1);
    expect(host.querySelector('[role="status"]')).toBeNull();
  } finally {
    act(() => root?.unmount());
    root = undefined;
    timeout.mockRestore();
    clear.mockRestore();
  }
});

test("a history page in the side panel keeps Run until the reader runs it", async () => {
  await draw(false);
  document.documentElement.setAttribute("data-lab-live-render", "on");
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  act(() =>
    root!.render(
      <ArtifactPanel artifact={{ kind: "html", lang: "html", code: "<p>History panel</p>" }} onClose={() => {}} />,
    ),
  );
  expect(host.querySelectorAll("iframe")).toHaveLength(0);
  click("Show visualization");
  expect(host.querySelectorAll("iframe")).toHaveLength(1);
});

test("execution grants stay with their session and card through reattachment", async () => {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const sessionId = `grant-${testSession}`;
  const session = { sessionId, status: "running", updatedAt: 1 };
  let socket: any;
  let holdAttach = false;
  let releaseAttach: (() => void) | undefined;
  let notifyAttach: (() => void) | undefined;
  const attachStarted = new Promise<void>((resolve) => {
    notifyAttach = resolve;
  });
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", sessionId },
    () => {},
    undefined,
    () => {
      socket = {
        readyState: 1,
        close() {},
        send(raw: string) {
          const { id, method } = JSON.parse(raw);
          const result =
            method === "initialize"
              ? { protocolVersion: 1 }
              : method === "_acpmux/watch"
                ? { sessions: [session] }
                : method === "_acpmux/attach"
                  ? { session, lastSeq: 0, events: [], hasMore: false }
                  : null;
          const reply = () => socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id, result }) });
          if (method === "_acpmux/attach" && holdAttach) {
            releaseAttach = reply;
            notifyAttach?.();
          } else if (id !== undefined) queueMicrotask(reply);
        },
      };
      queueMicrotask(() => socket.onopen?.());
      return socket as WebSocket;
    },
  );
  const markdown = "```cmux-render\n<p>Scoped execution</p>\n```";
  try {
    await draw(true, markdown, sessionId);
    expect(host.querySelectorAll("iframe")).toHaveLength(1);
    await draw(true, markdown, sessionId, false);
    expect(host.querySelectorAll("iframe")).toHaveLength(1);
    await draw(true, markdown, "other-session", false);
    expect(host.querySelectorAll("iframe")).toHaveLength(0);
    click("Show visualization");
    expect(host.querySelectorAll("iframe")).toHaveLength(1);
    const { renderAttachment } = await import("../src/agent-session/acpmux/conversation/renderExecution");
    const oldProvenance = { attachment: renderAttachment(sessionId) };
    await draw(true, markdown, sessionId, true, undefined, oldProvenance);
    holdAttach = true;
    let selection: Promise<string | undefined> | undefined;
    await act(async () => {
      selection = client.select(sessionId);
      void selection.catch(() => undefined);
      await attachStarted;
    });
    expect(host.querySelectorAll("iframe")).toHaveLength(0);
    await draw(true, markdown, sessionId, true, undefined, oldProvenance);
    expect(host.querySelectorAll("iframe")).toHaveLength(0);
    await act(async () => {
      releaseAttach?.();
      await selection;
    });
    await draw(true, markdown, sessionId, false);
    expect(host.querySelectorAll("iframe")).toHaveLength(0);
    click("Show visualization");
    expect(host.querySelectorAll("iframe")).toHaveLength(1);
  } finally {
    client.close();
  }
});

test("identical HTML in another row waits for Show visualization", async () => {
  await draw();
  const { RenderCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  const { TranscriptRowContext } = await import("../src/agent-session/acpmux/conversation/viewIdentity");
  const mount = (row: string, live: boolean) =>
    act(() =>
      root!.render(
        <ChatSessionContext.Provider value="grant-rows">
          <TranscriptRowContext.Provider value={row}>
            <RenderLiveContext.Provider value={live}>
              <RenderCard call={{ html: PAGE, id: "0" }} />
            </RenderLiveContext.Provider>
          </TranscriptRowContext.Provider>
        </ChatSessionContext.Provider>,
      ),
    );
  mount("first", true);
  expect(host.querySelectorAll("iframe")).toHaveLength(1);
  mount("second", false);
  expect(host.querySelectorAll("iframe")).toHaveLength(0);
});
