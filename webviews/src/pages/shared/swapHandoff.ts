// GRACEFUL-SWAP: a web bundle swap that looks like nothing happened (Leo, 2026-11-22: "no shift, no
// anything, just... ok now it changed"). When the web a page runs changes (a customize layer, a web-dev
// overlay, a web update), the host keeps the page's last frame on screen as a still under it
// (PageWebView+GracefulSwap.swift), asks the page to hand its state over (`window.cmuxWebSwap.prepare()`),
// and reloads it. The new document:
//
// - starts invisible (`html[data-cmux-swap-restoring]`, opacity 0) while the hand-off is fresh, so the
//   host's still shows through it instead of an empty shell, a skeleton or a half-drawn page;
// - waits until it is the page it was: nothing `aria-busy`, the focused field holds its text again,
//   the kept landmarks (the composer, the focus owner) have the size and place they had, each scroller
//   it left can reach its place, every registered hold (`holdSwapReveal`) is ready, and the DOM was
//   quiet for a moment, or `REVEAL_CAP_MS` passed;
// - puts back what the page itself does not keep: every scroller's place, unkept fields' text, the
//   focus with its caret or selection, and what components registered (`keepAcrossSwap`);
// - shows itself in one frame and answers the host's `restored()`, which then drops the still.
//
// The probe (`cmux-swap-probe` on window, `window.__cmuxSwapProbe`, the agent page's flicker log
// `swap` records) says what came back, for scripts/measure/graceful-swap.py.

import { focusRoute } from "../../ui/focusRoute";
import { elementPath } from "./pageHealth";

/** sessionStorage (it survives a reload): the state a page handed over before the host reloaded it. */
export const SWAP_HANDOFF_KEY = "cmux.webSwap.handoff";
/** On <html> while a swapped-in document restores itself: it draws nothing over the host's still. */
export const SWAP_RESTORING_ATTRIBUTE = "data-cmux-swap-restoring";
/** On window right before the hand-off is written: a page's own last-moment saves run then. */
export const SWAP_PREPARE_EVENT = "cmux-web-swap-prepare";
/** A hand-off older than this is from a swap that did not happen: ignored. */
export const SWAP_HANDOFF_FRESH_MS = 10_000;
/** The longest a swapped-in document stays invisible: it shows as it is then. */
export const REVEAL_CAP_MS = 1500;
/** How long the DOM must be still before the document shows (a late chip, row or measure). */
const QUIET_MS = 90;
/** How often the restore looks again (also while hidden, where no animation frame runs). */
const POLL_MS = 16;
/** Attributes whose elements' boxes a swap keeps: the composer, the focus owners. */
const LANDMARKS = "[data-cmux-swap-kept], [data-cmux-swap-focus]";

interface Spot {
  path: string;
  top: number;
  left: number;
}

interface Caret {
  path: string;
  /** Text field: its selection; editable root: text offsets of the selection inside it. */
  start: number;
  end: number;
  backward: boolean;
  text: string;
}

interface Box {
  path: string;
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface SwapHandoff {
  at: number;
  href: string;
  /** The focused element (null: the body had it). */
  focus: string | null;
  caret: Caret | null;
  scroll: Spot[];
  fields: { path: string; value: string }[];
  boxes: Box[];
  extras: Record<string, unknown>;
}

export interface SwapProbe {
  kind: "swap";
  page: string;
  at: number;
  /** From the host's prepare to the restored first frame. */
  restored_ms: number;
  /** The reveal waited out its cap (what still held it: `held`). */
  capped: boolean;
  held: string;
  kept_text: boolean;
  kept_selection: boolean;
  kept_focus: boolean;
  kept_scroll: boolean;
  kept_fields: boolean;
  kept_boxes: boolean;
  /** Layout-shift sum from the reveal for 500 ms (Chromium; null where the engine has no such entries). */
  layout_shift: number | null;
  kept: boolean;
}

type Keeper = { save: () => unknown; restore: (value: unknown) => void };
const keepers = new Map<string, Keeper>();
const revealHolds = new Set<() => string | null>();

/** Keeps a component's state across a swap: `save` at the hand-off, `restore` right before the page shows. */
export function keepAcrossSwap(key: string, save: () => unknown, restore: (value: unknown) => void): () => void {
  keepers.set(key, { save, restore });
  return () => void keepers.delete(key);
}

/** Keeps a swapped-in page invisible while `hold` answers why (a read that brings its rows or chips back). */
export function holdSwapReveal(hold: () => string | null): () => void {
  revealHolds.add(hold);
  return () => void revealHolds.delete(hold);
}

let restored: Promise<SwapProbe | null> = Promise.resolve(null);

/** The host's wait: the probe once a swapped-in document showed restored (null when it was no swap). */
export function swapRestored(): Promise<SwapProbe | null> {
  return restored;
}

const isTextField = (element: Element | null): element is HTMLInputElement | HTMLTextAreaElement =>
  !!element &&
  (element.localName === "textarea" ||
    (element.localName === "input" &&
      /^(text|search|url|tel|email|password|number|)$/.test((element as HTMLInputElement).type ?? "")));

/** Input types whose selection the DOM exposes (email and number throw on setSelectionRange). */
const hasSelection = (element: HTMLInputElement | HTMLTextAreaElement): boolean =>
  element.localName === "textarea" || /^(text|search|url|tel|password|)$/.test(element.type ?? "");

function editableRoot(element: Element | null): HTMLElement | null {
  let node = element as HTMLElement | null;
  let root: HTMLElement | null = null;
  while (node && node.isContentEditable) {
    root = node;
    node = node.parentElement;
  }
  return root;
}

/** The text offset of (node, offset) inside `root`. */
function textOffset(root: Node, node: Node, offset: number): number {
  const range = root.ownerDocument!.createRange();
  range.setStart(root, 0);
  try {
    range.setEnd(node, offset);
  } catch {
    return 0;
  }
  return range.toString().length;
}

/** The (text node, offset) at text offset `at` inside `root`. */
function textPoint(root: Node, at: number): [Node, number] {
  const walker = root.ownerDocument!.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let left = at;
  let last: Node | null = null;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const length = node.textContent?.length ?? 0;
    if (left <= length) return [node, left];
    left -= length;
    last = node;
  }
  return last ? [last, last.textContent?.length ?? 0] : [root, root.childNodes.length];
}

function captureCaret(doc: Document): Caret | null {
  const active = doc.activeElement;
  if (isTextField(active)) {
    // A password's value never leaves the page, and email/number have no caret to carry.
    if (active.type === "password" || !hasSelection(active)) return null;
    const path = elementPath(active);
    if (!path) return null;
    return {
      path,
      start: active.selectionStart ?? active.value.length,
      end: active.selectionEnd ?? active.value.length,
      backward: active.selectionDirection === "backward",
      text: active.value,
    };
  }
  const root = editableRoot(active);
  const selection = doc.getSelection();
  if (!root || !selection || !selection.anchorNode || !root.contains(selection.anchorNode)) return null;
  const path = elementPath(root);
  if (!path) return null;
  const anchor = textOffset(root, selection.anchorNode, selection.anchorOffset);
  const focus = selection.focusNode ? textOffset(root, selection.focusNode, selection.focusOffset) : anchor;
  return {
    path,
    start: Math.min(anchor, focus),
    end: Math.max(anchor, focus),
    backward: focus < anchor,
    text: root.textContent ?? "",
  };
}

function find(doc: Document, path: string): HTMLElement | null {
  try {
    return doc.querySelector<HTMLElement>(path);
  } catch {
    return null;
  }
}

function box(element: Element): Omit<Box, "path"> {
  const rect = element.getBoundingClientRect();
  return { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) };
}

/** What the page shows that a reload would lose or move, at the hand-off. */
export function captureHandoff(doc: Document = document): SwapHandoff {
  const view = doc.defaultView!;
  const scroll: Spot[] = [];
  for (const element of doc.querySelectorAll<HTMLElement>("*")) {
    if (element.scrollTop > 0 || element.scrollLeft > 0) {
      const path = elementPath(element);
      if (path) scroll.push({ path, top: element.scrollTop, left: element.scrollLeft });
    }
  }
  const fields: SwapHandoff["fields"] = [];
  for (const field of doc.querySelectorAll<HTMLInputElement | HTMLTextAreaElement>("input, textarea")) {
    if (!isTextField(field) || field.closest("[data-cmux-swap-kept]") || field.type === "password") continue;
    if (field.value === field.defaultValue) continue;
    const path = elementPath(field);
    if (path) fields.push({ path, value: field.value });
  }
  const boxes: Box[] = [];
  for (const element of doc.querySelectorAll(LANDMARKS)) {
    const path = elementPath(element);
    if (path) boxes.push({ path, ...box(element) });
  }
  const extras: Record<string, unknown> = {};
  for (const [key, keeper] of keepers) {
    try {
      extras[key] = keeper.save();
    } catch {
      // A component that cannot say keeps only what the page keeps itself.
    }
  }
  const active = doc.activeElement;
  return {
    at: Date.now(),
    href: view.location.href,
    focus: active && active !== doc.body && active !== doc.documentElement ? elementPath(active) : null,
    caret: captureCaret(doc),
    scroll,
    fields,
    boxes,
    extras,
  };
}

/** The host is about to reload the page into new web: hands its state over. True when it was kept. */
export function prepareSwap(doc: Document = document): boolean {
  // Pages that keep a drawn copy of themselves (the agent chat, chatSnapshot/live.ts) write it now.
  doc.defaultView?.dispatchEvent(new doc.defaultView.Event(SWAP_PREPARE_EVENT));
  try {
    doc.defaultView!.sessionStorage.setItem(SWAP_HANDOFF_KEY, JSON.stringify(captureHandoff(doc)));
    return true;
  } catch {
    return false;
  }
}

function takeHandoff(view: Window, now: number): SwapHandoff | null {
  try {
    const text = view.sessionStorage.getItem(SWAP_HANDOFF_KEY);
    if (!text) return null;
    view.sessionStorage.removeItem(SWAP_HANDOFF_KEY);
    const handoff = JSON.parse(text) as SwapHandoff;
    if (now - handoff.at > SWAP_HANDOFF_FRESH_MS || handoff.href !== view.location.href) return null;
    return handoff;
  } catch {
    return null;
  }
}

const near = (a: number, b: number) => Math.abs(a - b) <= 1;

function caretBack(doc: Document, caret: Caret): boolean {
  const element = find(doc, caret.path);
  if (!element) return false;
  if (isTextField(element)) {
    return element.value === caret.text && element.selectionStart === caret.start && element.selectionEnd === caret.end;
  }
  const now = captureCaret(doc);
  return !!now && now.path === caret.path && now.start === caret.start && now.end === caret.end;
}

function textOf(element: HTMLElement): string {
  return isTextField(element) ? element.value : (element.textContent ?? "");
}

/** Why the swapped-in document is not yet the page it was, or null when it is. */
function notBack(doc: Document, handoff: SwapHandoff): string | null {
  if (doc.querySelector('[aria-busy="true"]')) return "busy";
  for (const hold of revealHolds) {
    const reason = hold();
    if (reason) return reason;
  }
  if (handoff.caret) {
    const element = find(doc, handoff.caret.path);
    if (!element) return "focus";
    if (textOf(element).trim() !== handoff.caret.text.trim()) return "text";
  }
  for (const saved of handoff.boxes) {
    const element = find(doc, saved.path);
    if (!element) return "box";
    const now = box(element);
    if (!near(now.x, saved.x) || !near(now.y, saved.y) || !near(now.w, saved.w) || !near(now.h, saved.h)) return "box";
  }
  for (const spot of handoff.scroll) {
    const element = find(doc, spot.path);
    if (!element) return "scroll";
    if (element.scrollHeight - element.clientHeight < spot.top - 1) return "scroll";
    if (element.scrollWidth - element.clientWidth < spot.left - 1) return "scroll";
  }
  return null;
}

function putValue(field: HTMLInputElement | HTMLTextAreaElement, value: string): void {
  const view = field.ownerDocument.defaultView!;
  const proto = field.localName === "textarea" ? view.HTMLTextAreaElement.prototype : view.HTMLInputElement.prototype;
  // The prototype's setter: React tracks the property and would drop the event.
  Object.getOwnPropertyDescriptor(proto, "value")?.set?.call(field, value);
  field.dispatchEvent(new view.Event("input", { bubbles: true }));
}

function putBack(doc: Document, handoff: SwapHandoff): void {
  for (const spot of handoff.scroll) {
    const element = find(doc, spot.path);
    if (!element) continue;
    if (!near(element.scrollTop, spot.top)) element.scrollTop = spot.top;
    if (!near(element.scrollLeft, spot.left)) element.scrollLeft = spot.left;
  }
  for (const saved of handoff.fields) {
    const field = find(doc, saved.path);
    if (isTextField(field) && field.value === field.defaultValue && field.value !== saved.value)
      putValue(field, saved.value);
  }
  for (const [key, value] of Object.entries(handoff.extras)) {
    try {
      keepers.get(key)?.restore(value);
    } catch {
      // What a component could not restore it restores the way it would after any reload.
    }
  }
  const focus = handoff.focus ? find(doc, handoff.focus) : null;
  if (focus && doc.activeElement !== focus)
    focusRoute(focus, "system", "a web swap gives the keys back", { preventScroll: true });
  const caret = handoff.caret;
  if (!caret || caretBack(doc, caret)) return;
  const element = find(doc, caret.path);
  if (!element) return;
  if (isTextField(element)) {
    if (doc.activeElement !== element)
      focusRoute(element, "system", "a web swap gives the caret back", { preventScroll: true });
    if (!hasSelection(element)) return;
    try {
      element.setSelectionRange(caret.start, caret.end, caret.backward ? "backward" : "forward");
    } catch {
      // A field whose type changed under the swap keeps the caret it has.
    }
    return;
  }
  if (doc.activeElement !== element && !element.contains(doc.activeElement))
    focusRoute(element, "system", "a web swap gives the caret back", { preventScroll: true });
  const selection = doc.getSelection();
  if (!selection) return;
  const [startNode, startOffset] = textPoint(element, caret.start);
  const [endNode, endOffset] = textPoint(element, caret.end);
  if (caret.backward) selection.setBaseAndExtent(endNode, endOffset, startNode, startOffset);
  else selection.setBaseAndExtent(startNode, startOffset, endNode, endOffset);
}

function probeOf(doc: Document, handoff: SwapHandoff, capped: boolean, held: string): SwapProbe {
  const caret = handoff.caret;
  const caretElement = caret ? find(doc, caret.path) : null;
  const keptText = !caret || (!!caretElement && textOf(caretElement) === caret.text);
  const keptSelection = !caret || caretBack(doc, caret);
  const active = doc.activeElement;
  const keptFocus = handoff.focus
    ? !!active && (elementPath(active) === handoff.focus || !!find(doc, handoff.focus)?.contains(active))
    : true;
  const keptScroll = handoff.scroll.every((spot) => {
    const element = find(doc, spot.path);
    return !!element && near(element.scrollTop, spot.top) && near(element.scrollLeft, spot.left);
  });
  const keptFields = handoff.fields.every((saved) => {
    const field = find(doc, saved.path);
    return isTextField(field) && field.value === saved.value;
  });
  const keptBoxes = handoff.boxes.every((saved) => {
    const element = find(doc, saved.path);
    if (!element) return false;
    const now = box(element);
    return near(now.x, saved.x) && near(now.y, saved.y) && near(now.w, saved.w) && near(now.h, saved.h);
  });
  const view = doc.defaultView!;
  return {
    kind: "swap",
    page: view.location.pathname.split("/").filter(Boolean)[0] ?? view.location.host,
    at: Date.now(),
    restored_ms: Date.now() - handoff.at,
    capped,
    held,
    kept_text: keptText,
    kept_selection: keptSelection,
    kept_focus: keptFocus,
    kept_scroll: keptScroll,
    kept_fields: keptFields,
    kept_boxes: keptBoxes,
    layout_shift: null,
    kept: keptText && keptSelection && keptFocus && keptScroll && keptFields && keptBoxes,
  };
}

/** One painted frame (a timer where a hidden document draws none). */
function afterFrame(view: Window): Promise<void> {
  return new Promise((done) => {
    if (view.document.visibilityState !== "visible") return void view.setTimeout(done, 0);
    view.requestAnimationFrame(() => view.setTimeout(done, 0));
  });
}

function layoutShiftAfter(view: Window, ms: number): Promise<number | null> {
  const Observer = (view as unknown as { PerformanceObserver?: typeof PerformanceObserver }).PerformanceObserver;
  if (!Observer?.supportedEntryTypes?.includes("layout-shift")) return Promise.resolve(null);
  return new Promise((done) => {
    let sum = 0;
    const observer = new Observer((list) => {
      for (const entry of list.getEntries()) sum += (entry as unknown as { value: number }).value ?? 0;
    });
    observer.observe({ type: "layout-shift", buffered: false } as PerformanceObserverInit);
    view.setTimeout(() => {
      observer.disconnect();
      done(Math.round(sum * 10000) / 10000);
    }, ms);
  });
}

/** At document start: a fresh hand-off keeps the document invisible until it is the page it was. */
export function startSwapRestore(doc: Document = document): void {
  const view = doc.defaultView;
  if (!view) return;
  const handoff = takeHandoff(view, Date.now());
  restored = Promise.resolve(null);
  if (!handoff) return;
  const root = doc.documentElement;
  // A hidden page (a chat in another tab) shows nothing meanwhile and may get no timer for a second:
  // it puts its state back without hiding, so showing it later never shows a cleared page.
  if (doc.visibilityState === "visible") root.setAttribute(SWAP_RESTORING_ATTRIBUTE, "");
  const style = doc.createElement("style");
  // No transition runs while it restores: a field, a fold or a scroller put back shows put back,
  // not on its way there.
  style.textContent = `html[${SWAP_RESTORING_ATTRIBUTE}]{opacity:0!important}html[${SWAP_RESTORING_ATTRIBUTE}] *{transition:none!important}`;
  (doc.head ?? root).appendChild(style);
  restored = new Promise((resolve) => {
    const started = Date.now();
    let changed = Date.now();
    const mutations = new view.MutationObserver(() => (changed = Date.now()));
    mutations.observe(root, { childList: true, subtree: true, attributes: true, characterData: true });
    // A person who types or clicks during the restore gets the page as it is, at once.
    let interrupted = false;
    const interrupt = () => (interrupted = true);
    view.addEventListener("keydown", interrupt, { capture: true, once: true });
    view.addEventListener("pointerdown", interrupt, { capture: true, once: true });
    const look = () => {
      const held = notBack(doc, handoff);
      const quiet = Date.now() - changed >= QUIET_MS;
      const capped = Date.now() - started >= REVEAL_CAP_MS;
      if (!interrupted && !capped && (held || !quiet)) return void view.setTimeout(look, POLL_MS);
      mutations.disconnect();
      view.removeEventListener("keydown", interrupt, { capture: true });
      view.removeEventListener("pointerdown", interrupt, { capture: true });
      if (!interrupted) putBack(doc, handoff);
      root.removeAttribute(SWAP_RESTORING_ATTRIBUTE);
      const shifts = layoutShiftAfter(view, 500);
      void afterFrame(view).then(() => {
        const probe = probeOf(doc, handoff, capped && !!(held || !quiet), held ?? (quiet ? "" : "dom"));
        style.remove();
        resolve(probe);
        void shifts.then((shift) => {
          const record = { ...probe, layout_shift: shift };
          (view as unknown as { __cmuxSwapProbe?: SwapProbe }).__cmuxSwapProbe = record;
          view.dispatchEvent(new view.CustomEvent("cmux-swap-probe", { detail: record }));
          console.info("cmux.swap " + JSON.stringify(record));
        });
      });
    };
    look();
  });
}
