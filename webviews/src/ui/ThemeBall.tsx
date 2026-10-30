// A theme as a ball (theme/themeBall.ts): every theme picker draws its choices with it.
import { memo } from "react";
import type { TerminalColors } from "../theme/appTheme";
import { BALL_SIZE, themeBall, type ThemeBall as Ball } from "../theme/themeBall";

// A theme's colors object is shared and never mutated (the theme colors cache), so its ball is
// computed once: a picker of 600+ themes re-renders without redoing the palette math per row.
const balls = new WeakMap<TerminalColors, Ball>();
function ballOf(colors: TerminalColors): Ball {
  let ball = balls.get(colors);
  if (!ball) balls.set(colors, (ball = themeBall(colors)));
  return ball;
}

/** A theme as a ball; memoized, since a list redraws many of them with unchanged props. */
export const ThemeBall = memo(function ThemeBall({
  name,
  colors,
  className,
  size,
}: {
  /** The theme's name, for `data-theme-ball`. */
  name?: string;
  /** Its colors; absent draws an empty dashed circle (colors still loading). */
  colors: TerminalColors | undefined;
  className?: string;
  /** Its width and height in px; by default the stylesheet sizes `.theme-ball`. */
  size?: number;
}) {
  const style = size ? { width: size, height: size, flexShrink: 0 } : undefined;
  const classes = ["theme-ball", className].filter(Boolean).join(" ");
  if (!colors) return <span className={`${classes} theme-ball-empty`} style={style} aria-hidden="true" />;
  const ball = ballOf(colors);
  return (
    <svg
      className={classes}
      style={style}
      viewBox={`0 0 ${BALL_SIZE} ${BALL_SIZE}`}
      aria-hidden="true"
      shapeRendering="geometricPrecision"
      data-theme-ball={name}
    >
      <circle data-ball="surface" {...ball.surface} stroke="currentColor" strokeOpacity="0.2" strokeWidth="0.75" />
      {ball.ring.map(({ hue, accent, ...dot }) => (
        <circle key={hue} data-ball-hue={hue} data-ball-accent={accent || undefined} {...dot} />
      ))}
      <circle data-ball="text" {...ball.text} />
    </svg>
  );
});
