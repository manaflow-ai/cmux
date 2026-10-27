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
proto.getBoundingClientRect = function (this: HTMLElement) {
  return this === host
    ? { top: 0, left: 0, right: 400, bottom: 300, width: 400, height: 300 }
    : { top: 160, left: 16, right: 384, bottom: 220, width: 368, height: 60 };
};
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

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
