// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The transcript's one jump control (jumpControl.ts, design/transcript-overlays.md). Leo, 2026-11-10,
// of Jump up stacked on Jump to latest with the unread pill under them: "There's also no point doubling
// up on this." One disc does the jump the view needs: up to "New since you looked" with its count while
// unread turns lie above, else down to the latest message while scrolled up, else none. An unread line
// older than the loaded pages is read in first (direct.ts `loadThrough`) so the jump lands on it.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { installJsdomScroller, scrollerEnd } from "./support/jsdomScroller";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
dom.window.document.documentElement.dataset.agentMotion = "off";
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout: a 600 px viewport (the transcript's first height) over a long conversation,
// and a scroll offset the test moves as the reader would.
const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => VIEWPORT);
dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) {
  this.scrollTop = typeof options === "number" ? 0 : (options?.top ?? 0);
} as typeof HTMLElement.prototype.scrollTo;

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { SINCE_DIVIDER } = await import("../src/agent-session/acpmux/model");
const { resetUnreadForTest } = await import("../src/agent-session/acpmux/conversation/unreadState");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const turn = (index: number) => [
  row(`user-${index * 3 + 1}`, "user", `Question ${index}`),
  row(`assistant-${index * 3 + 2}`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`end-${index * 3 + 3}`, "turnSummary"), status: "completed", durationMs: 1_000 },
];
const MARK = "chat-1:30";
/// Ten turns the person saw, the line after record 30, then nine that ended while they were away.
const since: AcpmuxRow = {
  ...row(SINCE_DIVIDER, SINCE_DIVIDER),
  since: { key: MARK, seq: 30, turns: 9 },
};
const seen = Array.from({ length: 10 }, (_, index) => turn(index)).flat();
const away = Array.from({ length: 9 }, (_, index) => turn(10 + index)).flat();
const nextFrame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));

/// Every jump control drawn, and what the one there says.
const controls = () => {
  const doc = dom.window.document;
  const all = [...doc.querySelectorAll<HTMLButtonElement>(".acpmux-jump-latest")];
  const one = all[0];
  return {
    count: all.length,
    // The controls the transcript drew before it had one: none of them may come back.
    extra: doc.querySelectorAll(".acpmux-jump-up, .acpmux-since-jump").length,
    shown: one?.hasAttribute("data-shown") ?? false,
    jump: one?.dataset.jump,
    badge: one?.querySelector(".acpmux-jump-latest__count")?.textContent ?? undefined,
  };
};

async function open(props: { loadThrough?: (seq: number) => Promise<boolean>; onJumpToSince?: () => void }) {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const rows = turnView([...seen, since, ...away], new Set());
  await act(async () =>
    root.render(
      <VirtualTranscript
        rows={rows}
        jumpButton
        sinceKey={MARK}
        onJumpToSince={props.onJumpToSince ?? (() => {})}
        loadThrough={props.loadThrough}
        onToggleActivity={() => {}}
        expanded={new Set()}
      />,
    ),
  );
  return root;
}

test("back in a chat with unread turns above: one control, pointing up, with their count", async () => {
  resetUnreadForTest();
  const root = await open({});
  try {
    const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    expect(scroller.scrollTop).toBe(scrollerEnd(scroller));
    expect(controls()).toEqual({ count: 1, extra: 0, shown: true, jump: "unread", badge: "9" });
    // Scrolled up past Jump to latest's distance, the line still above the view: still the one
    // control, never a second disc (the double-control regression, Leo's 2026-11-10 capture).
    scroller.scrollTop = scrollerEnd(scroller) - VIEWPORT / 3;
    await act(async () => {
      scroller.dispatchEvent(new dom.window.Event("scroll"));
      await nextFrame();
    });
    expect(controls()).toEqual({ count: 1, extra: 0, shown: true, jump: "unread", badge: "9" });
  } finally {
    await act(async () => root.unmount());
  }
});

test("the press reads in the history through the last seen record, then lands on the line", async () => {
  resetUnreadForTest();
  const calls: string[] = [];
  let release: (held: boolean) => void = () => {};
  const root = await open({
    loadThrough: (seq) => {
      calls.push(`load ${seq}`);
      return new Promise((resolve) => (release = resolve));
    },
    onJumpToSince: () => calls.push("reveal"),
  });
  try {
    await act(async () => dom.window.document.querySelector<HTMLButtonElement>(".acpmux-jump-latest")!.click());
    // The line's history is asked for first; the reveal waits for it.
    expect(calls).toEqual(["load 30"]);
    await act(async () => {
      release(true);
      await Promise.resolve();
    });
    expect(calls).toEqual(["load 30", "reveal"]);
    // Pressed, the unread jump has done its job: still at the latest message here (the spy moved
    // nothing), the control fades out instead of pointing up again for this return.
    expect(controls()).toMatchObject({ count: 1, extra: 0, shown: false });
  } finally {
    await act(async () => root.unmount());
  }
});

test("with nothing unread, the control is Jump to latest only while scrolled up, and nothing else", async () => {
  resetUnreadForTest();
  const root = createRoot(dom.window.document.getElementById("root")!);
  const rows = turnView([...seen, ...away], new Set());
  try {
    await act(async () =>
      root.render(<VirtualTranscript rows={rows} jumpButton onToggleActivity={() => {}} expanded={new Set()} />),
    );
    const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    // At the latest message: hidden. Jump up's old always-on places (the last prompt, the last stop)
    // never bring an up control.
    expect(controls()).toEqual({ count: 1, extra: 0, shown: false, jump: "latest", badge: undefined });
    scroller.scrollTop = 0;
    await act(async () => {
      scroller.dispatchEvent(new dom.window.Event("scroll"));
      await nextFrame();
    });
    expect(controls()).toEqual({ count: 1, extra: 0, shown: true, jump: "latest", badge: undefined });
  } finally {
    await act(async () => root.unmount());
  }
});
