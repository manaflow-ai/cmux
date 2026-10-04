import React, { useId, useSyncExternalStore } from "react";
import { agentBrand, AGENT_BRANDS, type AgentBrandSpec, type BrandTone } from "./agentBrand";

export { agentBrand };

/// How marks color: each vendor's own colors (the default), or white on dark themes
/// and black on light ones.
export type AgentMarkStyle = "brand" | "mono";

/// Sets the mark style for every mark on the page.
export function setAgentMarkStyle(style: AgentMarkStyle) {
  if (typeof document === "undefined") return;
  if (style === "mono") document.documentElement.dataset.agentMarks = "mono";
  else delete document.documentElement.dataset.agentMarks;
}

// The root attributes marks follow: data-theme, which applyAgentTheme sets from the
// background-against-text luminance, and data-agent-marks. One observer for every mark.
const listeners = new Set<() => void>();
let observer: MutationObserver | undefined;
function subscribe(listener: () => void) {
  listeners.add(listener);
  if (!observer && typeof MutationObserver !== "undefined" && typeof document !== "undefined") {
    observer = new MutationObserver(() => listeners.forEach((notify) => notify()));
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme", "data-agent-marks"],
    });
  }
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) {
      observer?.disconnect();
      observer = undefined;
    }
  };
}
/// Whether the shared root observer is live. @internal, for tests.
export const agentMarkObserving = () => observer !== undefined;
// The pane is dark, in brand color, until told otherwise.
const appearance = () => {
  if (typeof document === "undefined") return "dark brand";
  const { theme, agentMarks } = document.documentElement.dataset;
  return `${theme === "light" ? "light" : "dark"} ${agentMarks === "mono" ? "mono" : "brand"}`;
};

const tone = (value: BrandTone, dark: boolean) => (typeof value === "string" ? value : dark ? value[0] : value[1]);
const box = (v: readonly number[]) => v.join(" ");

/// An agent's mark, at `size` px, for the model menu, the pane header, session rows
/// and new-tab cards. With `label` it is an image named for the agent; without, it
/// is decoration beside text that already names it. Marks pick their colors for the
/// page's theme; on a surface of the other lightness (a selected row on the accent),
/// `onDark` says which side the surface is on. The marks and their sources live in
/// design/agent-icons (manifest.json); agentBrands.generated.ts is generated from it.
export function AgentMark({
  agent,
  size = 16,
  label,
  onDark,
}: {
  agent?: string;
  size?: number;
  label?: string;
  onDark?: boolean;
}) {
  const key = agentBrand(agent);
  const [scheme, style] = useSyncExternalStore(subscribe, appearance, () => "dark brand").split(" ");
  const dark = onDark ?? scheme === "dark";
  const brand = style === "brand";
  // useId's punctuation would need escaping inside url(#…).
  const gradientId = `agent-mark${useId().replace(/[^\w-]/g, "")}`;
  const spec: AgentBrandSpec | undefined = key ? AGENT_BRANDS[key] : undefined;
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
  const tile = brand ? spec.tile : undefined;
  const fill = brand ? tone(spec.tone, dark) : dark ? "#fff" : "#000";
  const drawPath = (path: AgentBrandSpec["paths"][number], index: number, paint?: string) => {
    const own = brand && path.tone ? tone(path.tone, dark) : undefined;
    const opacity = brand ? undefined : path.monoOpacity;
    if (opacity === 0) return null;
    const color = paint ?? own;
    return path.strokeWidth ? (
      <path
        key={index}
        d={path.d}
        fill="none"
        stroke={color ?? fill}
        strokeWidth={path.strokeWidth}
        opacity={opacity}
      />
    ) : (
      <path key={index} d={path.d} fill={color} fillRule={path.evenOdd ? "evenodd" : undefined} opacity={opacity} />
    );
  };
  return (
    <svg
      className="agent-mark"
      data-agent={key}
      width={size}
      height={size}
      viewBox={box(tile?.viewBox ?? spec.viewBox)}
      fill={fill}
      focusable="false"
      {...a11y}
    >
      {tile && (
        <rect
          x={tile.viewBox[0]}
          y={tile.viewBox[1]}
          width={tile.viewBox[2]}
          height={tile.viewBox[3]}
          rx={tile.radius}
          fill={tone(tile.tone, dark)}
        />
      )}
      {spec.paths.map((path, index) => drawPath(path, index))}
      {brand &&
        spec.overlays?.map((gradient, index) => (
          <React.Fragment key={`overlay${index}`}>
            <defs>
              <linearGradient
                id={`${gradientId}-${index}`}
                gradientUnits="userSpaceOnUse"
                x1={gradient.x1}
                y1={gradient.y1}
                x2={gradient.x2}
                y2={gradient.y2}
              >
                {gradient.stops.map(([offset, color, opacity], stop) => (
                  <stop key={stop} offset={offset} stopColor={color} stopOpacity={opacity} />
                ))}
              </linearGradient>
            </defs>
            {spec.paths.map((path, pathIndex) =>
              path.strokeWidth ? null : drawPath(path, pathIndex, `url(#${gradientId}-${index})`),
            )}
          </React.Fragment>
        ))}
    </svg>
  );
}
