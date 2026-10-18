// l10n-allow-file: test fixtures, not shipped UI.
import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act, type ReactNode } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "https://pane.test/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  location: dom.window.location,
  navigator: dom.window.navigator,
  localStorage: dom.window.localStorage,
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
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
// JSDOM has no layout. Give the prompt its pre-wrap lines for the overflow measurement.
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollHeight", {
  configurable: true,
  get() {
    return (this.textContent?.split("\n").length ?? 1) * 22.75;
  },
});
dom.window.localStorage.setItem("cmux.acpmux.codeWrap", "true");
const host = dom.window.document.getElementById("root")!;
const { createRoot } = await import("react-dom/client");
const { configureLabs } = await import("../src/agent-session/acpmux/labs");
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { FindReveal, findMatches } = await import("../src/agent-session/acpmux/conversation/chatFind");
const { ChatSessionContext } = await import("../src/agent-session/acpmux/conversation/viewIdentity");
const { layoutConversation } = await import("../src/agent-session/acpmux/model");
const { PlainCode } = await import("../src/agent-session/acpmux/conversation/StreamingCode");
const { CodeBlock } = await import("../src/agent-session/acpmux/conversation/CodeBlock");
const { HighlightedCode } = await import("../src/agent-session/acpmux/conversation/HighlightedCode");
const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
let root: Root | undefined;

beforeEach(() => {
  act(() => configureLabs(undefined));
  setComposerSettings({ showContextUsage: true });
});
afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});
afterAll(() => {
  configureLabs(undefined);
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
async function draw(node: ReactNode) {
  root ??= createRoot(host);
  await act(async () => root!.render(node));
}
const button = (label: string) =>
  [...host.querySelectorAll("button")].find(
    (node) => node.getAttribute("aria-label") === label || node.textContent === label,
  );
const prompt = (id: string, text = "Hello", at = Date.now()): AcpmuxRow => ({
  id,
  text,
  at,
  kind: "user",
  version: 1,
});

test("labs default off and keep the prompt and plain code markup", async () => {
  await draw(<UserBubble row={prompt("off")} text="Hello" />);
  expect(host.innerHTML).toBe('<div class="cv-user__bubble selectable">Hello</div>');
  await draw(<PlainCode code="line" lang="text" />);
  expect(button("Wrap lines")).toBeUndefined();
  expect(host.querySelector("pre")?.className).toBe("cv-code-plain selectable");
});

test("promptCollapse folds long prompts, remembers expansion on remount, and Find opens a hidden match", async () => {
  act(() => configureLabs({ labs: { promptCollapse: true } }));
  const text = Array.from({ length: 16 }, (_, n) => `line ${n}`).join("\n");
  const row = prompt("long", text);
  await draw(<UserBubble row={row} text={text} />);
  expect(button("Show more")?.getAttribute("aria-expanded")).toBe("false");
  await act(async () => button("Show more")!.click());
  expect(host.querySelector(".is-clamped")).toBeNull();
  const expandedHeight = layoutConversation([row], 700).totalHeight;
  await draw(null);
  await draw(<UserBubble row={row} text={text} />);
  expect(button("Show less")).toBeDefined();
  await act(async () => button("Show less")!.click());
  const collapsedHeight = layoutConversation([row], 700).totalHeight;
  expect(collapsedHeight).toBeLessThan(expandedHeight);
  expect(collapsedHeight).toBeGreaterThanOrEqual(8 * 22.75 + 32);
  expect(findMatches([row], "line 15")).toHaveLength(1);
  let repaints = 0;
  await draw(
    <FindReveal.Provider value={{ rowId: row.id, card: false, needle: "line 15", repaint: () => repaints++ }}>
      <UserBubble row={row} text={text} />
    </FindReveal.Provider>,
  );
  expect(host.querySelector(".is-clamped")).toBeNull();
  expect(repaints).toBeGreaterThan(0);
});

test("short prompts have no collapse action, and Find with the lab off leaves their DOM alone", async () => {
  act(() => configureLabs({ labs: { promptCollapse: true } }));
  await draw(<UserBubble row={prompt("short")} text="Hello" />);
  expect(button("Show more")).toBeUndefined();
  act(() => configureLabs(undefined));
  await draw(
    <FindReveal.Provider value={{ rowId: "short", card: false, needle: "hello", repaint: () => {} }}>
      <UserBubble row={prompt("short")} text="Hello" />
    </FindReveal.Provider>,
  );
  expect(host.innerHTML).toBe('<div class="cv-user__bubble selectable">Hello</div>');
});

test("messageTimes uses the prompt time, adds a date on older messages, and is focusable only with the lab on", async () => {
  act(() => configureLabs({ labs: { messageTimes: true } }));
  const at = new Date(2020, 1, 2, 14, 41).getTime();
  await draw(
    <div className="cv-user">
      <UserBubble row={prompt("dated", "Hello", at)} text="Hello" />
    </div>,
  );
  const time = host.querySelector("time")!;
  expect(time.dateTime).toBe(new Date(at).toISOString());
  expect(time.textContent).toContain("2020");
  expect(time.getAttribute("aria-label")).toContain("2020");
  expect(host.querySelector(".cv-user__bubble")?.getAttribute("tabindex")).toBe("0");
  await draw(<UserBubble row={prompt("today")} text="Hello" />);
  expect(host.querySelector("time")?.textContent).not.toContain(String(new Date().getFullYear()));
  await draw(<UserBubble row={prompt("unknown", "Hello", 0)} text="Hello" />);
  expect(host.querySelector("time")).toBeNull();
  act(() => configureLabs(undefined));
  expect(host.querySelector("[tabindex]")).toBeNull();
});

test("codeWrap restores storage and shares changes across highlighted, streaming and oversized cards", async () => {
  act(() => configureLabs({ labs: { codeWrap: true } }));
  await draw(
    <>
      <HighlightedCode code="let x = 1" lang="text" />
      <PlainCode code="streaming\n" lang="text" open />
      <CodeBlock code={"long ".repeat(40_001)} lang="text" />
    </>,
  );
  const toggles = () => [...host.querySelectorAll<HTMLButtonElement>('[aria-label="Wrap lines"]')];
  expect(toggles()).toHaveLength(3);
  expect(toggles().every((node) => node.getAttribute("aria-pressed") === "true")).toBe(true);
  expect(host.querySelectorAll("pre.is-wrapped")).toHaveLength(2);
  expect(host.querySelector("diffs-container")?.getAttribute("data-wrap")).toBe("true");
  await act(async () => toggles()[0]!.click());
  expect(toggles().every((node) => node.getAttribute("aria-pressed") === "false")).toBe(true);
  expect(dom.window.localStorage.getItem("cmux.acpmux.codeWrap")).toBe("false");
  expect(host.querySelector("diffs-container")?.getAttribute("data-wrap")).toBe("false");
  // A blocked write still updates every card in this pane.
  const storageSet = dom.window.Storage.prototype.setItem;
  dom.window.Storage.prototype.setItem = () => {
    throw new Error("blocked");
  };
  try {
    await act(async () => toggles()[1]!.click());
    expect(toggles().every((node) => node.getAttribute("aria-pressed") === "true")).toBe(true);
  } finally {
    dom.window.Storage.prototype.setItem = storageSet;
  }
  await draw(null);
  await draw(<PlainCode code="remounted" lang="text" />);
  expect(toggles()[0]?.getAttribute("aria-pressed")).toBe("true");
  act(() => configureLabs(undefined));
  expect(toggles()).toHaveLength(0);
  expect(host.querySelector("pre.is-wrapped")).toBeNull();
});

test("with codeWrap off, highlighted cards keep independent wrap choices and plain cards have no toggle", async () => {
  await draw(
    <>
      <HighlightedCode code="one" lang="text" />
      <HighlightedCode code="two" lang="text" />
      <PlainCode code="three" lang="text" />
    </>,
  );
  const toggles = [...host.querySelectorAll<HTMLButtonElement>('[aria-label="Wrap lines"]')];
  expect(toggles).toHaveLength(2);
  expect(toggles.every((node) => node.getAttribute("aria-pressed") === "false")).toBe(true);
  await act(async () => toggles[0]!.click());
  expect(toggles[0]!.getAttribute("aria-pressed")).toBe("true");
  expect(toggles[1]!.getAttribute("aria-pressed")).toBe("false");
});

test("contextMeter reuses the ring details and hides unknown or disabled usage", async () => {
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const client = new QueryClient();
  const snapshot = {
    rows: [],
    sessions: [],
    catalog: [],
    configOptions: [],
    isWorking: false,
    summary: { sessionId: "test", harness: "codex", usage: { used: 40_000, size: 100_000 } },
  } as unknown as AcpmuxSnapshot;
  const picker = (value = snapshot) => (
    <QueryClientProvider client={client}>
      <ComposerPickers snapshot={value} onModel={() => {}} onMode={() => {}} onEffort={() => {}} />
    </QueryClientProvider>
  );
  await draw(picker());
  expect(host.querySelector(".acpmux-context-ring")).toBeNull();
  act(() => configureLabs({ labs: { contextMeter: true } }));
  expect(button("Context: 40% used") ?? host.querySelector(".acpmux-context-ring")).not.toBeNull();
  await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-context-ring")!.click());
  expect(dom.window.document.querySelector(".acpmux-context-tokens")?.textContent).toContain("40K");
  act(() => setComposerSettings({ showContextUsage: false }));
  expect(host.querySelector(".acpmux-context-ring")).toBeNull();
  act(() => setComposerSettings({ showContextUsage: true }));
  for (const usage of [undefined, { used: 0, size: 0 }, { used: Number.NaN, size: 100 }, { used: -1, size: 100 }]) {
    await draw(picker({ ...snapshot, summary: { ...snapshot.summary!, usage } }));
    expect(host.querySelector(".acpmux-context-ring")).toBeNull();
  }
  client.clear();
});

test("prompt expansion belongs to the session even when row ids repeat", async () => {
  act(() => configureLabs({ labs: { promptCollapse: true } }));
  const text = Array.from({ length: 16 }, (_, n) => `line ${n}`).join("\n");
  const bubble = (session: string) => (
    <ChatSessionContext.Provider value={session}>
      <UserBubble row={prompt("repeated", text)} text={text} />
    </ChatSessionContext.Provider>
  );
  await draw(bubble("prompt-a"));
  await act(async () => button("Show more")!.click());
  await draw(null);
  await draw(bubble("prompt-b"));
  expect(host.querySelector(".is-clamped")).not.toBeNull();
  await draw(bubble("prompt-a"));
  expect(host.querySelector(".is-clamped")).toBeNull();
});

test("transcript invalidates unmounted prompt estimates when collapse changes", async () => {
  const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
  const { expandPrompt } = await import("../src/agent-session/acpmux/conversation/promptCollapse");
  const text = Array.from({ length: 40 }, (_, n) => `line ${n}`).join("\n");
  const rows = Array.from({ length: 80 }, (_, n) => prompt(`geometry-${n}`, text));
  const transcript = (
    <VirtualTranscript rows={rows} sessionId="geometry" expanded={new Set()} onToggleActivity={() => {}} />
  );
  await draw(transcript);
  const height = () => parseFloat(host.querySelector<HTMLElement>(".acpmux-spacer")!.style.height);
  const full = height();
  expect(host.querySelector('[data-row-id="geometry-0"]')).toBeNull();
  await act(async () => configureLabs({ labs: { promptCollapse: true } }));
  const collapsed = height();
  expect(collapsed).toBeLessThan(full);
  await act(async () => expandPrompt("geometry-0", true, "geometry"));
  expect(height()).toBeGreaterThan(collapsed);
  await act(async () => configureLabs(undefined));
  expect(height()).toBe(full);
});

test("a folded offscreen prompt discards its old drawn height and reused layout prefix", async () => {
  const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
  const { expandPrompt } = await import("../src/agent-session/acpmux/conversation/promptCollapse");
  const text = Array.from({ length: 40 }, (_, n) => `line ${n}`).join("\n");
  const rows = Array.from({ length: 80 }, (_, n) => prompt(`drawn-${n}`, text));
  const transcript = (shown: AcpmuxRow[]) => (
    <VirtualTranscript rows={shown} sessionId="drawn" expanded={new Set()} onToggleActivity={() => {}} />
  );
  const prototype = dom.window.HTMLElement.prototype;
  const rect = prototype.getBoundingClientRect;
  const viewport = Object.getOwnPropertyDescriptor(prototype, "clientHeight");
  Object.defineProperty(prototype, "clientHeight", { configurable: true, get: () => 600 });
  prototype.getBoundingClientRect = function () {
    const bounds = rect.call(this);
    return this.getAttribute("data-row-id") === "drawn-0"
      ? new dom.window.DOMRect(bounds.x, bounds.y, bounds.width, 3000)
      : bounds;
  };
  try {
    await draw(transcript([rows[0]!]));
    await draw(transcript(rows));
    const scroller = host.querySelector<HTMLElement>(".acpmux-scroll")!;
    await act(async () => {
      scroller.scrollTop = 70_000;
      scroller.dispatchEvent(new dom.window.Event("scroll", { bubbles: true }));
    });
    expect(host.querySelector('[data-row-id="drawn-0"]') === null).toBe(true);
    const height = () => parseFloat(host.querySelector<HTMLElement>(".acpmux-spacer")!.style.height);
    await act(async () => configureLabs({ labs: { promptCollapse: true } }));
    const collapsed = height();
    const short = layoutConversation([rows[0]!], 700, undefined, undefined, undefined, undefined, "drawn").totalHeight;
    await act(async () => expandPrompt("drawn-0", true, "drawn"));
    const tall = layoutConversation([rows[0]!], 700, undefined, undefined, undefined, undefined, "drawn").totalHeight;
    expect(height()).toBeCloseTo(collapsed + tall - short, 5);
    await act(async () => expandPrompt("drawn-0", false, "drawn"));
    expect(height()).toBe(collapsed);
  } finally {
    prototype.getBoundingClientRect = rect;
    if (viewport) Object.defineProperty(prototype, "clientHeight", viewport);
    else Reflect.deleteProperty(prototype, "clientHeight");
  }
});

test.each(["messageTimes", "liveRender", "codeWrap", "planProgress", "contextMeter", "shared wrap"] as const)(
  "%s discards a measured offscreen row height like a fresh transcript",
  async (setting) => {
    const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
    if (setting === "shared wrap") act(() => configureLabs({ labs: { codeWrap: true } }));
    const text = Array.from({ length: 40 }, (_, n) => `line ${n}`).join("\n");
    const rows = Array.from({ length: 80 }, (_, n) => prompt(`setting-${n}`, text));
    const transcript = (shown: AcpmuxRow[]) => (
      <>
        <VirtualTranscript rows={shown} sessionId="settings" expanded={new Set()} onToggleActivity={() => {}} />
        <PlainCode code="wrap control" lang="text" />
      </>
    );
    const prototype = dom.window.HTMLElement.prototype;
    const rect = prototype.getBoundingClientRect;
    const viewport = Object.getOwnPropertyDescriptor(prototype, "clientHeight");
    Object.defineProperty(prototype, "clientHeight", { configurable: true, get: () => 600 });
    prototype.getBoundingClientRect = function () {
      const bounds = rect.call(this);
      return this.getAttribute("data-row-id") === "setting-0"
        ? new dom.window.DOMRect(bounds.x, bounds.y, bounds.width, 3000)
        : bounds;
    };
    try {
      await draw(transcript([rows[0]!]));
      await draw(transcript(rows));
      const scroller = host.querySelector<HTMLElement>(".acpmux-scroll")!;
      await act(async () => {
        scroller.scrollTop = 70_000;
        scroller.dispatchEvent(new dom.window.Event("scroll", { bubbles: true }));
      });
      expect(host.querySelector('[data-row-id="setting-0"]')).toBeNull();
      const height = () => parseFloat(host.querySelector<HTMLElement>(".acpmux-spacer")!.style.height);
      const cached = height();
      if (setting === "shared wrap") await act(async () => button("Wrap lines")!.click());
      else await act(async () => configureLabs({ labs: { [setting]: true } }));
      const changed = height();
      act(() => root!.unmount());
      root = undefined;
      await draw(transcript(rows));
      expect(cached).not.toBe(height());
      expect(changed).toBe(height());
      await act(async () => configureLabs(undefined));
      expect(height()).toBe(changed);
    } finally {
      prototype.getBoundingClientRect = rect;
      if (viewport) Object.defineProperty(prototype, "clientHeight", viewport);
      else Reflect.deleteProperty(prototype, "clientHeight");
    }
  },
);

test("Find reopens a prompt for the next occurrence after the reader collapses it", async () => {
  const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
  const { useChatFind } = await import("../src/agent-session/acpmux/conversation/chatFind");
  act(() => configureLabs({ labs: { promptCollapse: true } }));
  const text = Array.from({ length: 16 }, () => "match").join("\n");
  const rows = [prompt("find-occurrences", text)];
  let find!: ReturnType<typeof useChatFind>;
  function Transcript() {
    find = useChatFind(rows);
    return (
      <VirtualTranscript
        rows={rows}
        sessionId="find-occurrences"
        find={find}
        expanded={new Set()}
        onToggleActivity={() => {}}
      />
    );
  }
  await draw(<Transcript />);
  await act(async () => find.show("match"));
  expect(button("Show less")).toBeDefined();
  await act(async () => button("Show less")!.click());
  expect(host.querySelector(".is-clamped")).not.toBeNull();
  await act(async () => find.next());
  expect(host.querySelector(".is-clamped")).toBeNull();
});

test("live render rows leave the card head free of the floating Copy", async () => {
  const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
  const rows: AcpmuxRow[] = [
    {
      ...prompt("render-copy", "card source"),
      kind: "render",
      items: [
        {
          kind: "tool",
          text: "card source",
          tool: {
            id: "render-copy",
            title: "render",
            inputSummary: JSON.stringify({ html: "<p>Preview</p>" }),
            status: "completed",
          },
        },
      ],
    },
  ];
  const transcript = (
    <VirtualTranscript rows={rows} sessionId="render-copy" expanded={new Set()} onToggleActivity={() => {}} />
  );
  await draw(transcript);
  expect(host.querySelector(".acpmux-row__copy")).not.toBeNull();
  act(() => configureLabs({ labs: { liveRender: true } }));
  expect(host.querySelector(".acpmux-render-card") !== null).toBe(true);
  expect(host.querySelector(".acpmux-row__copy") === null).toBe(true);
});

test("context details open on hover and focus without moving focus, and still open on click", async () => {
  const { ContextRing } = await import("../src/agent-session/acpmux/ComposerPickers");
  act(() => configureLabs({ labs: { contextMeter: true } }));
  await draw(<ContextRing used={40000} size={100000} />);
  const ring = host.querySelector<HTMLButtonElement>(".acpmux-context-ring")!;
  await act(async () => {
    ring.dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 450));
  });
  expect(document.querySelector(".acpmux-context-tokens")?.textContent).toContain("40K");
  expect(document.activeElement).not.toBe(document.querySelector(".acpmux-context-compact"));
  await draw(null);
  await draw(<ContextRing used={40000} size={100000} />);
  const focused = host.querySelector<HTMLButtonElement>(".acpmux-context-ring")!;
  await act(async () => focused.focus());
  expect(document.querySelector(".acpmux-context-tokens")?.textContent).toContain("40K");
  expect(document.activeElement).toBe(focused);
});

test("collapsing a prompt anchors its toggle through transcript layout", async () => {
  const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
  const { expandPrompt } = await import("../src/agent-session/acpmux/conversation/promptCollapse");
  act(() => configureLabs({ labs: { promptCollapse: true } }));
  const text = Array.from({ length: 50 }, (_, n) => `line ${n}`).join("\n");
  const rows = [
    prompt("anchored", text),
    ...Array.from({ length: 12 }, (_, n) => ({ ...prompt(`tail-${n}`, "Answer"), kind: "assistant" as const })),
  ];
  expandPrompt("anchored", true, "anchor-toggle");
  const prototype = dom.window.HTMLElement.prototype;
  const rect = prototype.getBoundingClientRect;
  const viewport = Object.getOwnPropertyDescriptor(prototype, "clientHeight");
  Object.defineProperty(prototype, "clientHeight", { configurable: true, get: () => 600 });
  prototype.getBoundingClientRect = function () {
    const bounds = rect.call(this);
    const scroller = host.querySelector<HTMLElement>(".acpmux-scroll");
    const tall = host.querySelector('.cv-user__expand[aria-expanded="true"]') !== null;
    if (this.matches(".cv-user__expand"))
      return new dom.window.DOMRect(0, (tall ? 1100 : 250) - (scroller?.scrollTop ?? 0), 80, 24);
    if (this.hasAttribute("data-row-id"))
      return new dom.window.DOMRect(0, 0, 700, this.dataset.rowId === "anchored" ? (tall ? 1200 : 350) : 300);
    return bounds;
  };
  try {
    await draw(
      <VirtualTranscript
        rows={rows}
        sessionId="anchor-toggle"
        openAt={{ rowId: "anchored", offset: 900 }}
        expanded={new Set()}
        onToggleActivity={() => {}}
      />,
    );
    const scroller = host.querySelector<HTMLElement>(".acpmux-scroll")!;
    const toggle = button("Show less")!;
    const before = toggle.getBoundingClientRect().top;
    await act(async () => toggle.click());
    expect(button("Show more")!.getBoundingClientRect().top).toBeCloseTo(before, 1);
    expect(scroller.scrollTop).toBeCloseTo(50, 1);
  } finally {
    prototype.getBoundingClientRect = rect;
    if (viewport) Object.defineProperty(prototype, "clientHeight", viewport);
    else Reflect.deleteProperty(prototype, "clientHeight");
  }
});
