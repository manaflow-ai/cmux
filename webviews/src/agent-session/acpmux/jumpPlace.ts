// Where the jump stack stands (jumpPlace.experiment.ts, jumpPlace.css): the arm, turned to the side
// the tucked hat's handle leaves free, so the stack and the handle never share a column.
import type { TrayHandleSide } from "./chatDisplay";
import type { HatPillPlace } from "./hatPillPlace.experiment";
import type { JumpLatestPlace } from "./jumpPlace.experiment";

export type JumpSide = "start" | "end";

/// The stack's side for `.acpmux-main[data-jump-side]`, or undefined for the centered arm. A side arm
/// keeps its side unless the hat's handle stands there (`agentPane.display.trayHandle` left or right:
/// the tucked hat's pull tab, and the open hat's tuck chevron on its top edge), and then takes the
/// other one; the middle handle leaves both sides free.
export function jumpSide(place: JumpLatestPlace, handle: TrayHandleSide): JumpSide | undefined {
  if (place === "center") return undefined;
  const side: JumpSide = place === "start" ? "start" : "end";
  if (side === "end" && handle === "right") return "start";
  if (side === "start" && handle === "left") return "end";
  return side;
}

/// Where the hat's handle (the tucked pill and the open hat's tuck chevron) stands along the
/// composer's top edge: the person's `agentPane.display.trayHandle`, except that the middle handle
/// moves aside while the jump stack holds the center line (Leo, 2026-11-22: "the composer hat hidden
/// bit was the one to move to the right. or left."), to the side the `hat-pill-place` arm names. The
/// side is fixed per chat view, never per frame, so neither control moves while a reply streams or
/// the disc fades in and out.
export function hatSide(jump: JumpLatestPlace, handle: TrayHandleSide, pill: HatPillPlace): TrayHandleSide {
  if (handle !== "middle" || jump !== "center" || pill === "middle") return handle;
  return pill === "start" ? "left" : "right";
}
