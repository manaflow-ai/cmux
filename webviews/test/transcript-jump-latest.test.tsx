// The transcript's jump-to-latest button (ChatGPT and Codex style): a glass circle with a down arrow,
// centered above the composer, shown only while the reader is scrolled up from the latest message.
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
const jumps: number[] = [];
dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) {
  const top = typeof options === "number" ? 0 : (options?.top ?? 0);
  jumps.push(top);
  this.scrollTop = top;
} as typeof HTMLElement.prototype.scrollTo;

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript, FOLLOW_BOTTOM_DEADBAND_PX } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const turns = Array.from({ length: 30 }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();
const nextFrame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));

test("a stale queued latest frame reports the live parked state to its parent", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const expanded = new Set<string>();
  const rows = turnView(turns, expanded);
  const changes: boolean[] = [];
  const onFollowingChange = (following: boolean) => changes.push(following);
  const draw = (shown: AcpmuxRow[]) =>
    root.render(
      <VirtualTranscript
        rows={shown}
        jumpButton
        onToggleActivity={() => {}}
        expanded={expanded}
        onFollowingChange={onFollowingChange}
      />,
    );
  try {
    await act(async () => draw(rows));
    const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const latest = scroller.scrollHeight - VIEWPORT;
    const parked = latest - VIEWPORT;
    changes.length = 0;
    await act(async () => {
      // Queue bottom-follow, then a rail/native default moves the DOM before the queued RAF.
      scroller.dispatchEvent(new dom.window.Event("scroll"));
      scroller.scrollTop = parked;
      await nextFrame();
    });
    expect(changes.at(-1)).toBe(false);
    expect(scroller.scrollTop).toBe(parked);
    // A later placement uses the same authoritative intent and cannot snap back to the latest row.
    await act(async () => draw([...rows, row("later-reply", "assistant", "New output below the reader.")]));
    expect(scroller.scrollTop).toBe(parked);
    expect(changes.at(-1)).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a parked reader's processed or non-upward input does not double-apply a row above that shrank, even just after an upward wheel", async () => {
  // Astra P2 on #26718: recent non-upward input (a click, a downward key or wheel) must not make the
  // live offset, which the browser already moved up for a row above that shrank, the anchor base.
  const long = `Answer 1.\n\n${"A long paragraph that later collapses. ".repeat(80)}`;
  const tall = turns.map((r) => (r.id === "t1-answer" ? { ...r, text: long } : r));
  const short = turns.map((r) => (r.id === "t1-answer" ? { ...r, text: "Answer 1.", version: 2 } : r));
  const expanded = new Set<string>();
  const heightOf = async (shown: AcpmuxRow[]) => {
    const host = dom.window.document.createElement("div");
    dom.window.document.body.append(host);
    const probe = createRoot(host);
    await act(async () =>
      probe.render(
        <VirtualTranscript rows={turnView(shown, expanded)} onToggleActivity={() => {}} expanded={expanded} />,
      ),
    );
    const height = parseFloat(host.querySelector<HTMLElement>(".acpmux-spacer")!.style.height);
    await act(async () => probe.unmount());
    host.remove();
    return height;
  };
  const shrink = (await heightOf(tall)) - (await heightOf(short));
  expect(shrink).toBeGreaterThan(FOLLOW_BOTTOM_DEADBAND_PX * 4);
  const realNow = performance.now;
  // Astra P2 (third round): with no click at all, the upward wheel's scroll event has already been
  // processed, so the shrink inside its 1 s window is layout work, not unprocessed reader movement.
  for (const { lapse, click } of [
    { lapse: 1_100, click: true },
    { lapse: 0, click: true },
    { lapse: 0, click: false },
  ]) {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const draw = (shown: AcpmuxRow[]) =>
      root.render(
        <VirtualTranscript rows={turnView(shown, expanded)} onToggleActivity={() => {}} expanded={expanded} />,
      );
    try {
      await act(async () => draw(tall));
      const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const parked = Math.round(scrollerEnd(scroller) / 2);
      await act(async () => {
        scroller.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: -120 }));
        scroller.scrollTop = parked;
        scroller.dispatchEvent(new dom.window.Event("scroll"));
        await nextFrame();
        await nextFrame();
      });
      expect(scroller.scrollTop).toBe(parked);
      const anchor = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].find(
        (el) => parseFloat(el.style.top) >= parked,
      )!;
      const id = anchor.dataset.rowId!;
      const seen = parseFloat(anchor.style.top) - parked;
      // With the upward wheel's input window (1 s) lapsed, and inside it: the click that follows is
      // the reader's latest input either way, and it does not move the view up.
      if (lapse) performance.now = () => realNow.call(performance) + lapse;
      await act(async () => {
        // A click (not upward movement), then the shrink above lands with the browser's own offset
        // adjustment already applied before its scroll event.
        if (click) scroller.dispatchEvent(new dom.window.Event("pointerdown"));
        scroller.scrollTop = parked - shrink;
        draw(short);
      });
      const row = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].find((el) => el.dataset.rowId === id)!;
      // The scroller keeps whole pixels while the shrink is fractional: at most a pixel of rounding.
      expect(Math.abs(parseFloat(row.style.top) - scroller.scrollTop - seen)).toBeLessThanOrEqual(1);
    } finally {
      performance.now = realNow;
      await act(async () => root.unmount());
    }
  }
});

test("scrolled up, a static button above the composer jumps to the latest message while a reply streams", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const rows = turnView(turns, new Set());
  const render = (working: boolean) =>
    root.render(
      <VirtualTranscript rows={rows} working={working} jumpButton onToggleActivity={() => {}} expanded={new Set()} />,
    );
  try {
    await act(async () => render(false));
    const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const latest = scrollerEnd(scroller);
    expect(latest).toBeGreaterThan(VIEWPORT);
    const button = () => dom.window.document.querySelector<HTMLButtonElement>(".acpmux-jump-latest");
    // It opens at the latest message: no button to show.
    expect(scroller.scrollTop).toBe(latest);
    expect(button()?.dataset.shown).toBeUndefined();

    // The reader scrolls up: the button shows.
    scroller.scrollTop = 0;
    await act(async () => {
      scroller.dispatchEvent(new dom.window.Event("scroll"));
      await nextFrame();
    });
    expect(button()?.dataset.shown).toBe("");
    expect(button()?.getAttribute("aria-label")).toBe("Jump to latest");
    // The arrow alone does not say what it does: hovering it names it.
    expect(button()?.title).toBe("Jump to latest");
    expect(button()?.dataset.working).toBeUndefined();

    // A reply streams below the viewport: the control stays static and only its accessible label changes.
    await act(async () => render(true));
    expect(button()?.dataset.working).toBeUndefined();
    expect(button()?.getAttribute("aria-label")).toBe("Jump to latest, still replying");
    expect(button()?.title).toBe("Jump to latest, still replying");

    // A click goes to the latest message, and the button hides there.
    jumps.length = 0;
    await act(async () => button()!.click());
    expect(scroller.scrollTop).toBe(latest);
    await act(async () => {
      scroller.dispatchEvent(new dom.window.Event("scroll"));
      await nextFrame();
    });
    expect(button()?.dataset.shown).toBeUndefined();
    // Hidden, it is inert: out of the tab order and the accessibility tree.
    expect(button()?.hasAttribute("inert")).toBe(true);

    // Scrolled up again, then the transcript changes to one that fits the viewport (another chat):
    // nothing is below, so the button hides without a scroll.
    scroller.scrollTop = 0;
    await act(async () => {
      scroller.dispatchEvent(new dom.window.Event("scroll"));
      await nextFrame();
    });
    expect(button()?.dataset.shown).toBe("");
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(turns.slice(0, 3), new Set())}
          jumpButton
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    expect(button()?.dataset.shown).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("once shown, the button stays shown back inside its distance and hides only at the latest message", async () => {
  // Leo 2026-10-28: "I don't want to see that fucking, like, jump to bottom button be jumping around
  // jittering and flickering like that." A gesture that turns back across the distance it shows at
  // turned it off and on again; it now hides only once the view is back at the latest message.
  const root = createRoot(dom.window.document.getElementById("root")!);
  const rows = turnView(turns, new Set());
  try {
    await act(async () =>
      root.render(<VirtualTranscript rows={rows} jumpButton onToggleActivity={() => {}} expanded={new Set()} />),
    );
    const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const latest = scrollerEnd(scroller);
    const button = () => dom.window.document.querySelector<HTMLButtonElement>(".acpmux-jump-latest");
    const scrollTo = async (top: number) => {
      scroller.scrollTop = top;
      await act(async () => {
        scroller.dispatchEvent(new dom.window.Event("scroll"));
        await nextFrame();
      });
    };
    // 40px up: not yet far enough to show.
    await scrollTo(latest - 40);
    expect(button()?.dataset.shown).toBeUndefined();
    // 120px up: it shows.
    await scrollTo(latest - 120);
    expect(button()?.dataset.shown).toBe("");
    // Back down to 40px and up to 120px, twice: it stays shown throughout.
    for (const top of [latest - 40, latest - 120, latest - 40]) {
      await scrollTo(top);
      expect(button()?.dataset.shown).toBe("");
    }
    // At the latest message it hides.
    await scrollTo(latest);
    expect(button()?.dataset.shown).toBeUndefined();
    // And shows again only past its distance.
    await scrollTo(latest - 40);
    expect(button()?.dataset.shown).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a keyboard jump hands focus to the composer instead of losing it with the hidden button", async () => {
  const doc = dom.window.document;
  const composer = doc.createElement("textarea");
  doc.body.append(composer);
  const root = createRoot(doc.getElementById("root")!);
  const rows = turnView(turns, new Set());
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={rows}
          jumpButton
          focusComposer={() => composer.focus()}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    const scroller = doc.querySelector<HTMLElement>(".acpmux-scroll")!;
    const button = doc.querySelector<HTMLButtonElement>(".acpmux-jump-latest")!;
    scroller.scrollTop = 0;
    await act(async () => {
      scroller.dispatchEvent(new dom.window.Event("scroll"));
      await nextFrame();
    });
    expect(button.dataset.shown).toBe("");

    // A pointer click (WebKit does not focus the button) leaves focus where the reader had it.
    const elsewhere = doc.createElement("input");
    doc.body.append(elsewhere);
    elsewhere.focus();
    await act(async () => button.click());
    expect(doc.activeElement).toBe(elsewhere);

    // Tab to the button and press Return or Space: it hides once there, so the composer takes focus.
    // The reader wheels back up first (the jump's glide ends at their input).
    scroller.dispatchEvent(new dom.window.Event("wheel"));
    scroller.scrollTop = 0;
    await act(async () => {
      scroller.dispatchEvent(new dom.window.Event("scroll"));
      await nextFrame();
    });
    expect(button.dataset.shown).toBe("");
    button.focus();
    expect(doc.activeElement).toBe(button);
    await act(async () => button.click());
    await act(async () => {
      scroller.dispatchEvent(new dom.window.Event("scroll"));
      await nextFrame();
    });
    expect(button.hasAttribute("inert")).toBe(true);
    expect(doc.activeElement).toBe(composer);
    elsewhere.remove();
  } finally {
    await act(async () => root.unmount());
    composer.remove();
  }
});
