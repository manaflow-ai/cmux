// Which way the open hat's list goes from its header (Leo, 2026-11-27, standup on CMUX-863: the hat
// opens toward free space). Under the header when the list fits there; above it when it fits there
// instead (a hat at the transcript's end with the pane's bottom edge right under it); neither, the
// side with more room, so the list scrolls in the larger part. The bottom stack's hat (`tray`
// placement) sits on the composer and grows into the transcript already: this only turns the hat
// placed after the latest message.
export type HatOpens = "down" | "up";

export function hatOpens(room: { above: number; below: number; list: number }): HatOpens {
  const { above, below, list } = room;
  if (list <= below) return "down";
  if (list <= above) return "up";
  return above > below ? "up" : "down";
}

/// The room around `head` inside the nearest ancestor that scrolls (else the window).
export function roomAround(head: HTMLElement): { above: number; below: number } {
  const box = head.getBoundingClientRect();
  let edge: { top: number; bottom: number } = { top: 0, bottom: head.ownerDocument.defaultView?.innerHeight ?? 0 };
  for (let node = head.parentElement; node; node = node.parentElement) {
    const overflow = getComputedStyle(node).overflowY;
    if (overflow === "auto" || overflow === "scroll") {
      edge = node.getBoundingClientRect();
      break;
    }
  }
  return { above: Math.max(0, box.top - edge.top), below: Math.max(0, edge.bottom - box.bottom) };
}
