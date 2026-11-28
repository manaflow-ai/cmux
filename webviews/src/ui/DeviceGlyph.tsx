import type { CSSProperties } from "react";
import { DEVICE_GLYPH_PATHS, DEVICE_GLYPH_VIEWBOX } from "./deviceGlyphPaths";
import { DEVICE_SYMBOLS, type DeviceKind, useDeviceKind } from "./deviceKinds";
import "./DeviceGlyph.css";

/// One device's glyph: the SF Symbol its kind names (`DEVICE_SYMBOLS`, the Rust table), drawn from
/// that symbol's vector paths (`deviceGlyphPaths.ts`) at one shared scale, so a Mac mini, a server
/// and an iPhone stand at the same optical size and center in every row (the MacBook prior art,
/// MacBookGlyph.tsx). Fills with the text color, so it follows the theme; `offline` dims it.
export function DeviceGlyph({
  kind,
  className,
  style,
  offline,
  width = 14,
  height = 14,
}: {
  kind: DeviceKind;
  className?: string;
  style?: CSSProperties | undefined;
  offline?: boolean;
  width?: number;
  height?: number;
}) {
  const symbol = DEVICE_SYMBOLS[kind];
  return (
    <svg
      className={`ui-device-glyph${className ? ` ${className}` : ""}`}
      data-device={kind}
      data-symbol={symbol}
      data-offline={offline ? "" : undefined}
      style={style}
      width={width}
      height={height}
      viewBox={DEVICE_GLYPH_VIEWBOX}
      aria-hidden="true"
      focusable="false"
    >
      <DeviceGlyphShapes kind={kind} />
    </svg>
  );
}

/// The glyph's paths alone, for an icon that already draws its own `<svg>` with the shared
/// `DEVICE_GLYPH_VIEWBOX` (the location picker's EnvironmentIcon, the composer chip).
export function DeviceGlyphShapes({ kind }: { kind: DeviceKind }) {
  const glyph = DEVICE_GLYPH_PATHS[DEVICE_SYMBOLS[kind]] ?? DEVICE_GLYPH_PATHS[DEVICE_SYMBOLS.generic];
  return (
    <g data-device={kind}>
      {glyph?.map((layer, index) => (
        <path key={index} d={layer.d} fill="currentColor" fillRule={layer.rule ?? "nonzero"} stroke="none" />
      ))}
    </g>
  );
}

/// The glyph of a machine the daemon described: this machine when `machine` is absent, else the
/// peer it names. `fallback` is the kind until the daemon says (an older daemon never does).
export function MachineGlyph({
  machine,
  fallback,
  ...rest
}: { machine?: string; fallback: DeviceKind } & Omit<Parameters<typeof DeviceGlyph>[0], "kind">) {
  const kind = useDeviceKind(machine) ?? fallback;
  return <DeviceGlyph kind={kind} {...rest} />;
}
