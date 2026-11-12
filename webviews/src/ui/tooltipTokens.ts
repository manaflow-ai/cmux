// Tooltip geometry follows the shared grid and the host's chrome interface scale.
import designScale from "../../../schemas/design-scale/design-scale.json";
import { interfaceScale } from "./interfaceScale";

export const UI_TOOLTIP_GAP = designScale.spacing.steps[0]!.px;
export const UI_TOOLTIP_EDGE = UI_TOOLTIP_GAP;
export const UI_TOOLTIP_MAX_WIDTH = UI_TOOLTIP_GAP * 80;

/** The interface scale the tooltip follows: the one every floating surface reads (interfaceScale.ts). */
export function tooltipScale(doc: Document): number {
  return interfaceScale(doc.defaultView ?? null, doc.documentElement);
}

// Base UI calls this only while placing an open tooltip; no observer or idle work.
export function tooltipGap(): number {
  return UI_TOOLTIP_GAP * (typeof document === "undefined" ? 1 : tooltipScale(document));
}
