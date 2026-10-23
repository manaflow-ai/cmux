// l10n-allow-file: test fixture prompts, answers and tool titles, not shipped UI.
// Leo (2026-10-21): "and we shuold also have some animation for collapsing and expanding". The
// tool, command, MCP, thought and tool-group folds already play the shared fold (fold.ts, #23093);
// "Worked for" opens and closes whole virtual rows, which played no motion: the rows below jumped
// and what it hid vanished. Now (turnFold.ts) the thread carries `data-turn-fold` while it plays,
// the rows below slide from where they were drawn, the rows it reveals fade in and copies of the
// rows it hides fade out. With the pane's animations off it toggles at once. jsdom has no layout: a
// row is drawn at its translateY, and an element in it at the row's top less the scroller's offset.
import { afterAll, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
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

const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
const offsets = new WeakMap<object, number>();
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: object, value: number) {
    offsets.set(this, value);
  },
});
const scroller = () => dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
/// Where an element in a row is drawn in the viewport: its row's place less the offset. Rows report
/// no drawn height (0 is "not laid out"), so they place by their estimates.
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  const row = this.closest<HTMLElement>(".acpmux-row");
  const at = row ? Number(/translateY\(([-\d.]+)px\)/.exec(row.style.transform)?.[1] ?? 0) : 0;
  const top = row ? at - (scroller()?.scrollTop ?? 0) : 0;
  return { top, bottom: top, left: 0, right: 0, width: 0, height: 0, x: 0, y: top, toJSON() {} } as DOMRect;
};

// JSDOM has no Web Animations: record each one, ended by the test.
type Played = {
  node: HTMLElement;
  keyframes: Keyframe[];
  options: KeyframeAnimationOptions;
  end: () => void;
  finished: boolean;
};
let played: Played[] = [];
(dom.window.HTMLElement.prototype as unknown as { animate: unknown }).animate = function (
  this: HTMLElement,
  keyframes: Keyframe[],
  options: KeyframeAnimationOptions,
) {
  const one: Played = { node: this, keyframes, options, end: () => animation.onfinish?.(), finished: false };
  const animation = {
    onfinish: null as null | (() => void),
    oncancel: null as null | (() => void),
    cancel() {},
    finish() {
      one.finished = true;
      animation.onfinish?.();
    },
  };
  played.push(one);
  return animation;
};
beforeEach(() => {
  played = [];
  delete dom.window.document.documentElement.dataset.agentMotion;
});

// The page's clock, which the test moves on past a hold (foldAnchor.ts) instead of waiting it out.
const clock = performance.now.bind(performance);
let skew = 0;
performance.now = () => clock() + skew;

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { endTurnFold, startTurnFold } = await import("../src/agent-session/acpmux/conversation/turnFold");

afterAll(() => {
  performance.now = clock;
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const call = (id: string) => ({
  kind: "tool",
  text: "",
  tool: { id, title: `Read src/${id}.ts`, kind: "read", status: "completed", output: `contents of ${id}` },
});
/// A turn that worked before it answered: its "Worked for" line opens to the calls.
const turn = (index: number) => [
  row(`t${index}-user`, "user", { text: `Question ${index}` }),
  row(`t${index}-run`, "activity", { items: Array.from({ length: 8 }, (_, step) => call(`t${index}-${step}`)) }),
  row(`t${index}-answer`, "assistant", { text: `Answer ${index}.\n\nWith a second paragraph so the turn has height.` }),
  row(`t${index}-end`, "turnSummary", { status: "completed", toolCount: 8 }),
];
const source = Array.from({ length: 12 }, (_, index) => turn(index)).flat();
const workedId = (index: number) => `${WORKED}-t${index}-user`;

/// The transcript as the pane draws it: a click on "Worked for" toggles it in `expanded`.
function mount(initial: Set<string>) {
  const root = createRoot(dom.window.document.getElementById("root")!);
  let expanded = initial;
  const render = () =>
    root.render(
      <VirtualTranscript
        rows={turnView(source, expanded)}
        sessionId="session-1"
        expanded={expanded}
        onToggleActivity={(id) => {
          const next = new Set(expanded);
          if (next.has(id)) next.delete(id);
          else next.add(id);
          expanded = next;
          render();
        }}
      />,
    );
  return { root, render };
}
const line = (index: number) =>
  dom.window.document.querySelector<HTMLElement>(`[data-row-id="${workedId(index)}"] button.cv-worked`)!;

const thread = () => dom.window.document.querySelector<HTMLElement>(".acpmux-thread")!;
const spacerHeight = () => parseFloat(dom.window.document.querySelector<HTMLElement>(".acpmux-spacer")!.style.height);
const rowOf = (node: HTMLElement) => node.dataset.rowId ?? "";
/// The slides played on rows: each row's id and how far from its place it starts (px).
const slides = () =>
  played
    .filter((one) => typeof one.keyframes[0]?.translate === "string")
    .map((one) => ({ id: rowOf(one.node), from: parseFloat(String(one.keyframes[0]!.translate).split(" ")[1]!) }));
const fades = (from: number) => played.filter((one) => one.keyframes[0]?.opacity === from);
const ghosts = () => [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-row--fold-ghost")];
/// The rows turn `index`'s open "Worked for" shows: every drawn row of the turn but its prompt,
/// line, answer and footer.
const shownBy = (index: number) => {
  const own = new Set([`t${index}-user`, workedId(index), `t${index}-answer`, `t${index}-end`]);
  return [...dom.window.document.querySelectorAll<HTMLElement>("[data-row-id]")]
    .map(rowOf)
    .filter((id) => id.startsWith(`t${index}-`) && !own.has(id));
};

test("opening Worked for marks the thread, fades in the rows it reveals and slides the rows below down", async () => {
  const { root, render } = mount(new Set());
  try {
    await act(async () => render());
    const closed = spacerHeight();
    await act(async () => line(11).click());
    expect(line(11).getAttribute("aria-expanded")).toBe("true");
    expect(thread().getAttribute("data-turn-fold")).toBe("open");
    expect(spacerHeight()).toBeGreaterThan(closed);
    // Each revealed row fades in once, on the fold's token (180 ms with no host).
    const revealed = shownBy(11);
    expect(revealed.length).toBeGreaterThan(0);
    const faded = fades(0).map((one) => rowOf(one.node));
    for (const id of revealed) expect(faded).toContain(id);
    expect(new Set(faded).size).toBe(faded.length);
    expect(fades(0)[0]!.options.duration).toBe(180);
    // The rows below start where they were drawn (above their new place) and slide down; the
    // clicked line and the rows above it never move.
    const moved = slides();
    expect(moved.length).toBeGreaterThan(0);
    for (const slide of moved) {
      expect(slide.id === `t11-answer` || slide.id === `t11-end`).toBe(true);
      expect(slide.from).toBeLessThan(0);
    }
    // No row's own entrance plays on top of the fold.
    expect(dom.window.document.querySelectorAll(".acpmux-row--enter").length).toBe(0);
    // The state goes once the fold is over.
    skew += 10_000;
    await act(async () => render());
    expect(thread().hasAttribute("data-turn-fold")).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});

test("closing Worked for fades out copies of what it hid, slides the rows below up and ends at the closed height", async () => {
  const { root, render } = mount(new Set());
  try {
    await act(async () => render());
    const closed = spacerHeight();
    await act(async () => line(11).click());
    skew += 10_000;
    await act(async () => render());
    const hidden = shownBy(11);
    expect(hidden.length).toBeGreaterThan(0);
    played = [];

    await act(async () => line(11).click());
    expect(line(11).getAttribute("aria-expanded")).toBe("false");
    expect(thread().getAttribute("data-turn-fold")).toBe("close");
    // The rows leave the transcript at once; their copies fade out where they were drawn, with no
    // ids, nothing to focus, and hidden from assistive technology.
    expect(shownBy(11)).toEqual([]);
    expect(ghosts().length).toBe(hidden.length);
    for (const ghost of ghosts()) {
      expect(ghost.getAttribute("aria-hidden")).toBe("true");
      expect(ghost.hasAttribute("inert")).toBe(true);
      expect(ghost.hasAttribute("data-row-id")).toBe(false);
      expect(ghost.querySelector("[id], [data-row-id], [tabindex]")).toBeNull();
    }
    expect(fades(1).length).toBe(hidden.length);
    // The rows below start where they were drawn (below their new place) and slide up.
    const moved = slides();
    expect(moved.length).toBeGreaterThan(0);
    for (const slide of moved) expect(slide.from).toBeGreaterThan(0);
    // The fold ends at the closed transcript: as tall as before it opened, and no copies left.
    expect(spacerHeight()).toBe(closed);
    for (const one of fades(1)) one.end();
    expect(ghosts()).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("with the pane's animations off, Worked for opens and closes at once", async () => {
  dom.window.document.documentElement.dataset.agentMotion = "off";
  const { root, render } = mount(new Set());
  try {
    await act(async () => render());
    const closed = spacerHeight();
    await act(async () => line(11).click());
    expect(line(11).getAttribute("aria-expanded")).toBe("true");
    expect(shownBy(11).length).toBeGreaterThan(0);
    expect(thread().hasAttribute("data-turn-fold")).toBe(false);
    await act(async () => line(11).click());
    expect(line(11).getAttribute("aria-expanded")).toBe("false");
    expect(shownBy(11)).toEqual([]);
    expect(ghosts()).toEqual([]);
    expect(thread().hasAttribute("data-turn-fold")).toBe(false);
    expect(spacerHeight()).toBe(closed);
    expect(played).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a second toggle while a close plays lands that close first, then holds its own line", async () => {
  const { root, render } = mount(new Set([workedId(10)]));
  try {
    await act(async () => render());
    await act(async () => line(10).click());
    expect(ghosts().length).toBeGreaterThan(0);
    const first = [...played];
    expect(first.length).toBeGreaterThan(0);
    // Turn 11's line, clicked while the rows below turn 10's still slide: nothing of the first fold
    // keeps moving or stays drawn, so the line the second hold measures stays where it was clicked.
    await act(async () => line(11).click());
    for (const one of first) expect(one.finished).toBe(true);
    expect(ghosts()).toEqual([]);
    expect(line(11).getAttribute("aria-expanded")).toBe("true");
    expect(thread().getAttribute("data-turn-fold")).toBe("open");
  } finally {
    await act(async () => root.unmount());
  }
});

test("a reader who scrolls while a fold plays moves every row alike: no row slides against the scroll", async () => {
  const { root, render } = mount(new Set());
  try {
    await act(async () => render());
    await act(async () => line(11).click());
    played = [];
    // A scroll mid-fold places the rows again; none of them changed place relative to the line.
    scroller().scrollTop = Math.max(0, scroller().scrollTop - 120);
    await act(async () => render());
    // (A copy of a row the scroll unmounted goes on with its slide: it is no row of the transcript.)
    expect(slides().filter((slide) => slide.id !== "")).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a row that mounts mid-fold joins the slide part way, on the fold's clock", async () => {
  const { root, render } = mount(new Set());
  try {
    await act(async () => render());
    await act(async () => line(10).click());
    const first = slides().find((slide) => slide.id === "t10-answer");
    expect(first).toBeDefined();
    played = [];
    // Later in the fold, the row is drawn again as a new element (the virtualizer remounted it).
    skew += 60;
    const answer = dom.window.document.querySelector<HTMLElement>('[data-row-id="t10-answer"]')!;
    const again = answer.cloneNode(true) as HTMLElement;
    answer.replaceWith(again);
    await act(async () => render());
    const joined = played.find((one) => one.node === again && typeof one.keyframes[0]?.translate === "string");
    expect(joined).toBeDefined();
    expect(parseFloat(String(joined!.keyframes[0]!.translate).split(" ")[1]!)).toBe(first!.from);
    expect(Number(joined!.options.delay)).toBeLessThanOrEqual(-60);
    // React's own element goes back before it unmounts.
    again.replaceWith(answer);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a fold its timer ends lets go of the rows it tracked, and the thread's state goes", () => {
  const document = dom.window.document;
  const host = document.createElement("div");
  host.className = "acpmux-thread";
  document.body.append(host);
  const ids = ["a", "b", "c", "d"];
  for (const [index, id] of ids.entries()) {
    const article = document.createElement("article");
    article.className = "acpmux-row";
    article.dataset.rowId = id;
    article.setAttribute("aria-posinset", String(index + 1));
    host.append(article);
  }
  try {
    const fold = startTurnFold(
      host,
      "a",
      true,
      { count: ids.length, idAt: (index) => ids[index], tops: [0, 20, 40, 60] },
      "s",
    );
    expect(fold).toBeDefined();
    expect(fold!.moving.size).toBe(3);
    expect(host.getAttribute("data-turn-fold")).toBe("open");
    endTurnFold(host, fold);
    expect(host.hasAttribute("data-turn-fold")).toBe(false);
    expect(fold!.moving.size).toBe(0);
    expect(fold!.animations.size).toBe(0);
    expect(fold!.startRows.count).toBe(0);
  } finally {
    host.remove();
  }
});
