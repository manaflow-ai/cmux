// l10n-allow-file: test fixture prompts, answers and tool titles, not shipped UI.
// Opening or closing anything in the transcript never moves the reader's view (Leo 2026-10-20:
// "Expanding/collapsing any tool call or collapsible must NOT scroll the user's view: anchor the
// clicked row in place"). Followed to the latest row, opening the last turn's "Worked for" used to
// put the view at the new latest row, so the line the reader clicked jumped up by everything it
// opened. jsdom has no layout: a row is drawn at its `top`, and an element in it at the row's
// top less the scroller's offset. A toggled "Worked for" also plays (turnFold.ts, Leo 2026-10-21: "and
// we shuold also have some animation for collapsing and expanding"): the rows below slide from where
// they were drawn, the rows it reveals fade in and copies of the rows it hides fade out.
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
  const at = row ? (Number.parseFloat(row.style.top) || 16) - 16 : 0; // less the thread's top padding
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
function mount(initial: Set<string>, rowsOf = () => source) {
  const root = createRoot(dom.window.document.getElementById("root")!);
  let expanded = initial;
  const render = () =>
    root.render(
      <VirtualTranscript
        rows={turnView(rowsOf(), expanded)}
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
const latest = () =>
  parseFloat(dom.window.document.querySelector<HTMLElement>(".acpmux-spacer")!.style.height) - VIEWPORT;

test("opening the last turn's Worked for while the view follows the latest row leaves the line where it was clicked", async () => {
  const { root, render } = mount(new Set());
  try {
    await act(async () => render());
    // Followed: the view rests at the latest row, the last turn's line in view.
    expect(scroller().scrollTop).toBe(latest());
    const before = line(11).getBoundingClientRect().top;
    expect(before).toBeGreaterThan(0);
    expect(before).toBeLessThan(VIEWPORT);
    const end = latest();

    await act(async () => line(11).click());
    expect(line(11).getAttribute("aria-expanded")).toBe("true");
    // The calls opened under the line; the line did not move, and the view no longer sits at the
    // (now further down) latest row.
    expect(line(11).getBoundingClientRect().top).toBe(before);
    expect(latest()).toBeGreaterThan(end);
    expect(scroller().scrollTop).toBeLessThan(latest());

    // A snapshot after the hold (here the same rows drawn again) does not pull the view back down.
    skew += 10_000;
    await act(async () => render());
    expect(line(11).getBoundingClientRect().top).toBe(before);
  } finally {
    await act(async () => root.unmount());
  }
});

test("closing an open Worked for scrolled up the transcript leaves its line where it was clicked", async () => {
  const { root, render } = mount(new Set([workedId(8)]));
  /// The reader scrolls to `top` (a wheel, then the browser's scroll event).
  const scrollTo = async (top: number) => {
    await act(async () => {
      scroller().dispatchEvent(new dom.window.Event("wheel"));
      scroller().scrollTop = top;
      scroller().dispatchEvent(new dom.window.Event("scroll"));
    });
  };
  try {
    await act(async () => render());
    // Up the transcript until turn 8's open line is drawn, then with it 200 px down the view.
    for (let top = latest(); !line(8) && top > 0; top -= VIEWPORT / 2) await scrollTo(top);
    await scrollTo(scroller().scrollTop + line(8).getBoundingClientRect().top - 200);
    const before = line(8).getBoundingClientRect().top;
    expect(before).toBe(200);
    expect(scroller().scrollTop).toBeLessThan(latest() - VIEWPORT);

    await act(async () => line(8).click());
    expect(line(8).getAttribute("aria-expanded")).toBe("false");
    expect(line(8).getBoundingClientRect().top).toBe(before);
  } finally {
    await act(async () => root.unmount());
  }
});

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
  const host = dom.window.document.createElement("div");
  host.innerHTML = ["a", "b", "c"]
    .map((id, at) => `<article class="acpmux-row" data-row-id="${id}" aria-posinset="${at + 1}"></article>`)
    .join("");
  const fold = startTurnFold(host, "a", true, { count: 3, idAt: (at) => "abc"[at], tops: [0, 20, 40] }, "s")!;
  expect([fold.moving.size, host.getAttribute("data-turn-fold")]).toEqual([2, "open"]);
  endTurnFold(host, fold);
  expect([fold.moving.size, fold.animations.size, fold.startRows.count, host.hasAttribute("data-turn-fold")]).toEqual([
    0,
    0,
    0,
    false,
  ]);
});

test("a token streamed while a fold plays runs no pass: only a row placed again does", async () => {
  let reply = "Streaming";
  const live = () => [...source, row("live-reply", "assistant", { text: reply, version: reply.length })];
  const { root, render } = mount(new Set(), live);
  try {
    await act(async () => render());
    await act(async () => line(11).click());
    expect(thread().getAttribute("data-turn-fold")).toBe("open");
    // A pass reads the thread's mounted rows; count those reads.
    const host = thread();
    const read = host.querySelectorAll.bind(host);
    let passes = 0;
    host.querySelectorAll = ((selector: string) => {
      if (selector.includes(":scope > .acpmux-row")) passes += 1;
      return read(selector);
    }) as typeof host.querySelectorAll;
    for (const token of [" the", " reply", " on"]) {
      reply += token;
      await act(async () => render());
    }
    expect(passes).toBe(0);
    expect(thread().getAttribute("data-turn-fold")).toBe("open");
    // A row placed again (the reply's height measured anew moves no row, so move one by hand) runs one.
    await act(async () => {
      host.querySelector<HTMLElement>('[data-row-id="t11-end"]')!.style.transform = "translateY(1px)";
    });
    expect(passes).toBeGreaterThan(0);
  } finally {
    await act(async () => root.unmount());
  }
});
