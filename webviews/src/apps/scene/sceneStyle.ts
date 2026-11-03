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
  accent: "var(--agent-text)",
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
  const rotation = sceneNumber(props.rotation);
  if (rotation !== undefined) style.transform = `rotate(${rotation}deg)`;
  style.backgroundColor = sceneColor(props.background);
  style.color = sceneColor(props.color);
  style.borderRadius = sceneNumber(props.cornerRadius);
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
