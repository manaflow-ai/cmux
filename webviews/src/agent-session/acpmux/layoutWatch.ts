// `debug.agent_pane {action: "layout_watch"}` (DEBUG automation): what moved on the page after it
// first showed its content. The click-through check (scripts/cmux-next/clickthrough-live.py) calls
// it right after a chat or workspace switch. Every frame for `ms` it reads the frames of the
// composer, its chips, the header and the transcript's rows; once the composer and the transcript
// (or the empty chat) are drawn, that frame is the first paint, and any element that later moves
// or resizes by more than `tolerance` px, or appears only later, is reported. Leo 2026-10-18: "we
// know the final layout", so after first paint nothing may jump.

import { chatSnapshotReport } from "./chatSnapshot/live";
import { SNAPSHOT_HOST_TAG } from "./chatSnapshot/shared";

export type LayoutWatchOptions = { ms?: number; tolerance?: number };

type Box = { x: number; y: number; w: number; h: number };
type Frame = {
  at: number;
  boxes: Map<string, Box>;
  scrollTop: number;
  empty: boolean;
  copy: boolean;
  /// The transcript's scroll height and its last rows' names and heights: what grew when it grew.
  scrollHeight: number;
  tail: string[];
  /// The scroller's parts (each child's class and height, the rows' drawn translate, the stack under
  /// them): read only for frames the report keeps (the first, the swap, a height change).
  parts: () => Record<string, unknown>;
};

const ROWS = ".cv-message, .cv-worked, .cv-tool, .cv-turn-actions";
const MAX_ROWS = 40;

/// Row names that match between the drawn copy and the live page (chatSnapshot/), so the swap from one
/// to the other scores as what the person sees: a row is its kind and text, counted from the
/// transcript's end among rows that read the same. The copy leaves out-of-view rows out and the live
/// page renders more above, so counting from the end keeps the names on screen the same in both.
function rowNames(rows: Element[]): string[] {
  const seen = new Map<string, number>();
  const named = Array.from<string>({ length: rows.length });
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const row = rows[index]!;
    const kind = ROW_KINDS.find((name) => row.classList.contains(name)) ?? "row";
    const text = (row.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 48);
    const key = `${kind}:${text}`;
    const count = (seen.get(key) ?? 0) + 1;
    seen.set(key, count);
    named[index] = count > 1 ? `row#${key}~${count}` : `row#${key}`;
  }
  return named;
}
const ROW_KINDS = ["cv-message", "cv-worked", "cv-tool", "cv-turn-actions"];

/// What the person sees: the drawn copy's shadow root while it shows (the live page under it is at
/// opacity 0 and lays out unseen), else the page.
function shownScope(): { scope: ParentNode; copy: boolean } {
  const host = document.querySelector<HTMLElement>(SNAPSHOT_HOST_TAG);
  const root = host?.shadowRoot;
  if (host && root && host.style.visibility !== "hidden") return { scope: root, copy: true };
  return { scope: document, copy: false };
}

function boxOf(node: Element): Box | undefined {
  const rect = node.getBoundingClientRect();
  if (rect.width <= 0 || rect.height <= 0) return undefined;
  return { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) };
}

/// The transcript's scroller: the tallest scrollable element holding a row.
function scroller(scope: ParentNode): Element | undefined {
  const row = scope.querySelector(ROWS);
  for (let node = row?.parentElement; node; node = node.parentElement) {
    if (node.scrollHeight > node.clientHeight + 1 && getComputedStyle(node).overflowY !== "visible") return node;
  }
  return undefined;
}

function read(start: number): Frame {
  const { scope, copy } = shownScope();
  const boxes = new Map<string, Box>();
  const add = (name: string, node: Element | null | undefined) => {
    const box = node && boxOf(node);
    if (box) boxes.set(name, box);
  };
  add("composer", scope.querySelector(".acpmux-composer"));
  for (const chip of scope.querySelectorAll<HTMLElement>("button[data-menu]")) add(`chip:${chip.dataset.menu}`, chip);
  add("header", scope.querySelector("header, [role=banner]"));
  const rows = [...scope.querySelectorAll(ROWS)];
  const named = rowNames(rows);
  // The newest rows are the ones on screen when a chat opens at its latest message.
  const from = Math.max(0, rows.length - MAX_ROWS);
  for (let index = from; index < rows.length; index += 1) add(named[index]!, rows[index]);
  const list = scroller(scope);
  const tail = rows.slice(-3).map((row, index) => {
    const box = boxOf(row);
    return `${named[rows.length - Math.min(3, rows.length) + index]!.slice(0, 40)} h${box ? box.h : 0}`;
  });
  return {
    at: performance.now() - start,
    boxes,
    scrollTop: Math.round(list?.scrollTop ?? 0),
    empty: emptyChat(scope),
    copy,
    scrollHeight: Math.round(list?.scrollHeight ?? 0),
    tail,
    parts: partsOf(list, scope),
  };
}

/// A snapshot of the scroller's parts now, read when the report asks (the frame's own boxes are read at once).
function partsOf(list: Element | undefined, scope: ParentNode): () => Record<string, unknown> {
  const children = list
    ? [...list.children].slice(0, 6).map((child) => {
        const style = getComputedStyle(child);
        return `${(child.className || child.tagName).toString().split(" ")[0]} h${Math.round(child.getBoundingClientRect().height)} t${style.translate} p${style.paddingBottom}`;
      })
    : [];
  const dock = scope.querySelector(".acpmux-composer")?.parentElement;
  const dockBox = dock && boxOf(dock);
  const view = list && boxOf(list);
  return () => ({ children, dock: dockBox, view });
}

const shown = (frame: Frame) =>
  frame.boxes.has("composer") && ([...frame.boxes.keys()].some((name) => name.startsWith("row#")) || frame.empty);
const emptyChat = (scope: ParentNode) =>
  scope.querySelectorAll(ROWS).length === 0 && document.body.innerText.trim().length > 0;

export async function layoutWatch(options: LayoutWatchOptions = {}): Promise<Record<string, unknown>> {
  const ms = Math.max(100, Math.min(options.ms ?? 1500, 10_000));
  const tolerance = options.tolerance ?? 1;
  const start = performance.now();
  // When the watch began on the wall clock, so a caller times its frames from its own action: the call may
  // reach the page well after it was asked (a Chromium page still starting, PageWebView.callPageScript).
  // Date.now(), not timeOrigin + now(): a page that lived through a sleep has a monotonic clock behind the wall.
  const startedWallMs = Date.now();
  const frames: Frame[] = [];
  while (performance.now() - start < ms) {
    frames.push(read(start));
    await new Promise((resolve) => requestAnimationFrame(resolve));
  }
  const first = frames.findIndex(shown);
  if (first < 0)
    return {
      frames: frames.length,
      started_wall_ms: startedWallMs,
      first_content_ms: null,
      first_rows: 0,
      shifts: [],
      appeared: [],
      scroll_jumps: [],
    };
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
  // A scroll offset compares within one document only: the copy's scroller and the live page's are two
  // elements, and their rows' boxes already score the swap.
  const later = frames.slice(first + 1);
  const scrollJumps = later
    .filter((frame, index) => {
      const before = index ? later[index - 1]! : base;
      return before.copy === frame.copy && Math.abs(frame.scrollTop - before.scrollTop) > tolerance;
    })
    .map((frame) => ({ at_ms: Math.round(frame.at), scroll_top: frame.scrollTop }));
  // What the transcript's end was when its height changed: a row that came or grew late shows here.
  const grew = later
    .filter((frame, index) => {
      const before = index ? later[index - 1]! : base;
      return before.copy === frame.copy && Math.abs(frame.scrollHeight - before.scrollHeight) > tolerance;
    })
    .slice(0, 8)
    .map((frame) => ({
      at_ms: Math.round(frame.at),
      scroll_height: frame.scrollHeight,
      scroll_top: frame.scrollTop,
      tail: frame.tail,
      parts: frame.parts(),
    }));
  const swappedAt = later.find((frame, index) => (index ? later[index - 1]! : base).copy && !frame.copy)?.at;
  return {
    frames: frames.length,
    started_wall_ms: startedWallMs,
    first_content_ms: Math.round(base.at),
    // The transcript rows the first paint drew: 0 when it was the empty chat (or a page still loading its
    // transcript, which reads the same), so a caller that opened a chat with messages can tell them apart.
    first_rows: [...base.boxes.keys()].filter((name) => name.startsWith("row#")).length,
    elements: base.boxes.size,
    // The chat's drawn copy (chatSnapshot/): when it painted and when the live page took over, in
    // the page's own clock (ms since the document began), or why none drew, and the page's writes.
    snapshot: chatSnapshotReport(),
    first_from_copy: base.copy,
    swap_ms: swappedAt === undefined ? null : Math.round(swappedAt),
    first_parts: { scroll_top: base.scrollTop, scroll_height: base.scrollHeight, ...base.parts() },
    swap_parts: (() => {
      const frame = later.find((each, index) => (index ? later[index - 1]! : base).copy && !each.copy);
      return frame ? { scroll_top: frame.scrollTop, scroll_height: frame.scrollHeight, ...frame.parts() } : null;
    })(),
    shifts,
    appeared,
    scroll_jumps: scrollJumps,
    grew,
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
