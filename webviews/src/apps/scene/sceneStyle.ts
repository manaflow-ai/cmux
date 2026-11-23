import type { CSSProperties } from "react";
import type { SceneProps } from "./store";

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

export type SceneTrim = { from: number; to: number; lineCap: "round" | "butt" };

/** A shape's `trim` (`{from?, to, lineCap?}`, SwiftUI's `trim(from:to:)`): fractions of the stroked
 * outline clamped to 0..1, `from` 0 by default and never past `to`; `lineCap` `round` or `butt`
 * (the default). Undefined with no finite `to`, so a bad value draws the whole outline. */
export function sceneTrim(value: unknown): SceneTrim | undefined {
  const trim = sceneRecord(value);
  const to = sceneNumber(trim.to);
  if (to === undefined) return undefined;
  const clamp = (n: number) => Math.max(0, Math.min(1, n));
  const from = clamp(sceneNumber(trim.from) ?? 0);
  return { from, to: Math.max(from, clamp(to)), lineCap: trim.lineCap === "round" ? "round" : "butt" };
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
  // `offset` moves the drawing, then `rotation` turns it clockwise about the node's own center, so a
  // clock hand offset by half its length turns about the face's center. Neither moves the layout.
  const rotation = sceneNumber(props.rotation);
  const offset = sceneRecord(props.offset);
  const dx = sceneNumber(offset.x) ?? 0;
  const dy = sceneNumber(offset.y) ?? 0;
  const transforms = [
    rotation !== undefined ? `rotate(${rotation}deg)` : "",
    dx || dy ? `translate(${dx}px, ${dy}px)` : "",
  ].filter(Boolean);
  if (transforms.length) style.transform = transforms.join(" ");
  // Glass replaces the fill, a gradient one too, as it does in the native renderer.
  const glass = sceneGlass(props.glass) !== undefined;
  style.backgroundImage = glass ? undefined : sceneGradient(props.background);
  style.backgroundColor = glass || style.backgroundImage ? undefined : sceneColor(props.background);
  style.color = sceneColor(props.color);
  style.borderRadius = sceneNumber(props.cornerRadius);
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
  return {
    fontSize: size === undefined ? FONTS[sceneText(props.font)] : Math.min(64, Math.max(6, size)),
    fontWeight: WEIGHTS[sceneText(props.weight)],
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
