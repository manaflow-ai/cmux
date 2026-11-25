import type { CSSProperties } from "react";
import sceneType from "../../../../schemas/type-scale/scene-type.json";
import type { SceneProps } from "./store";

const clamp = (value: number, low: number, high: number) => Math.min(Math.max(value, low), high);

export const sceneText = (value: unknown): string =>
  typeof value === "string" || typeof value === "number" ? String(value) : "";
export const sceneNumber = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined;
export const sceneRecord = (value: unknown): Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};

const COLORS: Record<string, string> = {
  primary: "var(--agent-text)",
  // The theme's accent: its text color by default (the no-blue rule), its own hue with appearance.accent.
  accent: "var(--cmux-accent, var(--agent-text))",
  secondary: "var(--agent-muted)",
  // The theme's tertiary ink (WebTheme --cmux-text-tertiary, 3:1 on every fill). The fixed 38% wash read a widget's
  // icons at 2.71:1 on Catppuccin Mocha's card (control-contrast-2, apps.widgets).
  tertiary: "var(--cmux-text-tertiary, color-mix(in srgb, var(--agent-text) 38%, transparent))",
  separator: "var(--agent-border)",
  success: "var(--agent-status-success)",
  warning: "var(--agent-status-warning)",
  danger: "var(--agent-danger)",
  hover: "var(--agent-control-hover)",
  selected: "var(--agent-accent-soft)",
  badge: "var(--agent-control)",
  clear: "transparent",
};

/** The glass levels a node's `glass` prop names, as the native renderer's (CmuxNextDesign GlassLevel). */
export const SCENE_GLASS_LEVELS = ["chrome", "popover", "menu", "chip"] as const;
export type SceneGlassLevel = (typeof SCENE_GLASS_LEVELS)[number];

/** A node's `glass` level, or undefined for none or an unknown one (which draws no glass). */
export function sceneGlass(value: unknown): SceneGlassLevel | undefined {
  return SCENE_GLASS_LEVELS.find((level) => level === value);
}

/** App colors are semantic tokens or hex, never arbitrary CSS. */
export function sceneColor(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  return COLORS[value] ?? (/^#[\da-f]{6}([\da-f]{2})?$/i.test(value) ? value : undefined);
}

/** A gradient fill (`background`, a shape's `fill`) as a CSS image: `{linear: {colors, angle?}}` or
 * `{radial: {colors}}`, 2 to 8 stops that are each a token or `#RRGGBB[AA]`, spaced evenly. `angle` is
 * in degrees the CSS way (0 up, 90 right, 180 down, the default). Anything else is undefined, so a
 * bad value draws no gradient rather than arbitrary CSS. */
export function sceneGradient(value: unknown): string | undefined {
  const record = sceneRecord(value);
  const keys = Object.keys(record);
  const kind = keys[0];
  if (keys.length !== 1 || (kind !== "linear" && kind !== "radial")) return undefined;
  const spec = sceneRecord(record[kind]);
  const allowed = kind === "linear" ? ["colors", "angle"] : ["colors"];
  if (Object.keys(spec).some((key) => !allowed.includes(key))) return undefined;
  const stops: unknown = spec.colors;
  if (!Array.isArray(stops) || stops.length < 2 || stops.length > 8) return undefined;
  const colors = stops.map(sceneColor);
  if (colors.some((color) => color === undefined)) return undefined;
  if (kind === "radial") return `radial-gradient(closest-side, ${colors.join(", ")})`;
  const angle = spec.angle === undefined ? 180 : sceneNumber(spec.angle);
  if (angle === undefined) return undefined;
  return `linear-gradient(${((angle % 360) + 360) % 360}deg, ${colors.join(", ")})`;
}

export type SceneStyle = CSSProperties & { "--app-hover"?: string; "--app-x"?: string; "--app-y"?: string };

/** A ZStack child's `position`: its center at `{x, y}` points, or with `unit: "fraction"` at 0...1 of
 * the stack (SwiftUI's `.position`); an axis left out centers. Undefined without one. */
export function scenePosition(props: SceneProps): { x: string; y: string } | undefined {
  const position = sceneRecord(props.position);
  const x = sceneNumber(position.x);
  const y = sceneNumber(position.y);
  if (x === undefined && y === undefined) return undefined;
  const fraction = position.unit === "fraction";
  const place = (value: number | undefined) =>
    value === undefined ? "50%" : fraction ? `${value * 100}%` : `${value}px`;
  return { x: place(x), y: place(y) };
}
/** The scene's type, one table for both renderers (RFD 0009): every name a node's `font` may take, a
 * cmux type role (`numeral` ... `footnote`) or an Apple text style name, at one size and weight. AppKit
 * draws the same table (`SceneType`, which scripts/cmux-next/gen-type-scale.py writes from this file). */
type SceneTypeStyle = { name: string; size: number; weight: "regular" | "medium" | "semibold" | "bold" };
const SCENE_TYPE: ReadonlyMap<string, SceneTypeStyle> = new Map(
  [...(sceneType.roles as SceneTypeStyle[]), ...(sceneType.styles as SceneTypeStyle[])].map((style) => [
    style.name,
    style,
  ]),
);

/** A `font` name's size and weight; an unknown name draws as `body`, as it does in AppKit. */
export function sceneTypeStyle(name: string): SceneTypeStyle {
  return SCENE_TYPE.get(name) ?? SCENE_TYPE.get("body")!;
}

const WEIGHTS: Record<string, number> = {
  ultraLight: 200,
  thin: 200,
  light: 300,
  regular: 400,
  medium: 500,
  semibold: 600,
  bold: 700,
  heavy: 800,
  black: 900,
};

export function sceneStyle(props: SceneProps): SceneStyle {
  const style: SceneStyle = {};
  const padding = sceneNumber(props.padding);
  const edges = sceneRecord(props.padding);
  if (padding !== undefined) style.padding = padding;
  else {
    style.paddingTop = sceneNumber(edges.top);
    style.paddingInlineStart = sceneNumber(edges.leading);
    style.paddingBottom = sceneNumber(edges.bottom);
    style.paddingInlineEnd = sceneNumber(edges.trailing);
  }
  const horizontal = sceneNumber(props.paddingHorizontal);
  const vertical = sceneNumber(props.paddingVertical);
  if (horizontal !== undefined) style.paddingInline = horizontal;
  if (vertical !== undefined) style.paddingBlock = vertical;
  const frame = sceneRecord(props.frame);
  for (const key of ["width", "height", "minWidth", "maxWidth", "minHeight", "maxHeight"] as const) {
    const value = sceneNumber(frame[key]);
    if (value !== undefined) style[key] = Math.max(0, value);
    else if (frame[key] === "infinity") style[key] = key.startsWith("max") ? "none" : "100%";
  }
  style.opacity =
    sceneNumber(props.opacity) === undefined ? undefined : Math.max(0, Math.min(1, props.opacity as number));
  // The node's own transform as the individual properties, so a value animation (`rotate` 350 to
  // 370 degrees turns 20, not back 340) and a loop or transition (`transform`) compose.
  // `offset` moves the drawing, then `rotation` turns it clockwise about the node's own center, so a
  // clock hand offset by half its length turns about the face's center. Neither moves the layout.
  const rotation = sceneNumber(props.rotation);
  const scale = sceneNumber(props.scale);
  if (scale !== undefined) style.scale = String(Math.max(0, scale));
  const offset = offsetTranslate(props.offset);
  if (offsetInTransform(props)) {
    // A rotated offset (a clock hand) or a positioned child (whose `translate` centers it on its
    // point) carries both in `transform`, offset first, so the rotation turns the offset too.
    const transforms = [
      rotation !== undefined ? `rotate(${rotation}deg)` : "",
      offset ? `translate(${offset.replace(" ", ", ")})` : "",
    ].filter(Boolean);
    if (transforms.length) style.transform = transforms.join(" ");
  } else {
    if (rotation !== undefined) style.rotate = `${rotation}deg`;
    style.translate = offset;
  }
  const blur = sceneNumber(props.blur);
  const glow = glowFilter(props.glow);
  // An animated node keeps both functions so a blur or glow change interpolates (same filter list).
  if (props.animation !== undefined && (blur !== undefined || props.glow !== undefined)) {
    style.filter = `blur(${Math.max(0, blur ?? 0)}px) ${glow ?? "drop-shadow(0 0 0px transparent)"}`;
  } else if (blur !== undefined || glow) {
    style.filter = [blur !== undefined ? `blur(${Math.max(0, blur)}px)` : "", glow ?? ""].filter(Boolean).join(" ");
  }
  // A `gradient` (the motion modifier) draws over a color `background`; a gradient `background` replaces the color.
  // Glass replaces the fill, a gradient one too, as it does in the native renderer.
  const glass = sceneGlass(props.glass) !== undefined;
  const backgroundGradient = glass ? undefined : sceneGradient(props.background);
  style.backgroundImage = gradientImage(props.gradient) ?? backgroundGradient;
  style.backgroundColor = glass || backgroundGradient ? undefined : sceneColor(props.background);
  style.color = sceneColor(props.color);
  style.borderRadius = sceneNumber(props.cornerRadius);
  // `.clipped()`: the node's content (a child's slide or glow) stays inside its frame and corners.
  if (props.clipped === true) style.overflow = "hidden";
  if (sceneColor(props.borderColor)) {
    style.borderColor = sceneColor(props.borderColor);
    style.borderStyle = "solid";
    style.borderWidth = Math.max(0, sceneNumber(props.borderWidth) ?? 1);
  }
  style["--app-hover"] = sceneColor(props.hoverBackground);
  const position = scenePosition(props);
  if (position) {
    style["--app-x"] = position.x;
    style["--app-y"] = position.y;
  }
  style.gap = sceneNumber(props.spacing);
  if (props.fixedSize === "both" || props.fixedSize === "horizontal") style.flexShrink = 0;
  // App controls follow the host's default cursor even when a cross-platform scene requests a hand.
  if (props.cursor === "pointer" || props.cursor === "default") style.cursor = "default";
  return style;
}

/** `fontDesign`: the system font's rounded, serif or monospaced design (scene.css's stacks: SF Pro
 * Rounded, New York, SF Mono where the system has them). The type scale still sets the size. */
const DESIGNS: Record<string, string> = {
  rounded: "var(--cmux-app-scene-font-rounded)",
  serif: "var(--cmux-app-scene-font-serif)",
  monospaced: "var(--cmux-app-scene-font-monospaced)",
};

export function textStyle(props: SceneProps): CSSProperties {
  const size = sceneNumber(props.font);
  const lines = sceneNumber(props.lineLimit);
  // A name draws its table size, grown with Interface Size like the chrome's `--text-*` steps.
  const named = typeof props.font === "string" ? sceneTypeStyle(props.font) : undefined;
  return {
    fontSize:
      size !== undefined
        ? Math.min(64, Math.max(6, size))
        : named && `calc(${named.size}px * var(--cmux-interface-scale, 1))`,
    fontWeight: WEIGHTS[sceneText(props.weight)] ?? (named && WEIGHTS[named.weight]),
    fontStyle: props.italic === true ? "italic" : undefined,
    textDecorationLine: props.strikethrough === true ? "line-through" : undefined,
    fontFamily: DESIGNS[sceneText(props.fontDesign)] ?? (props.monospaced === true ? "var(--font-mono)" : undefined),
    ...(lines === undefined
      ? {}
      : lines > 1
        ? {
            display: "-webkit-box",
            WebkitLineClamp: Math.max(1, Math.floor(lines)),
            WebkitBoxOrient: "vertical",
            overflow: "hidden",
          }
        : { overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }),
  };
}

/** `glow` as a CSS `drop-shadow()`, which follows the node's own shape (text, a circle, a capsule). */
export function glowFilter(value: unknown): string | undefined {
  const glow = sceneRecord(value);
  const color = sceneColor(glow.color);
  const radius = sceneNumber(glow.radius);
  if (!color || radius === undefined) return undefined;
  const opacity = clamp(sceneNumber(glow.opacity) ?? 1, 0, 1);
  const ink = opacity >= 1 ? color : `color-mix(in srgb, ${color} ${Math.round(opacity * 100)}%, transparent)`;
  return `drop-shadow(0 0 ${clamp(radius, 0, 200)}px ${ink})`;
}

/** `gradient` as a CSS `linear-gradient()`: the contract's 0 degrees runs left to right, 90 top to bottom. */
export function gradientImage(value: unknown): string | undefined {
  const gradient = sceneRecord(value);
  const colors = Array.isArray(gradient.colors) ? gradient.colors.map(sceneColor).filter((c): c is string => !!c) : [];
  if (colors.length === 0) return undefined;
  const stops = colors.length === 1 ? [colors[0], colors[0]] : colors.slice(0, 16);
  const angle = (sceneNumber(gradient.angle) ?? 90) + 90;
  return `linear-gradient(${angle}deg, ${stops.join(", ")})`;
}

/** Whether the node's `offset` goes in `transform` (after its rotation, or beside a ZStack `position`)
 * rather than the individual `translate`. */
export function offsetInTransform(props: SceneProps): boolean {
  return (
    offsetTranslate(props.offset) !== undefined &&
    (sceneNumber(props.rotation) !== undefined || scenePosition(props) !== undefined)
  );
}

/** The `offset` prop as a CSS `translate`. */
export function offsetTranslate(value: unknown): string | undefined {
  const offset = sceneRecord(value);
  const x = sceneNumber(offset.x) ?? 0;
  const y = sceneNumber(offset.y) ?? 0;
  return x === 0 && y === 0 && !("x" in offset || "y" in offset) ? undefined : `${x}px ${y}px`;
}
