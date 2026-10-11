import type { ReactNode } from "react";
import type { IconLayer } from "./types";

/// The theme accent, falling back to the text color where the pane sets none.
export const ACCENT_COLOR = "var(--agent-accent, currentColor)";

/// Generous mask bounds: row icons crop the grid and draw with overflow visible.
const MASK_BOUNDS = { x: -24, y: -24, width: 72, height: 72 } as const;

const strokeProps = (layer: IconLayer) => ({
  strokeWidth: layer.w ?? 1.5,
  strokeLinecap: layer.cap ?? "round",
  strokeLinejoin: layer.join ?? "round",
  strokeDasharray: layer.dash?.join(" "),
  strokeDashoffset: layer.dashPhase,
});

function shape(layer: IconLayer, key: number): ReactNode {
  const color = layer.accent ? ACCENT_COLOR : "currentColor";
  switch (layer.op) {
    case "fill":
      return <path key={key} d={layer.d} fill={color} opacity={layer.alpha} />;
    case "stroke":
      return <path key={key} d={layer.d} fill="none" stroke={color} opacity={layer.alpha} {...strokeProps(layer)} />;
    case "clearFill":
      return <path key={key} d={layer.d} fill="black" />;
    case "clearStroke":
      return <path key={key} d={layer.d} fill="none" stroke="black" {...strokeProps(layer)} />;
  }
}

const isClear = (layer: IconLayer) => layer.op === "clearFill" || layer.op === "clearStroke";

/// The SVG children for a flat layer list. A run of clear layers erases only what came before it:
/// everything drawn so far moves into a group masked by a white rect with the clear shapes in black,
/// and later layers draw outside that mask. `idPrefix` keeps mask ids unique per icon instance.
export function iconLayers(layers: IconLayer[], idPrefix: string): ReactNode[] {
  let drawn: ReactNode[] = [];
  let masks = 0;
  for (let index = 0; index < layers.length; index += 1) {
    if (!isClear(layers[index])) {
      drawn.push(shape(layers[index], index));
      continue;
    }
    const clears: ReactNode[] = [];
    while (index < layers.length && isClear(layers[index])) {
      clears.push(shape(layers[index], index));
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
