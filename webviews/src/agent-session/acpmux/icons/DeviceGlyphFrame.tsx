import type { CSSProperties, ReactNode } from "react";

/// The frame a device glyph draws in (ui/DeviceGlyph.tsx): the one inline vector root the device
/// glyphs need, kept in the icons module so nothing outside it draws its own icon root
/// (iconRegistry.test.ts (b)). Moved here unchanged: same attributes, same order, same look.
export function DeviceGlyphFrame({
  className,
  kind,
  symbol,
  offline,
  style,
  width,
  height,
  viewBox,
  children,
}: {
  className: string;
  kind: string;
  symbol: string | undefined;
  offline?: boolean | undefined;
  style?: CSSProperties | undefined;
  width: number;
  height: number;
  viewBox: string;
  children: ReactNode;
}) {
  return (
    <svg
      className={className}
      data-device={kind}
      data-symbol={symbol}
      data-offline={offline ? "" : undefined}
      style={style}
      width={width}
      height={height}
      viewBox={viewBox}
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}
