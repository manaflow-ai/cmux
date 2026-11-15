// What the swap from the drawn copy to the live page changed on screen, read once in the swap's task,
// when both are laid out (the live root under the copy at opacity 0): the composer, its chips, the
// header, the transcript's last rows and the bottom stack's parts, in each. Then, for a few seconds,
// each change of the live bottom stack's height and what it holds. For `debug.agent_pane
// layout_watch` (layoutWatch.ts) and the relaunch-shift bench, which ask after the swap may be over.
// Leo, 2026-11-14: "too much render shift when the thing restarts to update".

type Box = { x: number; y: number; w: number; h: number };

const ROWS = ".cv-message, .cv-worked, .cv-tool, .cv-turn-actions";
/// How long the live stack's changes are kept after the swap.
const AFTER_MS = 4_000;
const MAX_CHANGES = 8;

function boxOf(node: Element | null | undefined): Box | undefined {
  const rect = node?.getBoundingClientRect();
  if (!rect || rect.width <= 0 || rect.height <= 0) return undefined;
  return { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) };
}

/// The bottom stack's parts: each child's first class and height, in order.
function stackParts(dock: Element | null | undefined): string[] {
  if (!dock) return [];
  return [...dock.children].map((child) => {
    const name = (child.getAttribute("class") || child.tagName.toLowerCase()).split(" ")[0];
    return `${name} h${Math.round(child.getBoundingClientRect().height)}`;
  });
}

function boxesIn(scope: ParentNode): Record<string, Box> {
  const boxes: Record<string, Box> = {};
  const add = (name: string, node: Element | null | undefined) => {
    const box = boxOf(node);
    if (box) boxes[name] = box;
  };
  add("composer", scope.querySelector(".acpmux-composer"));
  add("dock", scope.querySelector(".acpmux-dock"));
  add("header", scope.querySelector("header, [role=banner]"));
  for (const chip of scope.querySelectorAll<HTMLElement>("button[data-menu]")) add(`chip:${chip.dataset.menu}`, chip);
  const rows = [...scope.querySelectorAll(ROWS)].slice(-3);
  rows.forEach((row, index) => add(`row-${rows.length - index}`, row));
  return boxes;
}

/// Whether the live page lays out what the copy shows: every part the copy has (the bottom stack, the
/// composer and its chips, the header, the last rows) is in the live page within a pixel. The swap waits
/// for it (live.ts `swapChatSnapshot`): a bottom ask the host answers after the chat is read (a folder's
/// trust) came into the stack 50 ms after the swap and drew every row up by its height.
export function liveMatchesCopy(copy: ParentNode, live: ParentNode): boolean {
  const a = boxesIn(copy);
  const b = boxesIn(live);
  for (const [name, x] of Object.entries(a)) {
    const y = b[name];
    if (!y || Math.max(Math.abs(x.x - y.x), Math.abs(x.y - y.y), Math.abs(x.w - y.w), Math.abs(x.h - y.h)) > 1)
      return false;
  }
  return true;
}

export type SwapDiff = {
  /// Elements whose box differs by more than a pixel, or that only one side has.
  changed: Record<string, { copy?: Box; live?: Box }>;
  copyStack: string[];
  liveStack: string[];
  /// How long the swap waited for the live page to match the copy (``liveMatchesCopy``), and whether it did.
  held_ms?: number;
  matched?: boolean;
  /// The live stack's height changes after the swap, ms after it.
  after: { at_ms: number; h: number; parts: string[] }[];
};

let last: SwapDiff | undefined;

export function swapDiff(): SwapDiff | undefined {
  return last;
}

/// Reads both sides; called in the swap's task before the copy goes.
export function noteSwap(
  copy: ParentNode,
  live: ParentNode,
  view: Window,
  held?: { ms: number; matched: boolean },
): void {
  try {
    const a = boxesIn(copy);
    const b = boxesIn(live);
    const changed: SwapDiff["changed"] = {};
    for (const name of new Set([...Object.keys(a), ...Object.keys(b)])) {
      const x = a[name];
      const y = b[name];
      const moved =
        !x || !y || Math.max(Math.abs(x.x - y.x), Math.abs(x.y - y.y), Math.abs(x.w - y.w), Math.abs(x.h - y.h)) > 1;
      if (moved) changed[name] = { ...(x ? { copy: x } : {}), ...(y ? { live: y } : {}) };
    }
    const dock = live.querySelector(".acpmux-dock");
    const diff: SwapDiff = {
      changed,
      copyStack: stackParts(copy.querySelector(".acpmux-dock")),
      liveStack: stackParts(dock),
      ...(held ? { held_ms: Math.round(held.ms), matched: held.matched } : {}),
      after: [],
    };
    last = diff;
    if (!dock || typeof ResizeObserver !== "function") return;
    const start = view.performance.now();
    let height = Math.round(dock.getBoundingClientRect().height);
    const observer = new ResizeObserver(() => {
      const at = view.performance.now() - start;
      const now = Math.round(dock.getBoundingClientRect().height);
      if (at > AFTER_MS || diff.after.length >= MAX_CHANGES) {
        observer.disconnect();
        return;
      }
      if (now === height) return;
      height = now;
      diff.after.push({ at_ms: Math.round(at), h: now, parts: stackParts(dock) });
    });
    observer.observe(dock);
    view.setTimeout(() => observer.disconnect(), AFTER_MS);
  } catch {
    // A report only: the swap goes on.
  }
}
