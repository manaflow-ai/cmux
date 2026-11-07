// The New Tab page's lists (Open Tabs, Recently Closed, the chat cards) move with their rows
// (motion pass, plans/cmux-next/motion.md), as the template switch moves its parts: a row in both
// the old and the new list slides from where it was drawn to its new place (`--agent-motion-move`),
// and a row that arrives or leaves does so at once: a new row is drawn where it lands in the frame
// it arrives, with no fade (Leo 2026-10-22: "we should basically have no entry animations a lot of
// the time, esp here all over the new tab area"; test/new-tab-no-entry-motion.test.ts).
// Rows are told apart by their keys, never by position. Only transform animates (Web Animations),
// and a change mid-motion starts from what is on screen. Reduce Motion drops the slides (rule 7):
// its move token is 0.
//
// A fold (All chats' project header, Leo, 2026-11-07: "they dont overshoot but they decelerate at the
// end. i think that might be the key") is one change its owner arms just before it (`arm`), with its own
// duration and curve (the settle). It reads the drawn rows (a fold still running included), and after
// the change every row still drawn slides from there to its place on those frames; a row that comes
// into the drawn range only now moves with the rows under the header. The rows the fold hides leave
// the list at once, as every row does, and a drawn copy of each (inert and hidden from assistive tech,
// as the transcript's fold draws them, conversation/turnFold.ts) slides into the header and fades on the
// same frames, gone when they end; the rows it shows come out of the header, fading in. A fold cut short
// goes back from where its rows and copies are drawn. One Web Animation per drawn row, each ending by
// itself; no frame loop and no timer. Reduce Motion, the pane's motion off or a hidden page: one frame.
// A list made with `armedOnly` (a virtual one, whose drawn rows change as it scrolls) moves only on an
// armed change, and reads its rows' keys from their elements (`keyOf`).
import { type RefObject, useLayoutEffect, useRef } from "react";
import { isAgentMotionOff } from "../../shared/motion";
import { entranceAllowed } from "../../shared/pageReveal";
import { motionMode } from "../../../ui/motion/motionMode";

type Places = Map<string, { x: number; y: number }>;

/// How long the list's size holds still before its rows' places are read again after a resize.
const RESIZE_SETTLE_MS = 120;

function seconds(value: string): number {
  const text = value.trim();
  const number = Number.parseFloat(text);
  if (!Number.isFinite(number) || number <= 0) return 0;
  return text.endsWith("ms") ? number / 1000 : number;
}

/// The translation a running slide draws `element` at now.
function drawnShift(element: HTMLElement): { x: number; y: number } {
  const transform = getComputedStyle(element).transform;
  if (!transform || transform === "none") return { x: 0, y: 0 };
  const matrix = new DOMMatrixReadOnly(transform);
  return { x: matrix.m41, y: matrix.m42 };
}

/// Where each row's box is laid out, relative to `root`: drawn places less their running slides.
function cancelRunning(running: { current: Animation[] }): void {
  // Clear the live set before cancelling: oncancel removes its own animation,
  // and mutating the array while iterating would skip every other animation.
  const animations = running.current;
  running.current = [];
  for (const animation of animations) animation.cancel();
}

/// A running animation, and the drawn copy of a hidden row it moves (dropped when it ends).
type Running = Animation & { ghost?: HTMLElement };

function trackAnimation(running: { current: Animation[] }, animation: Running): Running {
  const remove = () => {
    const index = running.current.indexOf(animation);
    if (index >= 0) running.current.splice(index, 1);
    animation.ghost?.remove();
  };
  animation.onfinish = remove;
  animation.oncancel = remove;
  running.current.push(animation);
  return animation;
}

/// More than one row arrives or more than one leaves.
function isLoad(before: readonly string[], after: readonly string[]): boolean {
  const was = new Set(before);
  const is = new Set(after);
  let arrived = 0;
  let left = 0;
  for (const key of is) if (!was.has(key) && ++arrived > 1) return true;
  for (const key of was) if (!is.has(key) && ++left > 1) return true;
  return false;
}

type Size = { width: number; height: number };

/// Reads each row's place in the list, and the list's own size into `size`.
function measure(
  root: HTMLElement,
  elements: HTMLElement[],
  keys: readonly string[],
  size: { current: Size | null },
): Places {
  const origin = root.getBoundingClientRect();
  size.current = { width: origin.width, height: origin.height };
  return new Map(
    elements.map((element, index) => {
      const rect = element.getBoundingClientRect();
      const shift = drawnShift(element);
      return [keys[index], { x: rect.left - origin.left - shift.x, y: rect.top - origin.top - shift.y }] as const;
    }),
  );
}

/// A fold its owner arms just before the change (`ListMotion.arm`).
export interface ListFold {
  /// Its duration (ms) and curve: the settle (MOTION_SETTLE_MS, MOTION_SETTLE).
  ms: number;
  easing: string;
  /// The key of the row the hidden rows fold into and the shown ones come out of (a project's header).
  into: string;
  /// The keys of the rows the change hides (folding) or shows (opening).
  rows: ReadonlySet<string>;
  opening: boolean;
}

export interface ListMotion {
  /// Arms the next change as `fold`: call it in the handler, before the state change.
  arm(fold: ListFold): void;
}

/// What a drawn copy of a hidden row carries (it is not a row: no motion reads it as one).
export const LIST_GHOST_ATTR = "data-list-ghost";

type Drawn = { node: HTMLElement; parent: Node | null; top: number; opacity: number };
type Armed = { fold: ListFold; drawn: Map<string, Drawn> };

function opacityOf(node: HTMLElement): number {
  const value = Number.parseFloat(node.ownerDocument.defaultView?.getComputedStyle(node).opacity ?? "1");
  return Number.isFinite(value) ? value : 1;
}

/// A copy of `row` that can sit in the list for the fold's frames: no ids, nothing focusable or found.
function ghostOf(row: HTMLElement): HTMLElement {
  const copy = row.cloneNode(true) as HTMLElement;
  for (const node of [copy, ...copy.querySelectorAll<HTMLElement>("[id], [tabindex], button, a[href]")]) {
    node.removeAttribute("id");
    node.removeAttribute("tabindex");
  }
  for (const name of ["role", "aria-posinset", "aria-setsize", "aria-current"]) copy.removeAttribute(name);
  copy.setAttribute(LIST_GHOST_ATTR, "");
  copy.setAttribute("aria-hidden", "true");
  copy.setAttribute("inert", "");
  copy.style.pointerEvents = "none";
  return copy;
}

/// One armed fold, after its change: every drawn row slides from where it was drawn to its place, the
/// shown rows come out of `into`, and a copy of each hidden row folds into it, on the fold's frames.
function playFold(
  root: HTMLElement,
  elements: HTMLElement[],
  keyOf: (element: HTMLElement) => string,
  armed: Armed,
  running: { current: Animation[] },
): void {
  const { fold, drawn } = armed;
  const origin = root.getBoundingClientRect().top;
  const top = (node: HTMLElement) => node.getBoundingClientRect().top - origin;
  const timing = { duration: fold.ms, easing: fold.easing };
  const play = (node: HTMLElement, from: Keyframe, to: Keyframe, fill?: FillMode): Running =>
    trackAnimation(running, node.animate([from, to], fill ? { ...timing, fill } : timing));
  const placed = elements.map((node) => ({ node, key: keyOf(node), top: top(node) }));
  const header = placed.find((row) => row.key === fold.into);
  const into = header?.top ?? drawn.get(fold.into)?.top ?? 0;
  // What the rows under the header moved by: one drawn before and after says.
  const stayed = placed.find((row) => row.top > into && !fold.rows.has(row.key) && drawn.has(row.key));
  const shift = stayed ? drawn.get(stayed.key)!.top - stayed.top : 0;
  for (const row of placed) {
    const was = drawn.get(row.key);
    const from: Keyframe = {};
    const to: Keyframe = {};
    if (was && was.node.isConnected) {
      // Drawn before (a header, a row under it, or a row a copy stood in for): from there.
      const delta = was.top - row.top;
      if (Math.abs(delta) >= 0.5) {
        from.translate = `0 ${delta}px`;
        to.translate = "0 0";
      }
      if (was.opacity < 1) {
        from.opacity = was.opacity;
        to.opacity = 1;
      }
    } else if (fold.opening && fold.rows.has(row.key)) {
      // Shown by the fold: out of the header (or back from its copy), fading in.
      const delta = (was ? was.top : into) - row.top;
      from.translate = `0 ${delta}px`;
      to.translate = "0 0";
      from.opacity = was?.opacity ?? 0;
      to.opacity = 1;
    } else if (row.top > into && Math.abs(shift) >= 0.5) {
      // Drawn only now, under the header: it moves with the rows there.
      from.translate = `0 ${shift}px`;
      to.translate = "0 0";
    }
    if (Object.keys(from).length > 0) play(row.node, from, to);
  }
  // The rows the fold hid: a drawn copy of each folds into the header and fades, then goes.
  if (fold.opening) return;
  for (const key of fold.rows) {
    const was = drawn.get(key);
    if (!was || was.node.isConnected || !was.parent) continue;
    const ghost = ghostOf(was.node);
    was.parent.appendChild(ghost);
    // It goes when its motion ends or is cancelled (a new fold, a hidden page, the list unmounting).
    play(
      ghost,
      { translate: "0 0", opacity: was.opacity },
      { translate: `0 ${into - was.top}px`, opacity: 0 },
      "forwards",
    ).ghost = ghost;
  }
}

/// Animates the rows of the list in `list` when `keys` change: `rows` selects them under the list's
/// own children (a row's box, not its `display: contents` menu host), in the order of `keys`.
/// Places are relative to the list, so a list that moves as a whole (the template switch) carries
/// its rows, and they are measured again once the list's size holds still after a resize (the cards
/// grid changes its columns with the pane's width, with no render), so a later change never slides
/// from a stale place. A live resize reads no row on its frames (Leo 2026-10-20: the page's resize
/// was "slow and wack"; new-tab-live-resize): a change landing before the size settles takes its
/// places at once, like a hidden page's.
export function useListMotion(
  list: RefObject<HTMLElement | null>,
  rows: string,
  keys: readonly string[],
  options: { armedOnly?: boolean; keyOf?: (element: HTMLElement) => string } = {},
): ListMotion {
  const places = useRef<Places>(new Map());
  const running = useRef<Animation[]>([]);
  const armed = useRef<Armed | undefined>(undefined);
  const optionsRef = useRef(options);
  optionsRef.current = options;
  /// The list's drawn rows (not the copies of hidden ones) and the copies, under `root`.
  const drawnRows = (root: HTMLElement) =>
    [...root.querySelectorAll<HTMLElement>(`:scope > ${rows}`)].filter((node) => !node.hasAttribute(LIST_GHOST_ATTR));
  const arm = (fold: ListFold) => {
    const root = list.current;
    armed.current = undefined;
    if (!root || motionMode(root.ownerDocument) !== "full" || typeof root.animate !== "function") return;
    const keyOf = (node: HTMLElement, index: number) =>
      optionsRef.current.keyOf?.(node) ?? keysRef.current[index] ?? "";
    const origin = root.getBoundingClientRect().top;
    const drawn = new Map<string, Drawn>();
    const read = (node: HTMLElement, key: string) => {
      if (!key) return;
      const top = node.getBoundingClientRect().top - origin;
      drawn.set(key, { node, parent: node.parentNode, top, opacity: opacityOf(node) });
    };
    for (const [index, node] of drawnRows(root).entries()) read(node, keyOf(node, index));
    // A copy still folding away (a fold cut short): its row comes back from where it is drawn.
    if (optionsRef.current.keyOf)
      for (const node of root.querySelectorAll<HTMLElement>(`[${LIST_GHOST_ATTR}]`))
        read(node, optionsRef.current.keyOf(node));
    armed.current = { fold, drawn };
  };
  const shown = useRef<string>("");
  const shownKeys = useRef<readonly string[]>([]);
  const keysRef = useRef(keys);
  keysRef.current = keys;
  const signature = JSON.stringify(keys);
  const observed = useRef<{ root: HTMLElement; observer: ResizeObserver; settle: () => void } | null>(null);
  // The list resized since its places were read: they are read again when the size settles.
  const stale = useRef(false);
  // The list's size when its places were last read. A row arriving or leaving resizes the list
  // itself; the observer then reports the size just read, which leaves the places current.
  const measuredSize = useRef<Size | null>(null);
  useLayoutEffect(() => {
    // A page hidden mid-motion (another New Tab opened over it) ends its motion there: WebKit
    // suspends a hidden page's animations, and this one would finish when the page shows again.
    const doc = list.current?.ownerDocument ?? (typeof document === "undefined" ? undefined : document);
    const hid = () => {
      if (doc?.visibilityState === "hidden") cancelRunning(running);
    };
    doc?.addEventListener("visibilitychange", hid);
    return () => {
      doc?.removeEventListener("visibilitychange", hid);
      observed.current?.observer.disconnect();
      observed.current?.settle();
      observed.current = null;
      cancelRunning(running);
    };
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- the list's document, read once at mount.
  }, []);
  // The key signature is the invalidation boundary for list motion. The callers derive `keys`
  // from their snapshots and may allocate a fresh array on every render; depending on that array
  // would put the measurement work back on every render. ResizeObserver remains responsible for
  // layout-only changes such as a grid column switch.
  useLayoutEffect(() => {
    const currentKeys = keysRef.current;
    const root = list.current;
    // An armed fold: every drawn row moves on its frames, from where it was drawn.
    const fold = armed.current;
    armed.current = undefined;
    if (fold && root) {
      cancelRunning(running);
      const elements = drawnRows(root);
      const keyOf = (node: HTMLElement) =>
        optionsRef.current.keyOf?.(node) ?? currentKeys[elements.indexOf(node)] ?? "";
      playFold(root, elements, keyOf, fold, running);
      if (!optionsRef.current.armedOnly && elements.length === currentKeys.length) {
        places.current = measure(root, elements, currentKeys, measuredSize);
        shown.current = signature;
        shownKeys.current = currentKeys;
      }
      return;
    }
    // A virtual list moves only on an armed change: a scroll draws other rows, which never slide.
    if (optionsRef.current.armedOnly) {
      if (shown.current !== signature) cancelRunning(running);
      shown.current = signature;
      return;
    }
    if (observed.current?.root !== root) {
      if (observed.current?.root) cancelRunning(running);
      observed.current?.observer.disconnect();
      observed.current?.settle();
      observed.current = null;
      stale.current = false;
      if (root && typeof ResizeObserver !== "undefined") {
        let timer: ReturnType<typeof setTimeout> | undefined;
        const remeasure = () => {
          timer = undefined;
          stale.current = false;
          const elements = [...root.querySelectorAll<HTMLElement>(`:scope > ${rows}`)];
          if (shown.current !== "" && elements.length === shownKeys.current.length)
            places.current = measure(root, elements, shownKeys.current, measuredSize);
        };
        let first = true;
        const observer = new ResizeObserver((entries) => {
          // The observer's first call is the size the list mounted at, which the effect just read.
          if (first) {
            first = false;
            return;
          }
          const box = entries?.at(-1)?.borderBoxSize?.[0];
          const read = measuredSize.current;
          if (box && read && Math.abs(box.inlineSize - read.width) < 0.5 && Math.abs(box.blockSize - read.height) < 0.5)
            return;
          stale.current = true;
          if (timer !== undefined) clearTimeout(timer);
          timer = setTimeout(remeasure, RESIZE_SETTLE_MS);
        });
        observer.observe(root);
        observed.current = {
          root,
          observer,
          settle: () => {
            if (timer !== undefined) clearTimeout(timer);
            timer = undefined;
          },
        };
      }
    }
    const elements = root ? [...root.querySelectorAll<HTMLElement>(`:scope > ${rows}`)] : [];
    if (!root || elements.length !== currentKeys.length) {
      cancelRunning(running);
      places.current = new Map();
      shown.current = "";
      shownKeys.current = [];
      return;
    }
    // A hidden page (an earlier New Tab page parked behind a newer one, Leo 2026-10-19; a tab in
    // another workspace) moves nothing either: its rows take their new places at once. WebKit
    // suspends a hidden page's animations, so a slide started now would play when the page
    // shows again. A change landing before the first frame back was made while the user was away
    // (Leo 2026-10-20), so it takes its places at once too (shared/pageReveal.ts).
    if (isAgentMotionOff() || !entranceAllowed(root.ownerDocument)) {
      cancelRunning(running);
      places.current = measure(root, elements, currentKeys, measuredSize);
      stale.current = false;
      shown.current = signature;
      shownKeys.current = currentKeys;
      return;
    }
    // Only a real insert or removal moves: a row or so arriving or leaving. A list that swaps
    // more at once is a load (a page shows the app's device chats, then acpmux's sessions take
    // their slots under other keys), and is drawn in place like the first one.
    const changed =
      !stale.current && shown.current !== "" && shown.current !== signature && !isLoad(shownKeys.current, currentKeys);
    const before = places.current;
    // Reads: where each row is drawn now (running slides included), then its new place.
    const drawn = new Map(elements.map((element, index) => [currentKeys[index], drawnShift(element)] as const));
    if (shown.current !== signature) cancelRunning(running);
    const after = measure(root, elements, currentKeys, measuredSize);
    places.current = after;
    stale.current = false;
    shown.current = signature;
    shownKeys.current = currentKeys;
    if (!changed) return;
    const style = getComputedStyle(root);
    const reduced = globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    const move = reduced ? 0 : seconds(style.getPropertyValue("--agent-motion-move")) * 1000;
    const easing = style.getPropertyValue("--agent-ease-out").trim() || "ease-out";
    // CSS cannot cancel Web Animations API instances. The explicit host policy is still honored
    // here when a list update races the theme's zero-motion transition.
    const motionOff = root.ownerDocument.documentElement.dataset.agentMotion === "off";
    if (motionOff) return;
    // Writes.
    for (const [index, element] of elements.entries()) {
      const key = currentKeys[index];
      const was = before.get(key);
      const is = after.get(key);
      // A row that just arrived is already in its place: it moves nothing.
      if (!was || !is) continue;
      const shift = drawn.get(key) ?? { x: 0, y: 0 };
      const x = was.x + shift.x - is.x;
      const y = was.y + shift.y - is.y;
      if (move > 0 && (Math.abs(x) > 0.5 || Math.abs(y) > 0.5)) {
        trackAnimation(
          running,
          element.animate([{ transform: `translate(${x}px, ${y}px)` }, { transform: "none" }], {
            duration: move,
            easing,
          }),
        );
      }
    }
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- `keys` is represented by its value signature.
  }, [list, rows, signature]);
  return { arm };
}
