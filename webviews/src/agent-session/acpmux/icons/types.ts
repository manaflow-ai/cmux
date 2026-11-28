/// The flattened icon pack scripts/icons/build_pack.py writes (cmuxIcons.json). Every drawing sits on
/// a 24-unit grid and uses only absolute M, L, C and Z, so the pane draws it as plain SVG paths.

/// What a layer does: draw (stroke, fill) or erase what earlier layers drew (clearFill, clearStroke).
export type IconLayerOp = "stroke" | "fill" | "clearFill" | "clearStroke";

export interface IconLayer {
  d: string;
  op: IconLayerOp;
  /// Stroke width in grid units (stroke ops).
  w?: number;
  /// 0-1 opacity; absent means opaque.
  alpha?: number;
  /// Dash pattern and offset in grid units.
  dash?: number[];
  dashPhase?: number;
  /// Absent means round.
  cap?: "butt" | "round" | "square";
  /// Absent means round.
  join?: "miter" | "round" | "bevel";
  /// Drawn in the theme accent instead of the text color (Cat drawings only).
  accent?: boolean;
}

export interface IconDrawing {
  line: IconLayer[];
  solid: IconLayer[];
  cat?: IconLayer[];
}

export interface IconPack {
  id: string;
  version: number;
  grid: number;
  icons: Record<string, IconDrawing>;
}

/// Line is the resting form; Solid marks the selected one.
export type IconStyle = "line" | "solid";

/// Cat swaps in an icon's Cat drawing where it has one.
export type IconAccent = "none" | "cat";
