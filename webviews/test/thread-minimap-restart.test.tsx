// A chat drawn again after a restart paints its prompt rail final on the first frame (Leo, 2026-11-25:
// "and then the scroll rail re-rednered"). The rail took its rows from the summary's count (turnCount)
// until the prompt index answered, seconds later; the count names carried and watched turns the index
// does not, so every tick and the band moved by the difference. The rail now keeps that difference per
// chat (railCountSeed.ts) and seeds the next open with it. And a rail mounting with its chat no longer
// fades in: only one appearing in a chat already drawn without it does.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { teardownDom } from "./support/domTeardown";
import { withRail } from "./support/railFrame";
// These tests drive the compact (Codex) rail; the default arm draws no minimap (layout.experiment.ts).
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});

const resizeObservers = new Set<{ fire(): void }>();
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
  // Kept, so a test that changes the transcript's height can tell the pane it resized.
  ResizeObserver: class {
    constructor(private readonly callback: () => void) {
      resizeObservers.add(this);
    }
    observe() {}
    unobserve() {}
    disconnect() {
      resizeObservers.delete(this);
    }
    fire() {
      this.callback();
    }
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
let viewport = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => viewport });
// Wide enough for the minimap's pane-edge rail in these layout tests.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 1040 });
const offsets = new WeakMap<object, number>();
// Read the pitch the mounted rail gives CSS; jsdom does not lay out its rows.
const railPitch = () =>
  Number.parseFloat(
    dom.window.document
      .querySelector<HTMLElement>(".acpmux-minimap__list")!
      .style.getPropertyValue("--acpmux-minimap-pitch"),
  );
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: object, value: number) {
    offsets.set(this, value);
  },
});
// A browser scrolls the rail's list to a row that takes focus; the list's scroll event then moves the
// drawn rows along. jsdom scrolls nothing, so focus does it here.
dom.window.document.addEventListener(
  "focusin",
  (event) => {
    const tick = (event.target as HTMLElement).closest?.<HTMLElement>("[data-tick]");
    const list = tick?.closest<HTMLElement>(".acpmux-minimap__list");
    if (!tick || !list) return;
    const top = Number(tick.dataset.tick) * railPitch();
    const room = Number.parseFloat(list.parentElement!.style.height);
    const at = list.scrollTop;
    if (top >= at && top + railPitch() <= at + room) return;
    list.scrollTop = top < at ? top : top + railPitch() - room;
    list.dispatchEvent(new dom.window.Event("scroll"));
  },
  true,
);
const jumps: number[] = [];
dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) {
  const top = typeof options === "number" ? 0 : (options?.top ?? 0);
  jumps.push(top);
  this.scrollTop = top;
} as typeof HTMLElement.prototype.scrollTo;

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { PromptHeads } = await import("../src/agent-session/acpmux/promptHeads");
const { resetPromptCountSeedsForTests, seededPromptCount } =
  await import("../src/agent-session/acpmux/threadMinimap/railCountSeed");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
/// Turns `from` up to `to`, each a prompt (`user-<seq>`), a reply and its end.
const span = (from: number, to: number) =>
  Array.from({ length: to - from }, (_, at) => {
    const index = from + at;
    return [
      row(`user-${index * 10}`, "user", `Question ${index}`),
      row(`t${index}-answer`, "assistant", `Answer ${index}.`),
      { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
    ];
  }).flat();
const prompts = (from: number, to: number) => span(from, to).filter((entry) => entry.kind === "user");
const setSize = (document: Document) =>
  Number(document.querySelector(".acpmux-minimap__entry")?.getAttribute("aria-setsize") ?? NaN);

test("the rail's rows on the next open are the index's, not the summary's count", async () => {
  resetPromptCountSeedsForTests();
  const document = dom.window.document;
  const sessionId = "restart-count";
  // 30 turns by the summary; the index names 25 prompts, 20 older than the 10 held.
  const held = span(20, 30);
  const draw = (root: ReturnType<typeof createRoot>, props: { promptCount?: number; earlier?: unknown }) =>
    withRail(
      act(async () =>
        root.render(
          <VirtualTranscript
            rows={turnView(held, new Set())}
            sessionId={sessionId}
            canLoadOlder
            onToggleActivity={() => {}}
            expanded={new Set()}
            {...(props as object)}
          />,
        ),
      ),
    );
  let root = createRoot(document.getElementById("root")!);
  try {
    await draw(root, { promptCount: 35 });
    expect(setSize(document)).toBe(35);
    // The index answers: the count goes, 20 earlier prompts come.
    await draw(root, { earlier: PromptHeads.fromRows(prompts(0, 20)) });
    expect(setSize(document)).toBe(30);
  } finally {
    await act(async () => root.unmount());
  }
  expect(seededPromptCount(sessionId, 35)).toBe(30);
  // The next open (a restart, a switch back) draws the count less what it was over by.
  root = createRoot(document.getElementById("root")!);
  try {
    await draw(root, { promptCount: 35 });
    expect(setSize(document)).toBe(30);
    // A chat with more turns since: the count grows, the offset holds.
    expect(seededPromptCount(sessionId, 40)).toBe(35);
    // Another chat is not seeded.
    expect(seededPromptCount("other", 35)).toBe(35);
  } finally {
    await act(async () => root.unmount());
  }
}, 60_000);

test("a rail mounting with its chat paints at once; one appearing in a drawn chat fades in", async () => {
  resetPromptCountSeedsForTests();
  const document = dom.window.document;
  const draw = (root: ReturnType<typeof createRoot>, rows: AcpmuxRow[], sessionId: string) =>
    withRail(
      act(async () =>
        root.render(
          <VirtualTranscript
            rows={turnView(rows, new Set())}
            sessionId={sessionId}
            onToggleActivity={() => {}}
            expanded={new Set()}
          />,
        ),
      ),
    );
  const rail = () => document.querySelector<HTMLElement>(".acpmux-minimap__rail");
  const root = createRoot(document.getElementById("root")!);
  try {
    // Drawn again with its prompts (a restart, a switch): no entrance.
    await draw(root, span(0, 12), "restart-mount");
    expect(rail()).not.toBeNull();
    expect(rail()!.hasAttribute("data-arrive")).toBe(false);
    // Another chat with its prompts: no entrance either.
    await draw(root, span(0, 6), "restart-other");
    expect(rail()!.hasAttribute("data-arrive")).toBe(false);
    // A new chat drawn with no prompt, then its first: the rail arrives.
    await draw(root, [], "restart-new");
    expect(rail()).toBeNull();
    await draw(root, span(0, 1), "restart-new");
    expect(rail()).not.toBeNull();
    expect(rail()!.hasAttribute("data-arrive")).toBe(true);
    // It stays drawn as more prompts come: the attribute is the arrival's, not each render's.
    await draw(root, span(0, 2), "restart-new");
    expect(rail()!.hasAttribute("data-arrive")).toBe(true);
  } finally {
    await act(async () => root.unmount());
  }
}, 60_000);
