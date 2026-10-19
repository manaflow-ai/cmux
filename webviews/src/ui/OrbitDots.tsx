// The Orbit set's working mark, the web copy of the app's (StatusIndicatorLayer+Orbit.swift, Leo
// 2026-10-18 after Claude Code's working mark): four dots in Claude's orange on a circle, a quarter
// turn apart, that turn once per 3.6 s and draw in to a tight cluster and back out twice a turn.
// Nothing fades, so nothing blinks. `still` (and Reduce Motion) leaves the dots spread on the axes
// where a turn starts; the app draws the static look under Reduce Motion (StatusGlyph "working").
import "./OrbitDots.css";

/** Claude Code's working orange (rgb 215 119 87), the app's `StatusIndicatorLayer.Colors.claude`. */
export const ORBIT_DOTS_ORANGE = "#d77757";

export function OrbitDots({
  size = 10,
  still = false,
  label,
  className,
}: {
  /** Width and height in px (10 is the status slot). */
  size?: number;
  still?: boolean;
  /** What it says to assistive tech; absent, the mark is hidden from it (its row says the state). */
  label?: string;
  className?: string;
}) {
  return (
    <span
      className={["orbit-dots", className].filter(Boolean).join(" ")}
      data-still={still || undefined}
      style={{
        width: size,
        height: size,
        ["--orbit-dots-size" as string]: `${size}px`,
        ["--orbit-dots-color" as string]: ORBIT_DOTS_ORANGE,
      }}
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : "true"}
    >
      {[0, 1, 2, 3].map((index) => (
        <span key={index} className="orbit-dots__arm" style={{ transform: `rotate(${index * 90}deg)` }}>
          <span className="orbit-dots__dot" />
        </span>
      ))}
    </span>
  );
}
