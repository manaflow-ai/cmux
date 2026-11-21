// Switch away and back (plans/cmux-next/shared-projections.md): a tab's page stays alive and
// hidden while another tab or workspace shows, so a switch is `visibilityState` going hidden and
// then visible. A view passes when a switch away and back makes 0 fetches and starts 0 entrance
// animations, including when its data changed while it was hidden.
//
//   const page = pageSwitch(window);
//   const load = page.fetch("chats.page", realLoad);       // count a data read
//   ...render the view...
//   const seen = await page.switchAwayAndBack({ away: () => render(changed) });
//   expect(seen).toEqual({ fetches: [], entrances: [] });
//
// Entrances are Web Animations (`element.animate`) and elements that gain an entrance class
// (`ENTRANCE_SELECTOR`) between leaving and the first frame back.
import { act } from "react";
import type { DOMWindow } from "jsdom";

/// The CSS classes and attributes that start an entrance animation when an element gets them.
export const ENTRANCE_SELECTOR =
  ".cv-enter, .acpmux-row--enter, .acpmux-row--message-enter, .cv-fresh, .cv-code-handoff.is-fading, [data-kind-switch]";

export type SwitchSeen = { fetches: string[]; entrances: string[] };

type StubAnimation = Animation & { label: string };

export type PageSwitch = {
  /// Wraps a data read so each call counts as a fetch named `name`.
  fetch<Args extends unknown[], Result>(name: string, read: (...args: Args) => Result): (...args: Args) => Result;
  /// Counts a fetch the test observes another way (a socket request, a host call).
  noteFetch(name: string): void;
  /// The page hides, `away` runs (data changing while hidden), the page shows, `back` runs
  /// (catch-up landing as it shows), then its first frame back passes. Returns what that started.
  switchAwayAndBack(steps?: {
    away?: () => unknown | Promise<unknown>;
    back?: () => unknown | Promise<unknown>;
  }): Promise<SwitchSeen>;
  /// Sets the page's visibility and tells it (`visibilitychange`).
  setVisibility(next: DocumentVisibilityState): Promise<void>;
  /// Entrances started since the last switch or `reset` (also while the page shows).
  entrances(): string[];
  fetches(): string[];
  reset(): void;
  /// Restores `Element.prototype.animate` and stops observing.
  dispose(): void;
};

function label(element: Element): string {
  const text = element.textContent?.trim().replace(/\s+/g, " ").slice(0, 60);
  return text || element.className || element.tagName.toLowerCase();
}

/// Installs the switch harness on a jsdom `window`: a settable `visibilityState`, a recording
/// `Element.prototype.animate` and an observer for entrance classes.
export function pageSwitch(window: DOMWindow): PageSwitch {
  const doc = window.document;
  let visibility: DocumentVisibilityState = "visible";
  Object.defineProperty(doc, "visibilityState", { configurable: true, get: () => visibility });
  Object.defineProperty(doc, "hidden", { configurable: true, get: () => visibility === "hidden" });

  const fetched: string[] = [];
  const entered: string[] = [];
  const running = new Set<StubAnimation>();

  const proto = window.Element.prototype as unknown as { animate?: Element["animate"] };
  const hadAnimate = Object.prototype.hasOwnProperty.call(proto, "animate");
  const previousAnimate = proto.animate;
  proto.animate = function animate(this: Element, keyframes: Keyframe[] | PropertyIndexedKeyframes | null) {
    const kinds = Array.isArray(keyframes) ? Object.keys(keyframes[0] ?? {}).join(",") : "";
    const name = `${label(this)}${kinds ? ` (${kinds})` : ""}`;
    entered.push(name);
    let settle: (value: unknown) => void = () => {};
    const finished = new Promise((resolve) => (settle = resolve));
    const animation = {
      label: name,
      id: "",
      currentTime: 0,
      finished,
      playState: "running" as AnimationPlayState,
      onfinish: null as null | ((event?: unknown) => void),
      oncancel: null as null | ((event?: unknown) => void),
      effect: { getComputedTiming: () => ({ endTime: 1 }) },
      cancel() {
        if (!running.delete(animation as unknown as StubAnimation)) return;
        animation.playState = "idle";
        animation.oncancel?.();
      },
      finish() {
        if (!running.delete(animation as unknown as StubAnimation)) return;
        animation.playState = "finished";
        animation.onfinish?.();
        settle(animation);
      },
    };
    running.add(animation as unknown as StubAnimation);
    return animation as unknown as Animation;
  } as Element["animate"];
  // The page's finite animations, for pageReveal.ts `finishPageAnimations`.
  const docWithAnimations = doc as unknown as { getAnimations?: () => Animation[] };
  const hadGetAnimations = Object.prototype.hasOwnProperty.call(doc, "getAnimations");
  docWithAnimations.getAnimations = () => [...running];

  const matches = (node: Node): Element[] => {
    if (node.nodeType !== 1) return [];
    const element = node as Element;
    const found = element.matches(ENTRANCE_SELECTOR) ? [element] : [];
    return [...found, ...element.querySelectorAll(ENTRANCE_SELECTOR)];
  };
  const observer = new window.MutationObserver((records) => {
    for (const record of records) {
      if (record.type === "childList")
        for (const node of record.addedNodes) for (const element of matches(node)) entered.push(label(element));
      else if (record.type === "attributes" && record.target.nodeType === 1) {
        const element = record.target as Element;
        const before = record.oldValue ?? "";
        // Counted when the changed attribute is what starts it: a class gaining an entrance class,
        // or a `data-kind-switch` set where there was none.
        const gained =
          record.attributeName === "class"
            ? element.matches(ENTRANCE_SELECTOR) &&
              /(^|\s)(cv-enter|acpmux-row--enter|acpmux-row--message-enter|cv-fresh|is-fading)(\s|$)/.test(
                element.className,
              ) &&
              !/(^|\s)(cv-enter|acpmux-row--enter|acpmux-row--message-enter|cv-fresh|is-fading)(\s|$)/.test(before)
            : element.hasAttribute("data-kind-switch") && record.oldValue === null;
        if (gained) entered.push(label(element));
      }
    }
  });
  observer.observe(doc, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeOldValue: true,
    attributeFilter: ["class", "data-kind-switch"],
  });

  const frame = () =>
    new Promise<void>((resolve) => {
      const raf = window.requestAnimationFrame?.bind(window) ?? globalThis.requestAnimationFrame;
      if (typeof raf === "function") raf(() => resolve());
      else setTimeout(resolve, 16); // fixed-wait: no requestAnimationFrame here, so one 60 Hz frame's time stands in
    });

  const setVisibility = async (next: DocumentVisibilityState) => {
    visibility = next;
    await act(async () => {
      doc.dispatchEvent(new window.Event("visibilitychange"));
    });
  };

  const api: PageSwitch = {
    fetch(name, read) {
      return (...args) => {
        fetched.push(name);
        return read(...args);
      };
    },
    noteFetch(name) {
      fetched.push(name);
    },
    async switchAwayAndBack(steps = {}) {
      api.reset();
      await setVisibility("hidden");
      if (steps.away) await act(async () => void (await steps.away!()));
      await setVisibility("visible");
      if (steps.back) await act(async () => void (await steps.back!()));
      // The first frame back, and the one after it.
      await act(async () => {
        await frame();
        await frame();
        await new Promise((resolve) => setTimeout(resolve, 0));
      });
      return { fetches: [...fetched], entrances: [...entered] };
    },
    setVisibility,
    entrances: () => [...entered],
    fetches: () => [...fetched],
    reset() {
      observer.takeRecords();
      fetched.length = 0;
      entered.length = 0;
    },
    dispose() {
      observer.disconnect();
      if (hadAnimate) proto.animate = previousAnimate;
      else delete proto.animate;
      if (!hadGetAnimations) delete docWithAnimations.getAnimations;
      visibility = "visible";
      delete (doc as unknown as Record<string, unknown>).visibilityState;
      delete (doc as unknown as Record<string, unknown>).hidden;
    },
  };
  return api;
}
