// Where the jump stack stands (jumpPlace.experiment.ts, jumpPlace.css): the arm, turned to the side
// the tucked hat's handle leaves free, so the stack and the handle never share a column.
import type { TrayHandleSide } from "./chatDisplay";
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
