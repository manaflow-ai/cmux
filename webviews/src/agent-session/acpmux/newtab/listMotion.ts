// The New Tab page's lists (Open Tabs, Recently Closed, the chat cards) move with their rows
// (motion pass, plans/cmux-next/motion.md), as the template switch moves its parts: a row in both
// the old and the new list slides from where it was drawn to its new place (`--agent-motion-move`),
// and a row that arrives or leaves does so at once: a new row is drawn where it lands in the frame
// it arrives, with no fade (Leo 2026-10-22: "we should basically have no entry animations a lot of
// the time, esp here all over the new tab area"; test/new-tab-no-entry-motion.test.ts).
// Rows are told apart by their keys, never by position. Only transform animates (Web Animations),
// and a change mid-motion starts from what is on screen. Reduce Motion drops the slides (rule 7):
// its move token is 0.
import { type RefObject, useLayoutEffect, useRef } from "react";
import { isAgentMotionOff } from "../../shared/motion";
import { entranceAllowed } from "../../shared/pageReveal";

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

function trackAnimation(running: { current: Animation[] }, animation: Animation): void {
  const remove = () => {
    const index = running.current.indexOf(animation);
    if (index >= 0) running.current.splice(index, 1);
  };
  animation.onfinish = remove;
  animation.oncancel = remove;
  running.current.push(animation);
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

/// Animates the rows of the list in `list` when `keys` change: `rows` selects them under the list's
/// own children (a row's box, not its `display: contents` menu host), in the order of `keys`.
/// Places are relative to the list, so a list that moves as a whole (the template switch) carries
/// its rows, and they are measured again once the list's size holds still after a resize (the cards
/// grid changes its columns with the pane's width, with no render), so a later change never slides
/// from a stale place. A live resize reads no row on its frames (Leo 2026-10-20: the page's resize
/// was "slow and wack"; new-tab-live-resize): a change landing before the size settles takes its
/// places at once, like a hidden page's.
export function useListMotion(list: RefObject<HTMLElement | null>, rows: string, keys: readonly string[]): void {
  const places = useRef<Places>(new Map());
  const running = useRef<Animation[]>([]);
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
}
