
import type { IconLayer } from "./types";
/// Generous mask bounds: row icons crop the grid and draw with overflow visible.
const MASK_BOUNDS = { x: -24, y: -24, width: 72, height: 72 } as const;

const strokeProps = (layer: IconLayer, strokeWidth?: number) => ({
  strokeWidth: strokeWidth ?? layer.w ?? 1.5,
  strokeLinecap: layer.cap ?? "round",
  strokeLinejoin: layer.join ?? "round",
  strokeDasharray: layer.dash?.join(" "),
  strokeDashoffset: layer.dashPhase,
});
