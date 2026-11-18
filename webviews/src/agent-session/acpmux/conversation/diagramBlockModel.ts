import { chartSpec } from "./chartSpec";

const CHART_LANGUAGES = new Set(["vega-lite", "vega"]);

/// Whether a finished fence draws as a chart or diagram: mermaid with source, a chart language and a
/// JSON object spec, or a ```chart fence whose small JSON compiles to a chart (chartSpec.ts).
export function isChart(lang: string, code: string): boolean {
  const language = lang.toLowerCase();
  if (language === "mermaid") return code.trim() !== "";
  if (language === "chart") return chartSpec(code) !== undefined;
  if (!CHART_LANGUAGES.has(language)) return false;
  try {
    const spec: unknown = JSON.parse(code);
    return typeof spec === "object" && spec !== null && !Array.isArray(spec);
  } catch {
    return false;
  }
}

/// The whole chart's size in CSS px, axes, legend, title and padding included.
export type ChartBox = { width: number; height: number };

/// Autosize that makes a Vega view's `width` and `height` the whole drawing's, padding included: the
/// SVG is then exactly that size, known from the spec before Vega loads.
export const FIT_AUTOSIZE = { type: "fit", contains: "padding" } as const;

/// Views Vega-Lite can fit to a size: a single or a layered view (it ignores `fit` for a facet, a
/// concat or a repeat, which then draw at their own size).
const UNFITTABLE = ["facet", "concat", "hconcat", "vconcat", "repeat"];

const size = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined);

const fits = (autosize: unknown) =>
  autosize !== null &&
  typeof autosize === "object" &&
  (autosize as { type?: unknown }).type === "fit" &&
  (autosize as { contains?: unknown }).contains === "padding";

/**
 * The spec a Vega or Vega-Lite fence draws, and the box it draws into, when the spec names it: a
 * numeric `width` and `height` with autosize `fit` to its padding. A Vega-Lite single or layered view
 * that names a size and no autosize gets that autosize, so the size it names is the chart's whole
 * box and the block reserves it before Vega loads: the reply row mounts at its final height and
 * nothing under or over it moves when the chart draws (schemas/layout-motion/contract.json). Any
 * other spec draws as written, at the size it lays out at.
 */
export function sizedChart(mode: "vega" | "vega-lite", source: string): { spec: string; box?: ChartBox } {
  let spec: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(source);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return { spec: source };
    spec = parsed as Record<string, unknown>;
  } catch {
    return { spec: source };
  }
  const width = size(spec.width);
  const height = size(spec.height);
  if (width === undefined || height === undefined) return { spec: source };
  if (fits(spec.autosize)) return { spec: source, box: { width, height } };
  if (mode !== "vega-lite" || spec.autosize !== undefined || UNFITTABLE.some((key) => key in spec))
    return { spec: source };
  return { spec: JSON.stringify({ ...spec, autosize: FIT_AUTOSIZE }), box: { width, height } };
}
