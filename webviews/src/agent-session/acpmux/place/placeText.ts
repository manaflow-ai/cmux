import type { Translate } from "../i18n";
import type { PlaceState } from "./placeModel";

/// The place's name: the chat's own VM when known.
export function cloudLabel(place: PlaceState, t: Translate): string {
  return place.cloudName ?? t("place.cloud");
}

export function placeName(place: PlaceState, t: Translate): string {
  return place.at === "cloud" ? cloudLabel(place, t) : t("place.thisMac");
}

/// The control's face: the choice, and for Auto where it runs now.
export function faceText(place: PlaceState, t: Translate): string {
  if (place.move?.state === "moving") return t("place.faceMoving", { to: place.move.to });
  if (place.mode === "auto") return t(place.at === "cloud" ? "place.faceAutoCloud" : "place.faceAutoLocal");
  return t(place.mode === "cloud" ? "place.faceCloud" : "place.faceLocal");
}
