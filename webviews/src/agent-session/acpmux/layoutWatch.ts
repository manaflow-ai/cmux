// `debug.agent_pane {action: "layout_watch"}` (DEBUG automation): what moved on the page after it
// first showed its content. The click-through check (scripts/cmux-next/clickthrough-live.py) calls
// it right after a chat or workspace switch. Every frame for `ms` it reads the frames of the
// composer, its chips, the header and the transcript's rows; once the composer and the transcript
// (or the empty chat) are drawn, that frame is the first paint, and any element that later moves
// or resizes by more than `tolerance` px, or appears only later, is reported. Leo 2026-10-18: "we
// know the final layout", so after first paint nothing may jump.

export type LayoutWatchOptions = { ms?: number; tolerance?: number };

type Box = { x: number; y: number; w: number; h: number };
type Frame = { at: number; boxes: Map<string, Box>; scrollTop: number; empty: boolean };

const ROWS = ".cv-message, .cv-worked, .cv-tool, .cv-turn-actions";
const MAX_ROWS = 40;

/// Stable names for elements across frames: the same node keeps its name.
const names = new WeakMap<Element, string>();
let nextName = 0;
function nameOf(node: Element, kind: string): string {
  let name = names.get(node);
  if (!name) {
    nextName += 1;
    name = `${kind}#${nextName}`;
    names.set(node, name);
  }
  return name;
}

function boxOf(node: Element): Box | undefined {
  const rect = node.getBoundingClientRect();
  if (rect.width <= 0 || rect.height <= 0) return undefined;
  return { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) };
}

/// The transcript's scroller: the tallest scrollable element holding a row.
function scroller(): Element | undefined {
  const row = document.querySelector(ROWS);
  for (let node = row?.parentElement; node; node = node.parentElement) {
    if (node.scrollHeight > node.clientHeight + 1 && getComputedStyle(node).overflowY !== "visible") return node;
  }
  return undefined;
}

function read(start: number): Frame {
  const boxes = new Map<string, Box>();
  const add = (name: string, node: Element | null | undefined) => {
    const box = node && boxOf(node);
    if (box) boxes.set(name, box);
  };
  add("composer", document.querySelector(".acpmux-composer"));
  for (const chip of document.querySelectorAll<HTMLElement>("button[data-menu]"))
    add(`chip:${chip.dataset.menu}`, chip);
  add("header", document.querySelector("header, [role=banner]"));
  const rows = [...document.querySelectorAll(ROWS)];
  // The newest rows are the ones on screen when a chat opens at its latest message.
  for (const row of rows.slice(-MAX_ROWS)) add(nameOf(row, "row"), row);
  return {
    at: performance.now() - start,
    boxes,
    scrollTop: Math.round(scroller()?.scrollTop ?? 0),
    empty: emptyChat(),
  };
}

const shown = (frame: Frame) =>
  frame.boxes.has("composer") && ([...frame.boxes.keys()].some((name) => name.startsWith("row#")) || frame.empty);
const emptyChat = () => document.querySelectorAll(ROWS).length === 0 && document.body.innerText.trim().length > 0;

export async function layoutWatch(options: LayoutWatchOptions = {}): Promise<Record<string, unknown>> {
  const ms = Math.max(100, Math.min(options.ms ?? 1500, 10_000));
  const tolerance = options.tolerance ?? 1;
  const start = performance.now();
  const frames: Frame[] = [];
  while (performance.now() - start < ms) {
    frames.push(read(start));
    // wakeup-allow: debug `debug.agent_pane layout_watch` reads frames for at most `ms` (10 s)
    await new Promise((resolve) => requestAnimationFrame(resolve));
  }
  const first = frames.findIndex(shown);
  if (first < 0) return { frames: frames.length, first_content_ms: null, shifts: [], appeared: [], scroll_jumps: [] };
  const base = frames[first]!;
  const shifts: Record<string, unknown>[] = [];
  const appeared: Record<string, unknown>[] = [];
  const seen = new Set(base.boxes.keys());
  const moved = new Set<string>();
  for (const frame of frames.slice(first + 1)) {
    for (const [name, box] of frame.boxes) {
      const was = base.boxes.get(name);
      if (!was) {
        if (!seen.has(name)) {
          seen.add(name);
          appeared.push({ element: name, at_ms: Math.round(frame.at), box });
        }
        continue;
      }
      const delta = Math.max(
        Math.abs(box.x - was.x),
        Math.abs(box.y - was.y),
        Math.abs(box.w - was.w),
        Math.abs(box.h - was.h),
      );
      if (delta > tolerance && !moved.has(name)) {
        moved.add(name);
        shifts.push({ element: name, at_ms: Math.round(frame.at), from: was, to: box });
      }
    }
  }
  const scrollJumps = frames
    .slice(first + 1)
    .filter((frame, index, list) => Math.abs(frame.scrollTop - (index ? list[index - 1]! : base).scrollTop) > tolerance)
    .map((frame) => ({ at_ms: Math.round(frame.at), scroll_top: frame.scrollTop }));
  return {
    frames: frames.length,
    first_content_ms: Math.round(base.at),
    elements: base.boxes.size,
    shifts,
    appeared,
    scroll_jumps: scrollJumps,
  };
}

/// The composer's chips as drawn: each shown `data-menu` button's visible label (a copy laid out
/// off screen to measure the row has no box and is skipped), and the access chip as `Mode`.
export function composerChips(): Record<string, string> {
  const chips: Record<string, string> = {};
  for (const chip of document.querySelectorAll<HTMLElement>("button[data-menu]")) {
    const name = chip.dataset.menu;
    if (!name || name in chips || !boxOf(chip)) continue;
    chips[name] = label(chip);
  }
  // The access chip (a menu, or its stand-in before the chat reports its modes) has no data-menu.
  const access = [...document.querySelectorAll<HTMLElement>(".acpmux-access-trigger")].find((node) => boxOf(node));
  if (access && !("Mode" in chips)) chips.Mode = label(access);
  return chips;
}

const label = (node: HTMLElement) =>
  (node.innerText || node.getAttribute("aria-label") || "").replace(/\s+/g, " ").trim();
