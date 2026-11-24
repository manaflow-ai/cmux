// The restyled tooltips and hover cards (`experiments.hoverLook`, off by default; ui/hoverLook.css):
// while the switch is on, `<html>` carries the arm in data-hover-look, so every tooltip and hover
// card on the page changes in the same frame, and the App's glass stops drawing under them
// (pageDrawsHover, read by ui/glass/hostGlass.ts) so the page's own paint is what shows.
import { experimentArm } from "../experiments/experiment";
import { experimentSwitchOn, subscribeExperimentSwitches } from "../experiments/switches";
import { HOVER_LOOK_ATTRIBUTE, HOVER_LOOK_SURFACES, HOVER_LOOK_SWITCH, hoverLook } from "./hoverLook.experiment";

/// Sets or clears the root attribute from the switch now.
export function applyHoverLook(doc: Document, on: boolean = experimentSwitchOn(HOVER_LOOK_SWITCH)): void {
  const root = doc.documentElement;
  if (on) root.setAttribute(HOVER_LOOK_ATTRIBUTE, experimentArm(hoverLook));
  else root.removeAttribute(HOVER_LOOK_ATTRIBUTE);
}

/// Keeps the root attribute in step with the switch; returns the unsubscribe.
export function installHoverLook(doc: Document): () => void {
  applyHoverLook(doc);
  return subscribeExperimentSwitches(() => applyHoverLook(doc));
}

/// Whether the page paints this hover surface itself (the restyle is on), so the App lays no glass
/// under it.
export function pageDrawsHover(element: Element): boolean {
  return (
    element.ownerDocument.documentElement.hasAttribute(HOVER_LOOK_ATTRIBUTE) && element.matches(HOVER_LOOK_SURFACES)
  );
}
