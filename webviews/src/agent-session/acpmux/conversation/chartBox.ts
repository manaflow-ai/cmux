/// The axes, labels and padding Vega draws around a spec's plot (px): the box a chart is drawn in is
/// about its plot plus this, so the frame keeps that box from the first frame and the chart draws
/// into it (the library loads and draws after the reply is on screen).
const CHART_FRAME = { width: 56, height: 52 };

/// The box a Vega or Vega-Lite spec with a fixed plot size draws in (its own width and height plus
/// the axes'), or none for a spec that sizes itself (no numbers, "container", a source that is not JSON).
export function chartBox(spec: string): { width: number; height: number } | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(spec);
  } catch {
    return undefined;
  }
  if (!parsed || typeof parsed !== "object") return undefined;
  const { width, height } = parsed as { width?: unknown; height?: unknown };
  if (typeof width !== "number" || typeof height !== "number" || !(width > 0) || !(height > 0)) return undefined;
  return { width: Math.round(width + CHART_FRAME.width), height: Math.round(height + CHART_FRAME.height) };
}
