// `debug.agent_pane {action: "layout_watch"}` (DEBUG automation): what moved on the page after it
// first showed its content. The click-through check (scripts/cmux-next/clickthrough-live.py) calls
// it right after a chat or workspace switch. Every frame for `ms` it reads the frames of the
// composer, its chips, the header and the transcript's rows; once the composer and the transcript
// (or the empty chat) are drawn, that frame is the first paint, and any element that later moves
// or resizes by more than `tolerance` px, or appears only later, is reported. Leo 2026-10-18: "we
// know the final layout", so after first paint nothing may jump. A New Tab page has neither composer
// nor transcript: its own parts are read by name, and its first paint is the frame with its box and field.
// There are 2 New Tab pages, the Classic one (root `.acpmux-newtab`) and the default one (root `.nt-screen`,
// its box `.nt-box`, its field `.nt-field`): the reply names the page that it read (`new_tab_page`) and has
// the first frame in which that page's root has a box (`root_ms`). Each `_page_ms` is the same frame as a
// time from the page's own start (performance.now()), so a field that comes long after its root shows, also
// when the watch starts late. A frame here is a frame of the page's script, not a frame on the screen.

import { chatSnapshotReport } from "./chatSnapshot/live";

export type LayoutWatchOptions = { ms?: number; tolerance?: number };

type Box = { x: number; y: number; w: number; h: number };
type Frame = { at: number; boxes: Map<string, Box>; scrollTop: number; empty: boolean };

const ROWS = ".cv-message, .cv-worked, .cv-tool, .cv-turn-actions";
const MAX_ROWS = 40;
/// The New Tab page's parts inside `.acpmux-newtab` (NewTabPage.tsx), each class without its `acpmux-`: the
/// box with the field and the kinds, the line under them with the project's chip (ProjectChooser.tsx), the
/// footer, the suggestions, a failed open and the actions. A second node of a class is `NAME:1`. That page
/// has no composer and no transcript row.
const NEW_TAB_PARTS = [
  "newtab-box",
  "newtab-row",
  "newtab-field",
  "newtab-switch",
  "newtab-kind",
  "newtab-under",
  "newtab-context",
  "project-button",
  "newtab-chip",
  "send",
  "newtab-foot",
  "omni",
  "omni-row",
  "newtab-failed",
  "newtab-actions",
  "newtab-all",
];
/// The default New Tab page's parts inside `.nt-screen` (newtab/NewTabScreen.tsx and its blocks), each by its
/// class: the composer with the strip above its box, the box, the input, the field's slot, the field, the
/// pickers and the foot; the toolbar; the room that the composer keeps in the list layout; the stage with its
/// cards; the starters, the player, the open tabs, the chats with their cards, and the list of all chats. A
/// second node of a class is `NAME:1`. The list of suggestions (`nt-rows`) is drawn in a layer of the
/// document, outside the root (ui/Popover.tsx): it is read in the whole document while the root is there.
export const NEW_TAB_SCREEN_PARTS = [
  "nt-composer",
  "nt-above",
  "nt-location",
  "nt-box",
  "nt-input",
  "nt-field-slot",
  "nt-field",
  "nt-pickers",
  "nt-foot",
  "nt-toolbar",
  "nt-composer-room",
  "nt-stage",
  "nt-stage-cards",
  "nt-stage-card",
  "nt-starters",
  "nt-player",
  "nt-open-tabs",
  "nt-chats",
  "nt-cards",
  "nt-card",
  "nt-all",
  "nt-rows",
];

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
  const newTab = document.querySelector(".acpmux-newtab");
  add("newtab", newTab);
  for (const part of NEW_TAB_PARTS) {
    const nodes = newTab ? [...newTab.querySelectorAll(`.acpmux-${part}`)] : [];
    for (const [index, node] of nodes.entries()) add(index ? `${part}:${index}` : part, node);
  }
  const screen = document.querySelector(".nt-screen");
  add("nt-screen", screen);
  if (screen)
    for (const part of NEW_TAB_SCREEN_PARTS) {
      const nodes = [...(part === "nt-rows" ? document : screen).querySelectorAll(`.${part}`)].slice(0, MAX_ROWS);
      for (const [index, node] of nodes.entries()) add(index ? `${part}:${index}` : part, node);
    }
  return {
    at: performance.now() - start,
    boxes,
    scrollTop: Math.round(scroller()?.scrollTop ?? 0),
    empty: emptyChat(),
  };
}

const shown = (frame: Frame) =>
  (frame.boxes.has("composer") && ([...frame.boxes.keys()].some((name) => name.startsWith("row#")) || frame.empty)) ||
  (frame.boxes.has("newtab-box") && frame.boxes.has("newtab-field")) ||
  (frame.boxes.has("nt-box") && frame.boxes.has("nt-field"));
const emptyChat = () => document.querySelectorAll(ROWS).length === 0 && document.body.innerText.trim().length > 0;

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
  // The first frame in which a New Tab page's root has a box, and which of the 2 pages it is (none on a
  // chat's page). `start` is the page's own time at the watch's start, so `start + at` is from the page's start.
  const rooted = frames.find((frame) => frame.boxes.has("newtab") || frame.boxes.has("nt-screen"));
  const root = {
    new_tab_page: !rooted ? null : rooted.boxes.has("newtab") ? "classic" : "default",
    root_ms: rooted ? Math.round(rooted.at) : null,
    root_page_ms: rooted ? Math.round(start + rooted.at) : null,
  };
  const first = frames.findIndex(shown);
  if (first < 0)
    return {
      frames: frames.length,
      started_wall_ms: startedWallMs,
      first_content_ms: null,
      first_content_page_ms: null,
      ...root,
      first_rows: 0,
      new_tab: null,
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
  const scrollJumps = frames
    .slice(first + 1)
    .filter((frame, index, list) => Math.abs(frame.scrollTop - (index ? list[index - 1]! : base).scrollTop) > tolerance)
    .map((frame) => ({ at_ms: Math.round(frame.at), scroll_top: frame.scrollTop }));
  return {
    frames: frames.length,
    started_wall_ms: startedWallMs,
    first_content_ms: Math.round(base.at),
    first_content_page_ms: Math.round(start + base.at),
    ...root,
    // The transcript rows the first paint drew: 0 when it was the empty chat (or a page still loading its
    // transcript, which reads the same), so a caller that opened a chat with messages can tell them apart.
    first_rows: [...base.boxes.keys()].filter((name) => name.startsWith("row#")).length,
    elements: base.boxes.size,
    // A New Tab page's first paint: each part's box by name (null on a chat's page).
    new_tab: base.boxes.has("newtab-box") || base.boxes.has("nt-box") ? Object.fromEntries(base.boxes) : null,
    // The chat's drawn copy (chatSnapshot/): when it painted and when the live page took over, in
    // the page's own clock (ms since the document began), or why none drew, and the page's writes.
    snapshot: chatSnapshotReport(),
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
