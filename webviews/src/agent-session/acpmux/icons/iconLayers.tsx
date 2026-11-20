import type { ReactNode } from "react";
import type { IconLayer } from "./types";

/// The theme accent, falling back to the text color where the pane sets none.
export const ACCENT_COLOR = "var(--agent-accent, currentColor)";

/// Generous mask bounds: row icons crop the grid and draw with overflow visible.
const MASK_BOUNDS = { x: -24, y: -24, width: 72, height: 72 } as const;

const strokeProps = (layer: IconLayer, strokeWidth?: number) => ({
  strokeWidth: strokeWidth ?? layer.w ?? 1.5,
  strokeLinecap: layer.cap ?? "round",
  strokeLinejoin: layer.join ?? "round",
  strokeDasharray: layer.dash?.join(" "),
  strokeDashoffset: layer.dashPhase,
});

/// A per-layer override of the color: `paint(index, count)` gets a drawing layer's place among the
/// icon's drawing layers (clear layers do not count) and answers its color and opacity, or undefined
/// to keep the layer as authored (the symbol rendering modes of app scenes).
export type IconLayerPaint = (index: number, count: number) => { color?: string; opacity?: number } | undefined;

function shape(
  layer: IconLayer,
  key: number,
  strokeWidth?: number,
  paint?: { color?: string; opacity?: number },
): ReactNode {
  const color = paint?.color ?? (layer.accent ? ACCENT_COLOR : "currentColor");
  const opacity = paint?.opacity === undefined ? layer.alpha : paint.opacity * (layer.alpha ?? 1);
  switch (layer.op) {
    case "fill":
      return <path key={key} d={layer.d} fill={color} fillRule={layer.rule} opacity={opacity} />;
    case "stroke":
      return (
        <path key={key} d={layer.d} fill="none" stroke={color} opacity={opacity} {...strokeProps(layer, strokeWidth)} />
      );
    case "clearFill":
      return <path key={key} d={layer.d} fill="black" fillRule={layer.rule} />;
    case "clearStroke":
      return <path key={key} d={layer.d} fill="none" stroke="black" {...strokeProps(layer, strokeWidth)} />;
  }
}

const isClear = (layer: IconLayer) => layer.op === "clearFill" || layer.op === "clearStroke";

/// The SVG children for a flat layer list. A run of clear layers erases only what came before it:
/// everything drawn so far moves into a group masked by a white rect with the clear shapes in black,
/// and later layers draw outside that mask. `idPrefix` keeps mask ids unique per icon instance;
/// `paint` recolors drawing layers (``IconLayerPaint``).
export function iconLayers(
  layers: IconLayer[],
  idPrefix: string,
  strokeWidth?: number,
  paint?: IconLayerPaint,
): ReactNode[] {
  let drawn: ReactNode[] = [];
  let masks = 0;
  const authoredStroke = layers.find((layer) => layer.op === "stroke")?.w ?? 1.5;
  const drawCount = paint ? layers.filter((layer) => !isClear(layer)).length : 0;
  let drawIndex = 0;
  for (let index = 0; index < layers.length; index += 1) {
    if (!isClear(layers[index])) {
      drawn.push(shape(layers[index], index, strokeWidth, paint?.(drawIndex, drawCount)));
      drawIndex += 1;
      continue;
    }
    const clears: ReactNode[] = [];
    while (index < layers.length && isClear(layers[index])) {
      const layer = layers[index];
      // Keep knockout gaps proportional when normalizing the visible line.
      const clearWidth =
        strokeWidth === undefined ? undefined : (strokeWidth * (layer.w ?? authoredStroke)) / authoredStroke;
      clears.push(shape(layer, index, clearWidth));
      index += 1;
    }
    index -= 1;
    const id = `${idPrefix}-m${masks}`;
    masks += 1;
    drawn = [
      <mask key={`${id}-mask`} id={id} maskUnits="userSpaceOnUse" {...MASK_BOUNDS}>
        <rect {...MASK_BOUNDS} fill="white" />
        {clears}
      </mask>,
      <g key={`${id}-group`} mask={`url(#${id})`}>
        {drawn}
      </g>,
    ];
  }
  return drawn;
}
