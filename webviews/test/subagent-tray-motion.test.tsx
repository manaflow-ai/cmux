// l10n-allow-file: test fixture subagent names, not shipped UI.
// The subagent tray moves with the transcript (Leo 2026-10-26: "Like why is this not animating and,
// like, following along with the exact same things as everything else?"; subagents/trayMotion.tsx):
// - it eases in only when it appears in a chat that showed without it;
// - it leaves on a kept copy, in place over the stack, only while its own chat still shows, and the
//   copy goes on its animationend (or its fallback timer), or at once when a card comes back;
// - its words tick: the old words stay in the cell until their exit ends, then go;
// - with no motion (no Web Animations, Reduce Motion) every change applies at once.
import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=host><div id=root></div></div>", {
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
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const proto = dom.window.HTMLElement.prototype as unknown as Record<string, unknown>;
const host = dom.window.document.getElementById("host")!;
Object.defineProperty(proto, "offsetParent", { configurable: true, get: () => host });
/// The card's drawn box; a test resizes it mid-motion.
let cardBox = { top: 160, left: 16, right: 384, bottom: 220, width: 368, height: 60 };
proto.getBoundingClientRect = function (this: HTMLElement) {
  return this === host ? { top: 0, left: 0, right: 400, bottom: 300, width: 400, height: 300 } : cardBox;
};
// Its laid-out box in the host (offsets, which no transform moves).
for (const [name, read] of [
  ["offsetTop", () => cardBox.top],
  ["offsetLeft", () => cardBox.left],
  ["offsetHeight", () => cardBox.height],
  ["offsetWidth", () => cardBox.width],
] as const)
  Object.defineProperty(proto, name, { configurable: true, get: read });
// The page's visibility, and the system's Reduce Motion with its change listeners.
let visibility = "visible";
Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
let reduce = false;
const reduceListeners = new Set<(event: { matches: boolean }) => void>();
(dom.window as unknown as { matchMedia: unknown }).matchMedia = (query: string) => ({
  get matches() {
    return query.includes("reduce") && reduce;
  },
  media: query,
  addEventListener: (_: string, listener: (event: { matches: boolean }) => void) => reduceListeners.add(listener),
  removeEventListener: (_: string, listener: (event: { matches: boolean }) => void) => reduceListeners.delete(listener),
});
const setReduce = (on: boolean) => {
  reduce = on;
  for (const listener of reduceListeners) listener({ matches: on });
};
const setVisibility = (state: string) => {
  visibility = state;
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
};
/// The page's reveal settles after its two frames back: wait for those frames to paint (each
/// requestAnimationFrame queued here runs after the reveal's own for that frame).
const frame = () => new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
const frames = async () => {
  for (let painted = 0; painted < 3; painted++) await frame();
};
const cancelled = (node: Element) => node.dispatchEvent(new dom.window.Event("animationcancel", { bubbles: true }));
Object.defineProperty(proto, "clientHeight", { configurable: true, get: () => 300 });
// A ghost's exit is an 80 ms animation; nothing else animates in this document.
const computed = dom.window.getComputedStyle.bind(dom.window);
dom.window.getComputedStyle = ((node: Element) =>
  node.classList.contains("acpmux-running-tray--ghost")
    ? ({ animationName: "acpmux-tray-leave", animationDuration: "0.08s" } as CSSStyleDeclaration)
    : computed(node)) as typeof dom.window.getComputedStyle;

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
const { SubagentTray } = await import("../src/agent-session/acpmux/subagents/SubagentTray");
const { Tick, TRAY_ENTER_ATTR, TRAY_GHOST } = await import("../src/agent-session/acpmux/subagents/trayMotion");
type TrayItem = import("../src/agent-session/acpmux/subagents/runningTray").TrayItem;
setPaneLanguage("en");

/// Turns Web Animations on (the tray checks `animate` before it moves anything) or off.
const motion = (on: boolean) => {
  if (on) proto.animate = () => ({});
  else delete proto.animate;
};

const item = (name: string): TrayItem => ({
  kind: "agent",
  id: name,
  agent: { id: name, parent: null, name, task: name, state: "running", startedAt: Date.now() },
  depth: 0,
});
const NONE = new Set<string>();
/// An animation's end, as WebKit sends it and as React may listen for it (jsdom's styles carry the
/// prefixed property, so React picks the prefixed event).
const ended = (node: Element) => {
  for (const name of ["animationend", "webkitAnimationEnd"])
    node.dispatchEvent(new dom.window.Event(name, { bubbles: true }));
};

function mount() {
  const element = dom.window.document.getElementById("root")!;
  const root = createRoot(element);
  return { element, root };
}

describe("subagent tray motion", () => {
  test("enters only when asked, and leaves on a kept copy while its chat shows", async () => {
    motion(true);
    const shown = { current: "chat-a" as string | undefined };
    const { root } = mount();
    const draw = (items: TrayItem[], enters: boolean) =>
      act(async () =>
        root.render(
          items.length
            ? createElement(SubagentTray, { items, working: true, waiting: NONE, onOpen: () => {}, shown, enters })
            : null,
        ),
      );
    await draw([item("Reviewer")], true);
    const card = host.querySelector<HTMLElement>(".acpmux-running-tray")!;
    expect(card.hasAttribute(TRAY_ENTER_ATTR)).toBe(true);
    // Its entrance ends: the mark goes.
    ended(card);
    expect(card.hasAttribute(TRAY_ENTER_ATTR)).toBe(false);
    // A change of placement keeps the card: no copy.
    await act(async () =>
      root.render(
        createElement(SubagentTray, {
          items: [item("Reviewer")],
          working: true,
          waiting: NONE,
          onOpen: () => {},
          shown,
          placement: "after-latest-message",
        }),
      ),
    );
    expect(host.querySelector(`.${TRAY_GHOST}`)).toBeNull();
    await draw([item("Reviewer")], false);
    expect(host.querySelector(`.${TRAY_GHOST}`)).toBeNull();
    // The last line goes: the real card is gone at once, a copy plays in its place.
    await draw([], false);
    const ghost = host.querySelector<HTMLElement>(`.${TRAY_GHOST}`)!;
    expect(ghost).not.toBeNull();
    expect(host.querySelectorAll(".acpmux-running-tray:not([aria-hidden])").length).toBe(0);
    expect(ghost.getAttribute("aria-hidden")).toBe("true");
    expect(ghost.hasAttribute("inert")).toBe(true);
    expect(ghost.style.position).toBe("absolute");
    expect(ghost.style.bottom).toBe("80px");
    // A card that comes back drops the copy at once.
    await draw([item("Writer")], false);
    expect(host.querySelector(`.${TRAY_GHOST}`)).toBeNull();
    expect(host.querySelector(".acpmux-running-tray")!.hasAttribute(TRAY_ENTER_ATTR)).toBe(false);
    // Another chat shows: the card goes with no copy.
    shown.current = "chat-b";
    await draw([], false);
    expect(host.querySelector(`.${TRAY_GHOST}`)).toBeNull();
    await act(async () => root.unmount());
  });

  test("a copy goes on its animationend", async () => {
    motion(true);
    const shown = { current: "chat-a" as string | undefined };
    const { root } = mount();
    await act(async () =>
      root.render(
        createElement(SubagentTray, { items: [item("A")], working: true, waiting: NONE, onOpen: () => {}, shown }),
      ),
    );
    await act(async () => root.render(null));
    const ghost = host.querySelector<HTMLElement>(`.${TRAY_GHOST}`)!;
    ended(ghost);
    expect(host.querySelector(`.${TRAY_GHOST}`)).toBeNull();
    await act(async () => root.unmount());
  });

  test("words tick: the old stay until their exit ends; with no motion they swap at once", async () => {
    motion(true);
    const { element, root } = mount();
    await act(async () => root.render(createElement(Tick, { text: "2 subagents running" })));
    await act(async () => root.render(createElement(Tick, { text: "3 subagents running" })));
    const out = element.querySelector<HTMLElement>(".acpmux-tick__out")!;
    expect(out.textContent).toBe("2 subagents running");
    expect(out.getAttribute("aria-hidden")).toBe("true");
    expect(element.querySelector(".acpmux-tick__in")!.textContent).toBe("3 subagents running");
    await act(async () => ended(out));
    expect(element.querySelector(".acpmux-tick__out")).toBeNull();
    expect(element.textContent).toBe("3 subagents running");
    // The shorter exit never cuts the entrance short: the new words keep rising until their own end.
    const rising = element.querySelector<HTMLElement>(".acpmux-tick__in")!;
    expect(rising).not.toBeNull();
    await act(async () => ended(rising));
    expect(element.querySelector(".acpmux-tick__in")).toBeNull();
    motion(false);
    await act(async () => root.render(createElement(Tick, { text: "4 subagents running" })));
    expect(element.querySelector(".acpmux-tick__out")).toBeNull();
    expect(element.textContent).toBe("4 subagents running");
    await act(async () => root.unmount());
  });

  test("with no motion the tray neither marks an entrance nor leaves a copy", async () => {
    motion(false);
    const shown = { current: "chat-a" as string | undefined };
    const { root } = mount();
    await act(async () =>
      root.render(
        createElement(SubagentTray, {
          items: [item("A")],
          working: true,
          waiting: NONE,
          onOpen: () => {},
          shown,
          enters: true,
        }),
      ),
    );
    expect(host.querySelector(".acpmux-running-tray")!.hasAttribute(TRAY_ENTER_ATTR)).toBe(false);
    await act(async () => root.render(null));
    expect(host.querySelector(`.${TRAY_GHOST}`)).toBeNull();
    await act(async () => root.unmount());
  });
});

describe("subagent tray motion edges", () => {
  const draw = (
    root: ReturnType<typeof createRoot>,
    shown: { current: string | undefined },
    items: TrayItem[],
    enters: boolean,
  ) =>
    act(async () =>
      root.render(
        items.length
          ? createElement(SubagentTray, { items, working: true, waiting: NONE, onOpen: () => {}, shown, enters })
          : null,
      ),
    );
  const card = () => host.querySelector<HTMLElement>(`.acpmux-running-tray:not(.${TRAY_GHOST})`);
  const ghosts = () => host.querySelectorAll(`.${TRAY_GHOST}`).length;

  test("a hidden page, and its first frames back, start no entrance and leave no copy", async () => {
    motion(true);
    const shown = { current: "chat-a" as string | undefined };
    const { root } = mount();
    setVisibility("hidden");
    await draw(root, shown, [item("A")], true);
    expect(card()!.hasAttribute(TRAY_ENTER_ATTR)).toBe(false);
    await draw(root, shown, [], false);
    expect(ghosts()).toBe(0);
    // Back: during the reveal's first frames nothing enters; after them it does.
    setVisibility("visible");
    await draw(root, shown, [item("A")], true);
    expect(card()!.hasAttribute(TRAY_ENTER_ATTR)).toBe(false);
    await draw(root, shown, [], false);
    expect(ghosts()).toBe(0);
    await frames();
    await draw(root, shown, [item("A")], true);
    expect(card()!.hasAttribute(TRAY_ENTER_ATTR)).toBe(true);
    await act(async () => root.unmount());
    for (const ghost of host.querySelectorAll(`.${TRAY_GHOST}`)) ended(ghost);
  });

  test("the same lines remounting in another chat show in place; coming back in the same chat re-enters and drops the copy", async () => {
    motion(true);
    const shown = { current: "chat-a" as string | undefined };
    const { root } = mount();
    await draw(root, shown, [item("A")], false);
    // Another chat shows with the same lines: the card goes with no copy, comes back with no entrance.
    shown.current = "chat-b";
    await draw(root, shown, [], false);
    expect(ghosts()).toBe(0);
    await draw(root, shown, [item("A")], false);
    expect(card()!.hasAttribute(TRAY_ENTER_ATTR)).toBe(false);
    // It leaves, then the same line comes back while the copy plays: one card, no copy, an entrance.
    await draw(root, shown, [], false);
    expect(ghosts()).toBe(1);
    await draw(root, shown, [item("A")], true);
    expect(ghosts()).toBe(0);
    expect(host.querySelectorAll(".acpmux-running-tray").length).toBe(1);
    expect(card()!.hasAttribute(TRAY_ENTER_ATTR)).toBe(true);
    await act(async () => root.unmount());
    for (const ghost of host.querySelectorAll(`.${TRAY_GHOST}`)) ended(ghost);
  });

  test("a resize mid-entrance keeps one entrance; a resize mid-exit keeps the copy where it left", async () => {
    motion(true);
    const shown = { current: "chat-a" as string | undefined };
    const { root } = mount();
    await draw(root, shown, [item("A")], true);
    const first = card()!;
    cardBox = { ...cardBox, top: 132, height: 88 };
    await draw(root, shown, [item("A"), item("B")], false);
    expect(card()).toBe(first);
    expect(first.hasAttribute(TRAY_ENTER_ATTR)).toBe(true);
    await draw(root, shown, [], false);
    const ghost = host.querySelector<HTMLElement>(`.${TRAY_GHOST}`)!;
    expect(ghost.style.height).toBe("88px");
    cardBox = { ...cardBox, top: 160, height: 60 };
    expect(ghost.style.height).toBe("88px");
    expect(ghost.style.bottom).toBe("80px");
    ended(ghost);
    expect(ghosts()).toBe(0);
    await act(async () => root.unmount());
  });

  test("the copy keeps the card's scroll offsets", async () => {
    motion(true);
    const shown = { current: "chat-a" as string | undefined };
    const { root } = mount();
    await draw(root, shown, [item("A"), item("B")], false);
    const list = card()!.querySelector<HTMLElement>(".acpmux-running-tray__list")!;
    list.scrollTop = 40;
    await draw(root, shown, [], false);
    const ghost = host.querySelector<HTMLElement>(`.${TRAY_GHOST}`)!;
    expect(ghost.querySelector<HTMLElement>(".acpmux-running-tray__list")!.scrollTop).toBe(40);
    ended(ghost);
    await act(async () => root.unmount());
  });

  test("a tray leaving mid-fold keeps the fold's drawn height and fade on its copy", async () => {
    motion(true);
    const shown = { current: "chat-a" as string | undefined };
    const { root } = mount();
    await draw(root, shown, [item("A"), item("B")], false);
    const fold = card()!.querySelector<HTMLElement>(".acpmux-running-tray__fold")!;
    // Midway through a collapse: useFold clips the fold, and its drawn box is 37px at 40% opacity.
    fold.style.overflow = "hidden";
    fold.style.opacity = "0.4";
    Object.defineProperty(fold, "offsetHeight", { configurable: true, get: () => 37 });
    await draw(root, shown, [], false);
    const copy = host.querySelector<HTMLElement>(`.${TRAY_GHOST} .acpmux-running-tray__fold`)!;
    expect(copy.style.height).toBe("37px");
    expect(copy.style.overflow).toBe("hidden");
    expect(copy.style.opacity).toBe("0.4");
    ended(host.querySelector(`.${TRAY_GHOST}`)!);
    await act(async () => root.unmount());
  });

  test("animationcancel settles the entrance, the copy and a tick, with their listeners", async () => {
    motion(true);
    const shown = { current: "chat-a" as string | undefined };
    const { root } = mount();
    await draw(root, shown, [item("A")], true);
    const tray = card()!;
    cancelled(tray);
    expect(tray.hasAttribute(TRAY_ENTER_ATTR)).toBe(false);
    await draw(root, shown, [], false);
    const ghost = host.querySelector<HTMLElement>(`.${TRAY_GHOST}`)!;
    cancelled(ghost);
    expect(ghosts()).toBe(0);
    await act(async () => root.unmount());
    const tick = mount();
    await act(async () => tick.root.render(createElement(Tick, { text: "one" })));
    await act(async () => tick.root.render(createElement(Tick, { text: "two" })));
    await act(async () => void cancelled(tick.element.querySelector(".acpmux-tick__out")!));
    await act(async () => void cancelled(tick.element.querySelector(".acpmux-tick__in")!));
    expect(tick.element.querySelector(".acpmux-tick__out, .acpmux-tick__in")).toBeNull();
    expect(tick.element.textContent).toBe("two");
    await act(async () => tick.root.unmount());
  });

  test("Reduce Motion turning on settles a running entrance and copy; its listener goes with the card", async () => {
    motion(true);
    const shown = { current: "chat-a" as string | undefined };
    const { root } = mount();
    await draw(root, shown, [item("A")], true);
    expect(reduceListeners.size).toBe(1);
    setReduce(true);
    expect(card()!.hasAttribute(TRAY_ENTER_ATTR)).toBe(false);
    setReduce(false);
    await draw(root, shown, [], false);
    expect(reduceListeners.size).toBe(0);
    expect(ghosts()).toBe(1);
    // A card coming back drops the copy at once.
    await draw(root, shown, [item("B")], false);
    expect(ghosts()).toBe(0);
    await act(async () => root.unmount());
    expect(reduceListeners.size).toBe(0);
  });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
