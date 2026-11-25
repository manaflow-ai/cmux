// A drag that moves a harness tab along the model picker's rail (QuickModelColumns.tsx,
// QuickModelMenu.tsx; Lucas 2026-11-25: "make it so that the harnesses are re-arrangeable in the
// model picker (excluding star)"). A press on a tab that moves past a few pixels lifts it: it follows
// the pointer along the rail, the tabs it passes slide aside, and the rail scrolls when the pointer
// nears its edge. Release drops it there (`onDrop`, the new place among the movable tabs); Escape,
// or a release where it started, puts it back. The drag moves the tabs with transforms on the DOM
// itself, read once at its start, so a move renders nothing; only the drop changes React state.
// Starred is never movable and never moves: it carries no `data-movable`.
import type { PointerEvent as ReactPointerEvent } from "react";

/// How far a press moves, in px, before it is a drag rather than a click.
const DRAG_START = 4;
/// How near the rail's visible edge the pointer scrolls it, in px, and how fast at the edge (px per frame).
const EDGE = 28;
const EDGE_SPEED = 10;

/** Starts a possible drag of the movable tab the pointer pressed. `axis` is the rail's direction. */
export function startRailDrag(
  event: ReactPointerEvent<HTMLElement>,
  axis: "x" | "y",
  onDrop: (key: string, to: number) => void,
): void {
  if (event.button !== 0 || event.ctrlKey) return;
  const tab = event.currentTarget;
  const key = tab.dataset.tabKey;
  const rail = tab.parentElement;
  if (!key || !rail || !tab.hasAttribute("data-movable")) return;
  const tabs = [...rail.children].filter((child): child is HTMLElement => child.hasAttribute("data-movable"));
  const from = tabs.indexOf(tab);
  if (from < 0) return;
  const pointer = event.pointerId;
  const doc = tab.ownerDocument;
  const win = doc.defaultView;
  if (!win) return;
  // Every read before any write: the tabs' places along the rail in its scrolled content.
  const y = axis === "y";
  const box = rail.getBoundingClientRect();
  const scrollAt = () => (y ? rail.scrollTop : rail.scrollLeft);
  const startScroll = scrollAt();
  const spans = tabs.map((element) => {
    const rect = element.getBoundingClientRect();
    const start = (y ? rect.top - box.top : rect.left - box.left) + startScroll;
    return { start, size: y ? rect.height : rect.width };
  });
  const centers = spans.map((span) => span.start + span.size / 2);
  // The step a passed tab slides: the lifted tab's size and the gap after it.
  const gap = spans.length > 1 ? Math.max(0, spans[1]!.start - (spans[0]!.start + spans[0]!.size)) : 0;
  const step = spans[from]!.size + gap;
  const origin = y ? event.clientY : event.clientX;
  let pointerAt = origin;
  let lifted = false;
  let to = from;
  let frame = 0;

  const place = () => {
    const moved = pointerAt - origin + (scrollAt() - startScroll);
    // The lifted tab's center stays between the first and the last movable tab's.
    const center = Math.min(centers.at(-1)!, Math.max(centers[0]!, centers[from]! + moved));
    const offset = center - centers[from]!;
    let nearest = 0;
    for (let index = 1; index < centers.length; index++)
      if (Math.abs(centers[index]! - center) < Math.abs(centers[nearest]! - center)) nearest = index;
    to = nearest;
    const shift = (px: number) => (y ? `translate3d(0, ${px}px, 0)` : `translate3d(${px}px, 0, 0)`);
    tab.style.transform = shift(offset);
    tabs.forEach((element, index) => {
      if (index === from) return;
      const by = from < to && index > from && index <= to ? -step : to < from && index >= to && index < from ? step : 0;
      element.style.transform = by ? shift(by) : "";
    });
  };

  // Near the rail's edge, scroll it each frame while the pointer stays there.
  const scrollEdge = () => {
    frame = 0;
    if (!lifted) return;
    const near = pointerAt - (y ? box.top : box.left);
    const length = y ? box.height : box.width;
    const by =
      near < EDGE
        ? -EDGE_SPEED * (1 - near / EDGE)
        : near > length - EDGE
          ? EDGE_SPEED * (1 - (length - near) / EDGE)
          : 0;
    if (!by) return;
    if (y) rail.scrollTop += by;
    else rail.scrollLeft += by;
    place();
    frame = win.requestAnimationFrame(scrollEdge);
  };

  const finish = (drop: boolean) => {
    win.removeEventListener("pointermove", move, true);
    win.removeEventListener("pointerup", up, true);
    win.removeEventListener("pointercancel", cancel, true);
    win.removeEventListener("keydown", key_, true);
    if (frame) win.cancelAnimationFrame(frame);
    if (!lifted) return;
    // The click the release makes on the tab is the drag's, never a pick of the tab. The next click
    // anywhere ends this guard; one elsewhere goes on as usual.
    win.addEventListener(
      "click",
      (click) => {
        if (click.target instanceof win.Node && tab.contains(click.target)) {
          click.preventDefault();
          click.stopPropagation();
        }
      },
      { capture: true, once: true },
    );
    rail.removeAttribute("data-reordering");
    tab.removeAttribute("data-lifted");
    for (const element of tabs) element.style.transform = "";
    if (drop && to !== from) onDrop(key, to);
  };
  const move = (next: PointerEvent) => {
    if (next.pointerId !== pointer) return;
    pointerAt = y ? next.clientY : next.clientX;
    if (!lifted) {
      if (Math.abs(pointerAt - origin) < DRAG_START) return;
      lifted = true;
      rail.setAttribute("data-reordering", "");
      tab.setAttribute("data-lifted", "");
    }
    next.preventDefault();
    place();
    if (!frame) frame = win.requestAnimationFrame(scrollEdge);
  };
  const up = (next: PointerEvent) => {
    if (next.pointerId === pointer) finish(true);
  };
  const cancel = (next: PointerEvent) => {
    if (next.pointerId === pointer) finish(false);
  };
  const key_ = (next: KeyboardEvent) => {
    if (next.key !== "Escape" || !lifted) return;
    // The menu's own Escape (close) waits: this one only puts the tab back.
    next.preventDefault();
    next.stopPropagation();
    finish(false);
  };
  win.addEventListener("pointermove", move, true);
  win.addEventListener("pointerup", up, true);
  win.addEventListener("pointercancel", cancel, true);
  win.addEventListener("keydown", key_, true);
}
