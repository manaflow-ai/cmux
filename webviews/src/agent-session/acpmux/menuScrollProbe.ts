// `debug.agent_pane {action: "menu_scroll"}` (DEBUG automation): scrolls the open composer menu's list
// from inside the page and reports what else changed while it did. Leo, 2026-11-06, of the folder
// menu: "when i scroll through this it flickers and the composer flickers". A capture slot's window
// is never active, so the App's synthetic wheel never moved that list (cmuxterm-hq#7353); this
// scrolls it as a wheel does (the viewport's scrollTop, one step a frame) and, with `hover`, sends the
// pointer events the row that comes under a resting pointer gets, so the menu's highlight follows.
//
// Every frame it reads: the popup's box and its glass attributes, the composer's box, and every
// mutation outside the popup (an attribute, a node, a text) with its element. A menu that scrolls
// cleanly changes nothing outside the popup and moves no box.

export type MenuScrollOptions = {
  /** How long to scroll, ms (default 1500). */
  ms?: number;
  /** CSS px a frame (default 12); the direction flips at each end. */
  step?: number;
  /** Send pointer events to the row under the list's middle each frame (default true). */
  hover?: boolean;
  /** Return at once and keep scrolling, so a frame recorder can run meanwhile; `result` reads it. */
  detach?: boolean;
  /** The detached run's report (waits for it to end). */
  result?: boolean;
};

let detached: Promise<Record<string, unknown>> | undefined;

type Watch = {
  frames: number[];
  popupBoxes: Set<string>;
  composerBoxes: Set<string>;
  popupAttributes: Map<string, number>;
  outside: Map<string, number>;
};

const COMPOSER = ".acpmux-dock";
const GLASS_ATTRIBUTES = [
  "class",
  "data-host-glass-drawn",
  "data-glass-over",
  "data-glass-keeps-underlay",
  "style",
  "data-highlight",
];

function describe(node: Node): string {
  const element = node instanceof Element ? node : node.parentElement;
  if (!element) return "#document";
  const classes = [...element.classList].slice(0, 3).join(".");
  return `${element.tagName.toLowerCase()}${classes ? "." + classes : ""}`;
}

function box(element: Element | null): string {
  if (!element) return "none";
  const rect = element.getBoundingClientRect();
  return [rect.x, rect.y, rect.width, rect.height].map((value) => Math.round(value * 2) / 2).join(",");
}

export async function menuScroll(options: MenuScrollOptions = {}): Promise<Record<string, unknown>> {
  if (options.result) return (await detached) ?? { error: "no detached run" };
  if (options.detach) {
    detached = run(options);
    return { detached: true };
  }
  return run(options);
}

async function run(options: MenuScrollOptions): Promise<Record<string, unknown>> {
  const ms = Math.max(100, Math.min(10_000, Number(options.ms ?? 1500)));
  const step = Math.max(1, Number(options.step ?? 12));
  const hover = options.hover !== false;
  const viewport = [...document.querySelectorAll<HTMLElement>(".ui-popup .ui-combobox-viewport")].at(-1);
  if (!viewport) return { error: "no open menu with a scrolling list" };
  const popup = viewport.closest<HTMLElement>(".ui-popup")!;
  const composer = document.querySelector(COMPOSER);
  const watch: Watch = {
    frames: [],
    popupBoxes: new Set(),
    composerBoxes: new Set(),
    popupAttributes: new Map(),
    outside: new Map(),
  };
  const count = (map: Map<string, number>, key: string) => map.set(key, (map.get(key) ?? 0) + 1);
  const popupObserver = new MutationObserver((records) => {
    for (const record of records) count(watch.popupAttributes, record.attributeName ?? "?");
  });
  popupObserver.observe(popup, { attributes: true, attributeFilter: GLASS_ATTRIBUTES });
  if (popup.parentElement)
    popupObserver.observe(popup.parentElement, { attributes: true, attributeFilter: ["style"] });
  const outsideObserver = new MutationObserver((records) => {
    for (const record of records) {
      if (popup.contains(record.target)) continue;
      count(watch.outside, `${record.type}${record.attributeName ? ":" + record.attributeName : ""} ${describe(record.target)}`);
    }
  });
  outsideObserver.observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    characterData: true,
  });
  const list = viewport.getBoundingClientRect();
  const point = { clientX: list.left + list.width / 2, clientY: list.top + list.height / 2 };
  let under: Element | null = null;
  const pointAt = () => {
    const next = document.elementFromPoint(point.clientX, point.clientY);
    const init = { bubbles: true, cancelable: true, composed: true, pointerType: "mouse", ...point };
    if (next !== under) {
      under?.dispatchEvent(new PointerEvent("pointerout", { ...init, relatedTarget: next }));
      under?.dispatchEvent(new PointerEvent("pointerleave", { ...init, bubbles: false }));
      next?.dispatchEvent(new PointerEvent("pointerover", { ...init, relatedTarget: under }));
      next?.dispatchEvent(new PointerEvent("pointerenter", { ...init, bubbles: false }));
      under = next;
    }
    next?.dispatchEvent(new PointerEvent("pointermove", init));
    next?.dispatchEvent(new MouseEvent("mousemove", init));
  };
  if (hover) pointAt();
  let direction = 1;
  let scrolled = 0;
  const start = performance.now();
  let last = start;
  await new Promise<void>((resolve) => {
    const frame = (now: number) => {
      watch.frames.push(now - last);
      last = now;
      watch.popupBoxes.add(box(popup));
      watch.composerBoxes.add(box(composer));
      if (now - start >= ms) {
        resolve();
        return;
      }
      const max = viewport.scrollHeight - viewport.clientHeight;
      if (viewport.scrollTop >= max - 0.5) direction = -1;
      else if (viewport.scrollTop <= 0.5) direction = 1;
      viewport.scrollTop += direction * step;
      scrolled += step;
      if (hover) pointAt();
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  });
  // The last frame's mutations land before the observers stop.
  await new Promise((resolve) => setTimeout(resolve, 50));
  popupObserver.disconnect();
  outsideObserver.disconnect();
  const sorted = [...watch.frames.slice(1)].sort((a, b) => a - b);
  const pick = (q: number) => Math.round((sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] ?? 0) * 10) / 10;
  return {
    ms,
    scrolled,
    overflow: viewport.scrollHeight - viewport.clientHeight,
    frames: watch.frames.length,
    frame_p50: pick(0.5),
    frame_p95: pick(0.95),
    frame_max: pick(1),
    popup_boxes: [...watch.popupBoxes],
    composer_boxes: [...watch.composerBoxes],
    popup_attributes: Object.fromEntries(watch.popupAttributes),
    outside: Object.fromEntries([...watch.outside].sort((a, b) => b[1] - a[1]).slice(0, 30)),
  };
}
