import { useId } from "react";

/// Auto's glyph (Leo, 2026-11-23: "the half and half computer/cloud icon with the angled slash"): a
/// laptop on the left and a cloud on the right, split by one angled slash. Drawn on the 24 grid of
/// design/icons/SPEC.md (1.5 stroke, 15 or more units across, ink centred on 12,12; the geometry holds
/// the size, no wrapping scale). The two halves are the same two drawings as This Mac and Cloud, each cut
/// at the slash with a clip, and a gap on either side of the slash.
export interface AutoGlyph {
  /// The slash's lean from vertical, in degrees (the cloud side leans right).
  readonly angle: number;
  /// The clear space either side of the slash, in 24-grid units (both halves keep off it).
  readonly gap: number;
}

/// Shipped: 22 degrees, 2.5 units of gap (the gallery compares the others).
export const AUTO_GLYPH: AutoGlyph = { angle: 22, gap: 2.5 };

const LAPTOP = "M3.25 6.25h9.5a1 1 0 0 1 1 1v7.5h-11.5v-7.5a1 1 0 0 1 1-1ZM1.75 17.75h14.5";
const CLOUD = "M13.5 17.75h5.2a3.3 3.3 0 0 0 .5-6.56A4.6 4.6 0 0 0 10.5 10a3.9 3.9 0 0 0 3 7.75Z";

export function AutoIcon({ glyph = AUTO_GLYPH }: { glyph?: AutoGlyph | undefined }) {
  const id = useId().replace(/:/g, "");
  const radians = (glyph.angle * Math.PI) / 180;
  // Along the slash, and across it (towards the cloud).
  const along = { x: Math.sin(radians), y: -Math.cos(radians) };
  const across = { x: Math.cos(radians), y: Math.sin(radians) };
  const half = (side: -1 | 1) => {
    const edge = (side * glyph.gap) / 2;
    const point = (long: number, wide: number) =>
      `${(12 + along.x * long + across.x * wide).toFixed(2)},${(12 + along.y * long + across.y * wide).toFixed(2)}`;
    return [point(-30, edge), point(30, edge), point(30, edge + side * 30), point(-30, edge + side * 30)].join(" ");
  };
  const slash = (long: number) =>
    `M${(12 - along.x * long).toFixed(2)} ${(12 - along.y * long).toFixed(2)}L${(12 + along.x * long).toFixed(2)} ${(12 + along.y * long).toFixed(2)}`;
  return (
    <svg
      className="acpmux-icon acpmux-location-icon acpmux-env-icon acpmux-auto-icon ui-ghost-icon"
      data-kind="auto"
      width={16}
      height={16}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <defs>
        <clipPath id={`${id}-laptop`}>
          <polygon points={half(-1)} />
        </clipPath>
        <clipPath id={`${id}-cloud`}>
          <polygon points={half(1)} />
        </clipPath>
      </defs>
      <path d={LAPTOP} clipPath={`url(#${id}-laptop)`} />
      <path d={CLOUD} clipPath={`url(#${id}-cloud)`} />
      <path d={slash(8)} />
    </svg>
  );
}
