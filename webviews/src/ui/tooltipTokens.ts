// Tooltip geometry follows the shared grid and the host's chrome interface scale.
import designScale from "../../../schemas/design-scale/design-scale.json";

export const UI_TOOLTIP_GAP = designScale.spacing.steps[0]!.px;
export const UI_TOOLTIP_EDGE = UI_TOOLTIP_GAP;
export const UI_TOOLTIP_MAX_WIDTH = UI_TOOLTIP_GAP * 80;

export function tooltipScale(doc: Document): number {
  const value = Number(
    doc.defaultView?.getComputedStyle(doc.documentElement).getPropertyValue("--cmux-interface-scale"),
  );
  return Number.isFinite(value) && value > 0 ? value : 1;
}

// Base UI calls this only while placing an open tooltip; no observer or idle work.
export function tooltipGap(): number {
  return UI_TOOLTIP_GAP * (typeof document === "undefined" ? 1 : tooltipScale(document));
}
