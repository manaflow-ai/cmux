import type { Page } from "playwright";

export type IconCenterCase = {
  family: string;
  /** Elements whose glyphs are being checked. */
  control: string;
  /** The glyph box inside each control. */
  glyph: string;
  /** Optional ancestor used to assert that controls in one row share a center line. */
  row?: string;
  /** Optional text or row reference that the control must share a vertical center with. */
  reference?: string;
  /** Ancestor containing `reference`; defaults to the control's parent. */
  referenceRoot?: string;
  /** Menu rows intentionally share a vertical line while their icon sits in the leading column. */
  axis?: "xy" | "y";
};

export type IconCenterObservation = {
  family: string;
  control: string;
  glyph: string;
  centerDeltaX: number;
  centerDeltaY: number;
  referenceDeltaY?: number;
  rowCenterDelta?: number;
};

export type IconCenterViolation = IconCenterObservation & { kind: "glyph" | "reference" | "row" | "empty" };

const CENTER_TOLERANCE = 0.5;

/**
 * Measure icon boxes in a live Chromium page. The glyph is the rendered SVG's ink bounds, transformed
 * into screen coordinates with its CTM. A reference is used for controls that float over a text line,
 * such as a corner code toolbar.
 */
export async function auditIconCentering(
  page: Page,
  cases: readonly IconCenterCase[],
): Promise<{ observations: IconCenterObservation[]; violations: IconCenterViolation[] }> {
  return page.evaluate(
    ({ cases, tolerance }) => {
      type Rect = { left: number; right: number; top: number; bottom: number; width: number; height: number };
      type Observation = {
        family: string;
        control: string;
        glyph: string;
        centerDeltaX: number;
        centerDeltaY: number;
        referenceDeltaY?: number;
        rowCenterDelta?: number;
      };
      type Violation = Observation & { kind: "glyph" | "reference" | "row" | "empty" };
      const center = (rect: Rect) => ({ x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 });
      const visible = (rect: Rect) => rect.width > 0 && rect.height > 0;
      const label = (element: Element) => {
        const aria = element.getAttribute("aria-label");
        if (aria) return aria;
        const icon = element.getAttribute("data-icon");
        if (icon) return icon;
        return String(element.className) || element.tagName;
      };
      const inkRect = (element: Element): Rect | null => {
        if (!(element instanceof SVGGraphicsElement)) {
          const rect = element.getBoundingClientRect();
          return visible(rect) ? rect : null;
        }
        try {
          const box = element.getBBox();
          const matrix = element.getScreenCTM();
          if (!matrix) return null;
          const points = [
            new DOMPoint(box.x, box.y),
            new DOMPoint(box.x + box.width, box.y),
            new DOMPoint(box.x, box.y + box.height),
            new DOMPoint(box.x + box.width, box.y + box.height),
          ].map((point) => point.matrixTransform(matrix));
          const left = Math.min(...points.map((point) => point.x));
          const right = Math.max(...points.map((point) => point.x));
          const top = Math.min(...points.map((point) => point.y));
          const bottom = Math.max(...points.map((point) => point.y));
          return { left, right, top, bottom, width: right - left, height: bottom - top };
        } catch {
          return null;
        }
      };
      const observations: Observation[] = [];
      const violations: Violation[] = [];
      for (const item of cases) {
        const controls = [...document.querySelectorAll<HTMLElement>(item.control)].filter((element) =>
          visible(element.getBoundingClientRect()),
        );
        if (controls.length === 0) {
          violations.push({
            family: item.family,
            control: item.control,
            glyph: "",
            centerDeltaX: 0,
            centerDeltaY: 0,
            kind: "empty",
          });
          continue;
        }
        const rows = new Map<Element, { centerY: number; controls: HTMLElement[] }>();
        const observationByControl = new Map<HTMLElement, Observation>();
        for (const control of controls) {
          const glyph = control.querySelector<Element>(item.glyph);
          const glyphRect = glyph ? inkRect(glyph) : null;
          if (!glyph || !glyphRect || !visible(glyphRect)) {
            violations.push({
              family: item.family,
              control: label(control),
              glyph: "",
              centerDeltaX: 0,
              centerDeltaY: 0,
              kind: "empty",
            });
            continue;
          }
          const controlRect = control.getBoundingClientRect();
          const controlCenter = center(controlRect);
          const glyphCenter = center(glyphRect);
          const centerDeltaX = Math.abs(glyphCenter.x - controlCenter.x);
          const centerDeltaY = Math.abs(glyphCenter.y - controlCenter.y);
          const observation: Observation = {
            family: item.family,
            control: label(control),
            glyph:
              (glyph.getAttribute("data-icon") ??
                (glyph instanceof SVGElement ? glyph.className.baseVal : glyph.className)) ||
              glyph.tagName,
            centerDeltaX,
            centerDeltaY,
          };
          observationByControl.set(control, observation);
          if (item.axis !== "y" && (centerDeltaX > tolerance || centerDeltaY > tolerance))
            violations.push({ ...observation, kind: "glyph" });
          if (item.axis === "y" && centerDeltaY > tolerance) violations.push({ ...observation, kind: "glyph" });
          if (item.reference) {
            const root = item.referenceRoot ? control.closest(item.referenceRoot) : control.parentElement;
            const reference = root?.querySelector<HTMLElement>(item.reference);
            if (reference) {
              const referenceCenter = center(reference.getBoundingClientRect());
              observation.referenceDeltaY = Math.abs(glyphCenter.y - referenceCenter.y);
              if (observation.referenceDeltaY > tolerance) violations.push({ ...observation, kind: "reference" });
            } else {
              violations.push({ ...observation, kind: "empty" });
            }
          }
          observations.push(observation);
          if (item.row) {
            const row = control.closest(item.row);
            if (row) {
              const rowEntry = rows.get(row);
              if (rowEntry) rowEntry.controls.push(control);
              else rows.set(row, { centerY: controlCenter.y, controls: [control] });
            }
          }
        }
        for (const row of rows.values()) {
          for (const control of row.controls) {
            const delta = Math.abs(center(control.getBoundingClientRect()).y - row.centerY);
            if (delta <= tolerance) continue;
            const observation = observationByControl.get(control);
            if (observation) violations.push({ ...observation, rowCenterDelta: delta, kind: "row" });
          }
        }
      }
      return { observations, violations };
    },
    { cases, tolerance: CENTER_TOLERANCE },
  );
}
