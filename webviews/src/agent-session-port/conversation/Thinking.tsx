import type { CSSProperties } from "react";

export type ThinkingProps = {
  label?: string;
  /**
   * Center of the moving highlight as a fraction of the label width (0…1). The capture
   * froze it over "ing" (0.88); `null` draws the label flat.
   */
  shimmer?: number | null;
  /** Half-width of the highlight ramp, as a fraction of the label width. */
  spread?: number;
};

/** Streaming "Thinking" label with its moving highlight frozen at `shimmer`. */
export function Thinking({ label = "Thinking", shimmer = 0.88, spread = 0.28 }: ThinkingProps) {
  const style =
    shimmer === null
      ? undefined
      : ({
          "--cv-shimmer": `${(shimmer * 100).toFixed(1)}%`,
          "--cv-shimmer-from": `${((shimmer - spread) * 100).toFixed(1)}%`,
          "--cv-shimmer-to": `${((shimmer + spread) * 100).toFixed(1)}%`,
        } as CSSProperties);
  return (
    <div className="cv-thinking-row">
      <span className={`cv-thinking${shimmer === null ? "" : " is-shimmer"}`} style={style}>
        {label}
      </span>
    </div>
  );
}
