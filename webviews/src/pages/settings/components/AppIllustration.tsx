import type { AppTheme } from "../../../theme/appTheme";

// The app half: a window drawn as an illustration (traffic lights, a sidebar, one grouped card
// of rows), placeholder bars instead of words and small control shapes instead of real controls,
// so it reads as a picture of the app in this theme, not as something to click.
const SIDEBAR_W = 84;
const BARS = [40, 52, 36, 46];
const ROW_H = 38;
const LIGHTS = ["#ff5f57", "#febc2e", "#28c840"];

export function AppIllustration({
  app,
  clip,
  x: APP_X,
  width: APP_W,
  height: H,
}: {
  app: AppTheme;
  clip: string;
  x: number;
  width: number;
  height: number;
}) {
  const a = app.tokens;
  const cardX = SIDEBAR_W + 14;
  const cardW = APP_W - cardX - 14;
  const cardY = 40;
  const right = cardX + cardW - 12;
  const row = (index: number) => cardY + index * ROW_H;
  return (
    <g transform={`translate(${APP_X} 0)`} aria-hidden="true">
      <clipPath id={clip}>
        <rect width={APP_W} height={H} rx="9" />
      </clipPath>
      <g clipPath={`url(#${clip})`}>
        <rect width={APP_W} height={H} fill={a.content} />
        <rect width={SIDEBAR_W} height={H} fill={a.sidebar} />
        <rect x={SIDEBAR_W} width="1" height={H} fill={a.separator} />
        {LIGHTS.map((light, index) => (
          <circle key={light} cx={13 + index * 11} cy="13" r="3.5" fill={light} opacity="0.85" />
        ))}
        {BARS.map((width, index) => (
          <g key={width} transform={`translate(8 ${34 + index * 20})`}>
            {index === 1 && <rect x="-2" y="-6" width={SIDEBAR_W - 12} height="18" rx="5" fill={a.selection} />}
            <rect
              x="2"
              y="0"
              width="6"
              height="6"
              rx="2"
              fill={index === 1 ? a.accent : a.icon}
              opacity={index === 1 ? 1 : 0.5}
            />
            <rect
              x="13"
              y="0.5"
              width={width - 16}
              height="5"
              rx="2.5"
              fill={a.text}
              opacity={index === 1 ? 0.8 : 0.35}
            />
          </g>
        ))}

        <rect x={cardX} y="17" width="64" height="7" rx="3.5" fill={a.text} opacity="0.8" />
        <rect x={cardX} y={cardY} width={cardW} height={ROW_H * 3} rx="7" fill={a.elevated} stroke={a.separator} />
        {[0, 1, 2].map((index) => (
          <g key={index}>
            {index > 0 && <rect x={cardX + 10} y={row(index)} width={cardW - 20} height="1" fill={a.separator} />}
            <rect
              x={cardX + 12}
              y={row(index) + 12}
              width={[58, 44, 66][index]}
              height="5"
              rx="2.5"
              fill={a.text}
              opacity="0.6"
            />
            <rect
              x={cardX + 12}
              y={row(index) + 22}
              width={[86, 72, 60][index]}
              height="4"
              rx="2"
              fill={a.textSecondary}
              opacity="0.45"
            />
          </g>
        ))}
        <rect x={right - 20} y={row(0) + 13} width="20" height="12" rx="6" fill={a.accent} />
        <circle cx={right - 6} cy={row(0) + 19} r="4.5" fill={a.onAccent} />
        <rect x={right - 36} y={row(1) + 13} width="36" height="12" rx="3.5" fill={a.control} />
        <rect x={right - 35} y={row(1) + 14} width="17" height="10" rx="3" fill={a.elevated} />
        <rect x={right - 20} y={row(2) + 13} width="20" height="12" rx="6" fill={a.control} stroke={a.controlStroke} />
        <circle cx={right - 14} cy={row(2) + 19} r="4.5" fill={a.icon} opacity="0.7" />

        <rect
          x={cardX}
          y={cardY + ROW_H * 3 + 18}
          width="50"
          height="5"
          rx="2.5"
          fill={a.textSecondary}
          opacity="0.45"
        />
        <rect
          x={cardX}
          y={cardY + ROW_H * 3 + 30}
          width={cardW - 40}
          height="5"
          rx="2.5"
          fill={a.textSecondary}
          opacity="0.3"
        />
      </g>
      <rect x="0.5" y="0.5" width={APP_W - 1} height={H - 1} rx="9" fill="none" stroke={a.separator} />
    </g>
  );
}
