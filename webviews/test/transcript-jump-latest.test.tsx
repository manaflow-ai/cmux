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
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

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
