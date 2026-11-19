import type { CSSProperties } from "react";
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
  tertiary: "color-mix(in srgb, var(--agent-text) 38%, transparent)",
  separator: "var(--agent-border)",
  success: "var(--agent-status-success)",
  warning: "var(--agent-status-warning)",
  danger: "var(--agent-danger)",
  hover: "var(--agent-control-hover)",
  selected: "var(--agent-accent-soft)",
  badge: "var(--agent-control)",
  clear: "transparent",
};

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

type SceneStyle = CSSProperties & { "--app-hover"?: string };
const FONTS: Record<string, string> = {
  largeTitle: "var(--text-title)",
  title: "var(--text-title)",
  title2: "var(--text-heading)",
  title3: "var(--text-heading)",
  headline: "var(--text-control)",
  subheadline: "var(--text-body)",
  body: "var(--text-control)",
  callout: "var(--text-body)",
  caption: "var(--text-detail)",
  caption2: "var(--text-caption)",
};
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
  const rotation = sceneNumber(props.rotation);
  if (rotation !== undefined) style.rotate = `${rotation}deg`;
  const scale = sceneNumber(props.scale);
  if (scale !== undefined) style.scale = String(Math.max(0, scale));
  style.translate = offsetTranslate(props.offset);
  const blur = sceneNumber(props.blur);
  const glow = glowFilter(props.glow);
  // An animated node keeps both functions so a blur or glow change interpolates (same filter list).
  if (props.animation !== undefined && (blur !== undefined || props.glow !== undefined)) {
    style.filter = `blur(${Math.max(0, blur ?? 0)}px) ${glow ?? "drop-shadow(0 0 0px transparent)"}`;
  } else if (blur !== undefined || glow) {
    style.filter = [blur !== undefined ? `blur(${Math.max(0, blur)}px)` : "", glow ?? ""].filter(Boolean).join(" ");
  }
  // A `gradient` (the motion modifier) draws over a color `background`; a gradient `background` replaces the color.
  const backgroundGradient = sceneGradient(props.background);
  style.backgroundImage = gradientImage(props.gradient) ?? backgroundGradient;
  style.backgroundColor = backgroundGradient ? undefined : sceneColor(props.background);
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
  style.gap = sceneNumber(props.spacing);
  if (props.fixedSize === "both" || props.fixedSize === "horizontal") style.flexShrink = 0;
  // App controls follow the host's default cursor even when a cross-platform scene requests a hand.
  if (props.cursor === "pointer" || props.cursor === "default") style.cursor = "default";
  return style;
}

export function textStyle(props: SceneProps): CSSProperties {
  const size = sceneNumber(props.font);
  const lines = sceneNumber(props.lineLimit);
  return {
    fontSize: size === undefined ? FONTS[sceneText(props.font)] : Math.min(64, Math.max(6, size)),
    fontWeight: WEIGHTS[sceneText(props.weight)],
    fontStyle: props.italic === true ? "italic" : undefined,
    textDecorationLine: props.strikethrough === true ? "line-through" : undefined,
    fontFamily: props.monospaced === true ? "var(--font-mono)" : undefined,
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

/** The `offset` prop as a CSS `translate`. */
export function offsetTranslate(value: unknown): string | undefined {
  const offset = sceneRecord(value);
  const x = sceneNumber(offset.x) ?? 0;
  const y = sceneNumber(offset.y) ?? 0;
  return x === 0 && y === 0 && !("x" in offset || "y" in offset) ? undefined : `${x}px ${y}px`;
}
