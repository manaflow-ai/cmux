import React, { useSyncExternalStore } from "react";

/// One agent's mark: monochrome paths drawn in currentColor, so the theme's text
/// tokens tint it. `brandColor` is kept for a later brand-color mode, and
/// `source` records where the official artwork came from (see AGENT_MARKS.md).
export type AgentMarkSpec = {
  viewBox: string;
  paths: string[];
  fillRule?: "evenodd";
  brandColor?: string;
  /// "black-white": the vendor allows the mark only in black or white, so it draws
  /// in the theme's text color only when that is near-black or near-white.
  recolor?: "any" | "black-white";
  source: string;
};

/// Marks by agent key. Only official artwork from each vendor's brand or press
/// assets goes here; an agent without one draws the generic agent glyph.
export const AGENT_MARKS: Record<string, AgentMarkSpec> = {};

/// The agent a harness id names: its first word, lowercased. acpmux names harnesses
/// by config id, so variants share their agent ("claude-sr" is "claude").
export function agentKey(id: string | undefined): string | undefined {
  const word = id?.split(/[-_\s]+/).find(Boolean);
  return word ? word.toLowerCase() : undefined;
}

/// Whether a CSS color is near-black or near-white (relative luminance at most 0.02 or at least 0.8).
export function nearBlackOrWhite(color: string): boolean {
  const hex = /^#([0-9a-f]{6})$/i.exec(color.trim());
  const rgb = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)/i.exec(color.trim());
  const channels = hex
    ? [0, 2, 4].map((at) => parseInt(hex[1]!.slice(at, at + 2), 16))
    : rgb
      ? [rgb[1], rgb[2], rgb[3]].map(Number)
      : undefined;
  if (!channels) return false;
  const [r, g, b] = channels.map((value) => {
    const c = value / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  }) as [number, number, number];
  const luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  return luminance <= 0.02 || luminance >= 0.8;
}

// The theme's text color, as applyAgentTheme sets it on the root; one observer for every mark.
const listeners = new Set<() => void>();
let observer: MutationObserver | undefined;
function subscribe(listener: () => void) {
  listeners.add(listener);
  if (!observer && typeof MutationObserver !== "undefined" && typeof document !== "undefined") {
    observer = new MutationObserver(() => listeners.forEach((notify) => notify()));
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["style"] });
  }
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) {
      observer?.disconnect();
      observer = undefined;
    }
  };
}
const themeText = () =>
  typeof document === "undefined" ? "" : document.documentElement.style.getPropertyValue("--agent-text");

/// An agent's mark, at `size` px, for the model menu, the pane header, session rows
/// and new-tab cards. With `label` it is an image named for the agent; without, it
/// is decoration beside text that already names it.
export function AgentMark({ agent, size = 16, label }: { agent?: string; size?: number; label?: string }) {
  const key = agentKey(agent);
  const text = useSyncExternalStore(subscribe, themeText, () => "");
  const found = key ? AGENT_MARKS[key] : undefined;
  const spec = found?.recolor === "black-white" && !nearBlackOrWhite(text) ? undefined : found;
  const a11y = label ? { role: "img", "aria-label": label } : { "aria-hidden": true as const };
  if (!spec)
    return (
      <svg
        className="agent-mark agent-mark-generic"
        width={size}
        height={size}
        viewBox="0 0 16 16"
        fill="none"
        stroke="currentColor"
        strokeWidth={1.25}
        strokeLinecap="round"
        strokeLinejoin="round"
        focusable="false"
        {...a11y}
      >
        <rect x="2.25" y="2.75" width="11.5" height="10.5" rx="2.5" />
        <path d="m5.25 6.5 2 1.75-2 1.75M8.75 10h2" />
      </svg>
    );
  return (
    <svg
      className="agent-mark"
      data-agent={key}
      width={size}
      height={size}
      viewBox={spec.viewBox}
      fill="currentColor"
      focusable="false"
      {...a11y}
    >
      {spec.paths.map((d, index) => (
        <path key={index} d={d} fillRule={spec.fillRule} clipRule={spec.fillRule} />
      ))}
    </svg>
  );
}
