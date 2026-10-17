// The New Tab page's lists (Open Tabs, Recently Closed, the chat cards) move with their rows
// (motion pass, plans/cmux-next/motion.md), as the template switch moves its parts: a row in both
// the old and the new list slides from where it was drawn to its new place (`--agent-motion-move`),
// a new row fades in where it lands (`--agent-motion-in`), and a row that left goes at once.
// Rows are told apart by their keys, never by position. Only transform and opacity animate (Web
// Animations), and a change mid-motion starts from what is on screen. Reduce Motion keeps the
// fades and drops the slides (rule 7): its move token is 0.
import { type RefObject, useLayoutEffect, useMemo, useRef } from "react";

type Places = Map<string, { x: number; y: number }>;

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
function measure(root: HTMLElement, elements: HTMLElement[], keys: readonly string[]): Places {
  const origin = root.getBoundingClientRect();
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
/// its rows, and they are measured again when the list resizes (the cards grid changes its columns
/// with the pane's width, with no render), so a later change never slides from a stale place.
export function useListMotion(list: RefObject<HTMLElement | null>, rows: string, keys: readonly string[]): void {
  const places = useRef<Places>(new Map());
  const running = useRef<Animation[]>([]);
  const shown = useRef<string>("");
  const shownKeys = useRef<readonly string[]>([]);
  const signature = keys.join("\n");
  const keyList = useMemo(() => (signature === "" ? [] : signature.split("\n")), [signature]);
  const observed = useRef<{ root: HTMLElement; observer: ResizeObserver } | null>(null);
  useLayoutEffect(() => () => observed.current?.observer.disconnect(), []);
  useLayoutEffect(() => {
    const root = list.current;
    if (observed.current?.root !== root) {
      observed.current?.observer.disconnect();
      observed.current = null;
      if (root && typeof ResizeObserver !== "undefined") {
        const observer = new ResizeObserver(() => {
          const elements = [...root.querySelectorAll<HTMLElement>(`:scope > ${rows}`)];
          if (shown.current !== "" && elements.length === shownKeys.current.length)
            places.current = measure(root, elements, shownKeys.current);
        });
        observer.observe(root);
        observed.current = { root, observer };
      }
    }
    const elements = root ? [...root.querySelectorAll<HTMLElement>(`:scope > ${rows}`)] : [];
    if (!root || elements.length !== keyList.length) {
      places.current = new Map();
      shown.current = "";
      return;
    }
    const changed = shown.current !== "" && shown.current !== signature;
    const before = places.current;
    // Reads: where each row is drawn now (running slides included), then its new place.
    const drawn = new Map(elements.map((element, index) => [keyList[index], drawnShift(element)] as const));
    if (changed) for (const animation of running.current) animation.cancel();
    if (changed) running.current = [];
    const after = measure(root, elements, keyList);
    places.current = after;
    shown.current = signature;
    shownKeys.current = keyList;
    if (!changed) return;
    const style = getComputedStyle(root);
    const reduced = globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    const move = reduced ? 0 : seconds(style.getPropertyValue("--agent-motion-move")) * 1000;
    const appear = seconds(style.getPropertyValue("--agent-motion-in")) * 1000;
    const easing = style.getPropertyValue("--agent-ease-out").trim() || "ease-out";
    // Writes.
    for (const [index, element] of elements.entries()) {
      const key = keyList[index];
      const was = before.get(key);
      const is = after.get(key);
      if (!was || !is) {
        if (appear > 0)
          running.current.push(element.animate([{ opacity: 0 }, { opacity: 1 }], { duration: appear, easing }));
        continue;
      }
      const shift = drawn.get(key) ?? { x: 0, y: 0 };
      const x = was.x + shift.x - is.x;
      const y = was.y + shift.y - is.y;
      if (move > 0 && (Math.abs(x) > 0.5 || Math.abs(y) > 0.5)) {
        running.current.push(
          element.animate([{ transform: `translate(${x}px, ${y}px)` }, { transform: "none" }], {
            duration: move,
            easing,
          }),
        );
      }
    }
  }, [keyList, list, rows, signature]);
}
