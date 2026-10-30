// The wave rail at the bottom of a long chat (Leo 2026-10-22: "I said it looked too short because
// it wouldn't show the highlighted bottom text where I was scrolling at the bottom, and it just
// didn't go to the bottom. It didn't show the bottom bits being highlighted."). A rail with more
// prompts than room scrolls its own list; that list kept only the band's first row in view, so the
// prompts below it, the chat's last ones among them, sat under the bottom fade or past the rail's
// end. The whole band now shows, clear of the fades, and at the bottom of the chat the list reaches
// its own end with the last ticks lit.
import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };
// Each test renders the whole transcript once per scroll step; jsdom takes about 5 s for that.
setDefaultTimeout(60_000);

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

// jsdom has no layout: a 600 px viewport (the transcript's first height) over a long conversation,
// and a scroll offset the test moves as the reader would.
let viewport = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => viewport });
// Wide enough for the minimap's pane-edge rail in these layout tests.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 1040 });
const offsets = new WeakMap<object, number>();
/// The rail's list clamps its offset as a browser does: rows are 10 px, the list as tall as the rail.
const listRoom = (node: HTMLElement) =>
  Math.max(
    0,
    // A spacer stands for the rows the list does not draw, as tall as its style says (tickWindow.ts).
    [...node.children].reduce(
      (sum, child) =>
        sum + (child.querySelector("[data-tick]") ? 10 : Number.parseFloat((child as HTMLElement).style.height) || 0),
      0,
    ) - Number.parseFloat(node.parentElement?.style.height ?? "0"),
  );
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: HTMLElement, value: number) {
    offsets.set(
      this,
      this.classList.contains("acpmux-minimap__list") ? Math.max(0, Math.min(listRoom(this), value)) : value,
    );
  },
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { TRANSCRIPT_FADE_BOTTOM, TRANSCRIPT_FADE_TOP } = await import("../src/agent-session/acpmux/threadMinimap/model");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
/// More prompts than the rail has room for (64 rows, 70% of the window, the transcript's height).
const TURNS = 90;
const turns = Array.from({ length: TURNS }, (_, index) => [
  row(`user-${index + 1}`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();

/// The 2.5rem fade the list draws at an edge with more rows past it (threadMinimap.css).
const FADE = 40;

test("the band shows whole while the reader scrolls down, and reaches the rail's end at the bottom", async () => {
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(turns, new Set())}
          sessionId="minimap-bottom"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const rail = () => document.querySelector<HTMLElement>(".acpmux-minimap__rail")!;
    const list = () => document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    // It opens at the latest message: that offset is the bottom of the chat.
    const bottom = scroller.scrollTop;
    expect(bottom).toBeGreaterThan(0);
    expect(rail()).not.toBeNull();
    const height = Number.parseFloat(rail().style.height);
    // The rail's rows scroll: there are more than it has room for.
    expect(TURNS * 10).toBeGreaterThan(height);
    /// Where each lit tick draws in the rail, checked to be inside it and clear of any fade.
    const check = (at: number) => {
      const node = list();
      const current = [...node.querySelectorAll<HTMLElement>('[data-tick][aria-current="true"]')].map((tick) =>
        Number(tick.dataset.tick),
      );
      expect(current.length).toBeGreaterThan(0);
      const top = node.hasAttribute("data-fade-top") ? FADE : 0;
      const end = height - (node.hasAttribute("data-fade-bottom") ? FADE : 0);
      for (const index of current) {
        const y = index * 10 - node.scrollTop;
        if (y < top || y + 10 > end)
          throw new Error(
            `at ${at} px the lit tick ${index} draws at ${y} px, outside ${top} to ${end} px of the rail`,
          );
      }
      return current;
    };
    const scrollTo = async (top: number) => {
      scroller.scrollTop = top;
      await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
    };
    // Up to the top, then down in wheel-sized steps to the bottom, as a reader goes back down a chat.
    await scrollTo(0);
    expect(check(0)[0]).toBe(0);
    for (let top = 0; top < bottom; top += 120) {
      await scrollTo(top);
      check(top);
    }
    // From two-thirds of the way down, straight back to the bottom.
    await scrollTo(Math.round(bottom * 0.66));
    check(Math.round(bottom * 0.66));
    await scrollTo(bottom);
    // At the bottom the last prompt is lit, the list is at its own end, and no fade is over it.
    expect(check(bottom).at(-1)).toBe(TURNS - 1);
    expect(list().scrollTop + height).toBe(TURNS * 10);
    expect(list().hasAttribute("data-fade-bottom")).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});

// With a tick under the pointer or keyboard focus, the rail used to stop following the band
// (#24058 review round 4): scrolling the chat from top to bottom while hovering left the lit band
// past the rail's end or under its edge fade until the pointer left. The band stays in view at every
// offset, whatever is hovered or focused; the rail holds still only while the band already shows.
for (const how of ["hover", "focus"] as const)
  test(`with a tick ${how === "hover" ? "hovered" : "focused"}, the band stays in the rail's clear area while the chat scrolls`, async () => {
    const document = dom.window.document;
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    try {
      await act(async () =>
        root.render(
          <VirtualTranscript
            rows={turnView(turns, new Set())}
            sessionId={`minimap-${how}-scroll`}
            onToggleActivity={() => {}}
            expanded={new Set()}
          />,
        ),
      );
      const scroller = host.querySelector<HTMLElement>(".acpmux-scroll")!;
      const list = () => host.querySelector<HTMLElement>(".acpmux-minimap__list")!;
      const rail = () => host.querySelector<HTMLElement>(".acpmux-minimap__rail")!;
      const bottom = scroller.scrollTop;
      const scrollTo = async (top: number) => {
        scroller.scrollTop = top;
        await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
      };
      await scrollTo(0);
      // A tick near the top of the rail, held while the chat scrolls down to its end.
      const tick = list().querySelector<HTMLElement>('[data-tick="3"]')!;
      if (how === "hover")
        await act(async () => {
          const Event =
            (dom.window as unknown as { PointerEvent?: typeof MouseEvent }).PointerEvent ?? dom.window.MouseEvent;
          tick.dispatchEvent(new Event("pointerover", { bubbles: true, relatedTarget: document.body }));
        });
      else await act(async () => tick.focus());
      expect(rail().hasAttribute("data-hovering") || document.activeElement === tick).toBe(true);
      const height = Number.parseFloat(rail().style.height);
      const outside: string[] = [];
      for (let top = 0; top <= bottom; top += 120) {
        await scrollTo(top);
        const node = list();
        const fade = Number.parseFloat(node.style.getPropertyValue("--acpmux-minimap-fade")) || FADE;
        const from = node.hasAttribute("data-fade-top") ? fade : 0;
        const to = height - (node.hasAttribute("data-fade-bottom") ? fade : 0);
        for (const lit of node.querySelectorAll<HTMLElement>('[data-tick][aria-current="true"]')) {
          const y = Number(lit.dataset.tick) * 10 - node.scrollTop;
          if (y < from || y + 10 > to)
            outside.push(`at ${top} px tick ${lit.dataset.tick} at ${y} px, outside ${from} to ${to}`);
        }
        if (outside.length > 5) break;
      }
      expect(outside).toEqual([]);
    } finally {
      await act(async () => root.unmount());
      host.remove();
    }
  });

// The rail's list moves under a pointer that stays still (the reader wheels the chat with the
// pointer on the rail): no pointerenter comes, so the magnified tick used to stay the one first
// hovered while another sat under the pointer (#24058 review round 5). The magnified tick is the
// one under the pointer at every offset.
/// Where the rail's list sits in the window, for the tests that point at it: jsdom lays nothing out,
/// so its box is put there by hand, below the window's top as the rail is (railTop).
const LIST_TOP = 140;
const placeList = (node: HTMLElement) => {
  node.getBoundingClientRect = () =>
    ({
      top: LIST_TOP,
      bottom: LIST_TOP + node.clientHeight,
      left: 0,
      right: 10,
      width: 10,
      height: node.clientHeight,
      x: 0,
      y: LIST_TOP,
    }) as DOMRect;
};

/// The chat rendered at its top with the pointer resting on tick 3 (35 px into the list), and the
/// ticks the rail magnifies against the one under that pointer.
async function pointerOnRail(sessionId: string) {
  const document = dom.window.document;
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <VirtualTranscript
        rows={turnView(turns, new Set())}
        sessionId={sessionId}
        onToggleActivity={() => {}}
        expanded={new Set()}
      />,
    ),
  );
  const scroller = host.querySelector<HTMLElement>(".acpmux-scroll")!;
  const list = () => host.querySelector<HTMLElement>(".acpmux-minimap__list")!;
  const bottom = scroller.scrollTop;
  const scrollTo = async (top: number) => {
    scroller.scrollTop = top;
    await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
  };
  await scrollTo(0);
  placeList(list());
  const y = LIST_TOP + 35;
  const Event = (dom.window as unknown as { PointerEvent?: typeof MouseEvent }).PointerEvent ?? dom.window.MouseEvent;
  await act(async () => {
    list()
      .querySelector<HTMLElement>('[data-tick="3"]')!
      .dispatchEvent(new Event("pointerover", { bubbles: true, clientY: y, relatedTarget: document.body }));
  });
  /// The magnified tick and the one under the pointer, as the list now sits.
  const read = () => ({
    active: list().querySelector('[data-tone="active"]')?.getAttribute("data-tick"),
    under: String(Math.floor((y - LIST_TOP + list().scrollTop) / 10)),
  });
  const close = async () => {
    await act(async () => root.unmount());
    host.remove();
  };
  return { list, bottom, scrollTo, read, close };
}

test("wheeling the chat with the pointer still on the rail magnifies the tick under the pointer", async () => {
  const rail = await pointerOnRail("minimap-hover-wheel");
  try {
    expect(rail.read().active).toBe("3");
    let moved = false;
    const wrong: string[] = [];
    for (let top = 0; top <= rail.bottom; top += 120) {
      await rail.scrollTo(top);
      if (rail.list().scrollTop > 0) moved = true;
      const { active, under } = rail.read();
      if (active !== under)
        wrong.push(
          `at ${top} px the list is at ${rail.list().scrollTop}: tick ${active} magnified, ${under} under the pointer`,
        );
      if (wrong.length > 5) break;
    }
    // The list did move under the pointer, and the magnified tick followed it.
    expect(moved).toBe(true);
    expect(wrong).toEqual([]);
  } finally {
    await rail.close();
  }
});

// End or an arrow key moves focus to a tick past the list's end, and the browser scrolls the
// overflow-hidden list to show it (a focus() without preventScroll). The pointer did not move: the
// magnified tick is the one under it, not the one it was on before the list moved (#24058 review
// round 6).
test("a key that focuses a tick off the list, with the pointer still on the rail, magnifies the tick under the pointer", async () => {
  const focus = dom.window.HTMLElement.prototype.focus;
  // As a browser does: a focus that may scroll brings the tick into its list's view.
  dom.window.HTMLElement.prototype.focus = function (this: HTMLElement, options?: FocusOptions) {
    focus.call(this, options);
    const list = this.closest<HTMLElement>(".acpmux-minimap__list");
    if (!list || options?.preventScroll) return;
    const room = Number.parseFloat(list.parentElement?.style.height ?? "0");
    const at = Number(this.dataset.tick) * 10;
    const top = at < list.scrollTop ? at : at + 10 > list.scrollTop + room ? at + 10 - room : list.scrollTop;
    if (top === list.scrollTop) return;
    list.scrollTop = top;
    list.dispatchEvent(new dom.window.Event("scroll"));
  };
  const rail = await pointerOnRail("minimap-hover-keys");
  try {
    expect(rail.read().active).toBe("3");
    const press = async (key: string) => {
      const target =
        dom.window.document.activeElement?.closest("[data-tick]") ?? rail.list().querySelector('[data-tick="3"]')!;
      await act(async () => void target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true })));
    };
    const seen: string[] = [];
    for (const key of ["End", "Home", "End", "ArrowUp"]) {
      await press(key);
      const { active, under } = rail.read();
      seen.push(`${key}: list at ${rail.list().scrollTop}, tick ${active} magnified, ${under} under the pointer`);
      expect(seen.at(-1)).toBe(
        `${key}: list at ${rail.list().scrollTop}, tick ${under} magnified, ${under} under the pointer`,
      );
    }
    // End did take the list down past its first screen.
    expect(seen[0]).not.toContain("list at 0,");
  } finally {
    dom.window.HTMLElement.prototype.focus = focus;
    await rail.close();
  }
});

/// The transcript mask's fades (conversation.css), in px: each edge's band, and the bottom's while
/// Jump to latest shows. The 0px rules (find open, Reduce Transparency, Increase Contrast) turn a
/// fade off and draw nothing, so they don't count.
function maskFades() {
  const css = readFileSync(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
    "utf8",
  ).replace(/\/\*[\s\S]*?\*\//g, "");
  const values = (name: string) =>
    [...css.matchAll(new RegExp(`${name}:\\s*(\\d+(?:\\.\\d+)?)px`, "g"))]
      .map((match) => Number(match[1]))
      .filter((px) => px > 0);
  const top = values("--acpmux-fade-top");
  const bottom = values("--acpmux-fade-bottom");
  return { top: Math.max(...top), bottom: Math.min(...bottom), jump: Math.max(...bottom) };
}

test("the rail keeps clear of the transcript's widest fades (the model reads the CSS's bands)", () => {
  const fades = maskFades();
  expect(fades.top).toBeGreaterThan(0);
  expect(fades.bottom).toBeGreaterThan(0);
  expect(TRANSCRIPT_FADE_TOP).toBeGreaterThanOrEqual(fades.top);
  expect(TRANSCRIPT_FADE_BOTTOM).toBe(fades.jump);
});

// The rail is inside the transcript, so the transcript's mask fades it too: 18 px under the top once
// scrolled from the start, and 18 px above the foot while more lies below, including with Jump to latest.
// In a short pane the rail filled the view less 8 px each end, so the first and last lit ticks drew
// in those fades at every offset short of the chat's two ends.
test("in a short pane every lit tick stays clear of the transcript's faded edges, at any offset", async () => {
  const document = dom.window.document;
  viewport = 320;
  // A short pane in a full window, as in the app: the rail's 70%-of-the-window cap is then taller
  // than the pane, so only the pane's own room holds the rail. (Bun's globalThis has no innerHeight,
  // so without this the rail took 70% of the pane and never reached the fades.)
  const scope = globalThis as { innerHeight?: number };
  const windowBefore = scope.innerHeight;
  scope.innerHeight = 900;
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(turns, new Set())}
          sessionId="minimap-short"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    const scroller = host.querySelector<HTMLElement>(".acpmux-scroll")!;
    const end = scroller.scrollTop;
    expect(end).toBeGreaterThan(0);
    const fades = maskFades();
    const clipped: string[] = [];
    const offsets = [...Array.from({ length: Math.floor(end / 37) + 1 }, (_, step) => step * 37), end - 1, end];
    for (const at of offsets) {
      scroller.scrollTop = at;
      await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
      const rail = host.querySelector<HTMLElement>(".acpmux-minimap__rail")!;
      const list = host.querySelector<HTMLElement>(".acpmux-minimap__list")!;
      // The mask's opaque band at this offset, from the scroller's own fade state.
      const from = scroller.hasAttribute("data-fade-top") ? fades.top : 0;
      const band = scroller.hasAttribute("data-jump-shown") ? fades.jump : fades.bottom;
      const to = viewport - (scroller.hasAttribute("data-fade-bottom") ? band : 0);
      const railTop = Number.parseFloat(rail.style.top);
      for (const tick of list.querySelectorAll<HTMLElement>('[data-tick][aria-current="true"]')) {
        const y = railTop + Number(tick.dataset.tick) * 10 - list.scrollTop;
        if (y < from || y + 10 > to)
          clipped.push(`at ${at} px tick ${tick.dataset.tick} draws at ${y} px, outside ${from} to ${to} px`);
      }
    }
    expect(clipped).toEqual([]);
  } finally {
    await act(async () => root.unmount());
    host.remove();
    viewport = 600;
    scope.innerHeight = windowBefore;
  }
});
