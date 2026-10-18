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
const { ChatSessionContext } = await import("../src/agent-session/acpmux/conversation/viewIdentity");
const PAGE = "<title>Interactive page</title><p>Ready</p>";

let testSession = 0;
let now = Date.now();
const clock = spyOn(Date, "now").mockImplementation(() => now);
afterAll(() => clock.mockRestore());
beforeEach(() => {
  testSession++;
});

async function draw(
  live = true,
  markdown = `\`\`\`cmux-render\n${PAGE}\n\`\`\``,
  sessionId = `live-test-${testSession}`,
) {
  act(() => root?.unmount());
  document.documentElement.setAttribute("data-lab-live-render", live ? "on" : "off");
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
        <ChatSessionContext.Provider value={sessionId}>
          <Markdown>{markdown}</Markdown>
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
  expect([...host.querySelectorAll("button")].some((button) => button.textContent === "Run")).toBe(false);
  expect(host.querySelector(".acpmux-render-card-head")).toBeNull();
  expect(
    [...host.querySelectorAll("button")].some((button) =>
      ["Stop", "Open preview", "Run"].includes(button.textContent!),
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

test("a new request replaces the pending confirmation; Cancel rejects it", async () => {
  const { request, replies } = await draw();
  request("sendPrompt", { text: "Old" }, undefined, "old");
  request("sendPrompt", { text: "New" }, undefined, "new");
  expect(replies).toContainEqual({ type: "cmux-render-reply", id: "old", ok: false, error: "replaced" });
  click("Cancel");
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
    act(() => root!.render(<ArtifactPanel key={artifact.kind} artifact={artifact} onClose={() => {}} />));
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

test("embedded frames retain accessible titles without a visible heading", async () => {
  await draw();
  const { RenderCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  for (const [html, title] of [
    ["<title>Plan &amp; effort</title><p>Choose</p>", "Plan & effort"],
    ["<!-- cmux-react -->\n// title: Plan picker\nfunction App() { return null; }", "Plan picker"],
  ]) {
    act(() => root!.render(<RenderCard call={{ html }} />));
    expect(host.querySelector(".acpmux-render-card-title")).toBeNull();
    expect(host.querySelector("iframe")?.title).toBe(title);
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
            <Markdown>{nested(html)}</Markdown>
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
        <RenderCard call={{ html }} />
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

test("a long confirmation expands fully and resets for the next draft", async () => {
  const prototype = dom.window.HTMLElement.prototype;
  const scrollHeight = Object.getOwnPropertyDescriptor(prototype, "scrollHeight");
  const clientHeight = Object.getOwnPropertyDescriptor(prototype, "clientHeight");
  Object.defineProperty(prototype, "scrollHeight", {
    configurable: true,
    get() {
      return this.classList.contains("acpmux-render-confirm-text") ? 240 : 0;
    },
  });
  Object.defineProperty(prototype, "clientHeight", {
    configurable: true,
    get() {
      return this.classList.contains("acpmux-render-confirm-text") ? 60 : 0;
    },
  });
  try {
    const card = await draw();
    card.request("sendPrompt", { text: "Long draft\n".repeat(12) });
    click("Show all");
    expect(host.querySelector(".acpmux-render-confirm-text")?.classList.contains("is-expanded")).toBe(true);
    expect(host.querySelector(".acpmux-render-confirm-text")?.textContent).toBe("Long draft\n".repeat(12));
    click("Show less");
    expect(host.querySelector(".acpmux-render-confirm-text")?.classList.contains("is-expanded")).toBe(false);
    click("Show all");
    card.request("sendPrompt", { text: "Replacement draft" });
    expect(host.querySelector(".acpmux-render-confirm-text")?.classList.contains("is-expanded")).toBe(false);
  } finally {
    for (const [name, descriptor] of [
      ["scrollHeight", scrollHeight],
      ["clientHeight", clientHeight],
    ] as const) {
      if (descriptor) Object.defineProperty(prototype, name, descriptor);
      else Reflect.deleteProperty(prototype, name);
    }
  }
});

test("confirmation clicks wait 500ms after appearance and every replacement, including the same text", async () => {
  const card = await draw();
  card.request("sendPrompt", { text: "Draft" });
  click("Send", false);
  expect(sent).toEqual([]);
  now += 499;
  click("Edit in prompt", false);
  click("Cancel", false);
  expect(prefilled).toEqual([]);
  expect(host.querySelector(".acpmux-render-confirm")).not.toBeNull();
  now += 1;
  card.request("prefill", { text: "Draft" }, undefined, "replacement");
  click("Edit in prompt", false);
  expect(prefilled).toEqual([]);
  click("Edit in prompt");
  expect(prefilled).toEqual(["Draft"]);
});

test.each([false, true])("a pending request freezes frame height, panel=%s", async (panel) => {
  await draw();
  const { RenderCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  act(() => root!.render(<RenderCard call={{ html: PAGE }} panel={panel} />));
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
    await draw();
    const { RenderCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
    document.documentElement.setAttribute("data-lab-live-render", "off");
    act(() => root!.render(<RenderCard call={{ html: PAGE }} />));
    click("Run");
    const old = host.querySelector("iframe")!;
    document.documentElement.setAttribute("data-lab-live-render", "on");
    act(() => root!.render(<RenderCard call={{ html: PAGE }} />));
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
  bridge!.openLink("https://example.com");
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
