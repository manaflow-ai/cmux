import type { Translate } from "../i18n";
import type { PlaceState } from "../place/placeModel";
import { placeName } from "../place/placeText";

/// Where the chat runs now, in the place lane's own words: the move in flight, else the place the
/// app reports. A pin that already names its place (Only on This Mac, running on this Mac) says
/// nothing twice.
export function placementLine(place: PlaceState, t: Translate): string | undefined {
  // A hybrid start's name already says where the chat is (Starting Here, Moving to Cloud, Running
  // Here); once in Cloud, the line names the machine.
  if (place.start) return place.start.cloud === "live" ? place.cloudName : undefined;
  if (place.move?.state === "moving") return t("place.faceMoving", { to: place.move.to });
  if (place.mode === "local" && place.at === "local") return undefined;
  if (place.mode === "cloud" && place.at === "cloud" && !place.cloudName) return undefined;
  return placeName(place, t);
}
