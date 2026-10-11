// The Theme section's preview (P3): a sample terminal in the theme's own colors (16 ANSI colors,
// background, foreground, cursor, selection) beside a sample app surface in the app tokens the
// theme derives (src/theme/appTheme.ts), then the palette itself. Drawn as SVG: the preview is
// an image of another theme, so it never paints the page's own surfaces (render rule).
import { useId } from "react";
import type { AppTheme } from "../../../theme/appTheme";
import type { GhosttyTheme } from "../../../theme/ghosttyTheme";
import { rowsByKey, sections } from "../schema";
import { t, text } from "../strings";

const W = 720;
const H = 214;
const GAP = 12;
const TERM_W = 424;
const APP_X = TERM_W + GAP;
const APP_W = W - APP_X;
const CELL = 7.25;
const LINE = 17.5;

type Segment = [column: number, color: number | "fg" | "dim", text: string];

// Sample terminal output: shell, git and ls text, the same in every language (as a screenshot).
const PROMPT: Segment[] = [
  [0, 4, "~/cmux"],
  [7, 5, "main"],
  [12, 2, "❯"],
];
const LINES: Segment[][] = [
  [...PROMPT, [14, "fg", "git status"]],
  [[0, "fg", "On branch main"]],
  [[0, "fg", "Changes to be committed:"]],
  [
    [2, 2, "new file:"],
    [14, 2, "src/theme.ts"],
  ],
  [
    [2, 1, "modified:"],
    [14, 1, "README.md"],
  ],
  [...PROMPT, [14, "fg", "ls"]],
  [
    [0, 4, "docs/"],
    [7, 4, "src/"],
    [13, 2, "build.sh"],
    [23, "fg", "README.md"],
    [34, "dim", "# 4 items"],
  ],
  [...PROMPT, [14, "fg", "git log --oneline -1"]],
  [
    [0, 3, "a3ebde5"],
    [8, "fg", "Add the Theme section"],
  ],
  [
    [0, 4, "~/cmux"],
    [7, 5, "main"],
    [12, 3, "*"],
    [14, 6, "1.2s"],
    [19, 2, "❯"],
  ],
];
const SELECTED = { line: 3, column: 14, length: 12 };
const CURSOR = { line: 9, column: 21 };

const title = (key: string) => (rowsByKey.get(key) ? text(rowsByKey.get(key)!.title) : key);
const help = (key: string) => text(rowsByKey.get(key)?.help);
const section = (id: string) => text(sections.find((item) => item.id === id)?.title);

export function ThemePreview({
  theme,
  app,
  fontFamily,
  label,
}: {
  theme: GhosttyTheme;
  app: AppTheme;
  fontFamily: string | null;
  label: string;
}) {
  const ansi = (index: number) => theme.palette[index] ?? theme.foreground;
  const color = (value: Segment[1]) => (value === "fg" ? theme.foreground : value === "dim" ? ansi(8) : ansi(value));
  const selection = theme.selectionBackground ?? mixHex(theme.background, theme.foreground, 0.25);
  const mono = `${fontFamily ? `"${fontFamily}", ` : ""}"SF Mono", ui-monospace, Menlo, monospace`;
  const a = app.tokens;
  const clip = `theme-preview-app-${useId().replace(/:/g, "")}`;
  const top = 28;
  const lineY = (line: number) => top + line * LINE;
  return (
    <svg
      className="theme-preview"
      viewBox={`0 0 ${W} ${H}`}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- an inline SVG drawing; an <img> cannot draw the theme.
      role="img"
      aria-label={label}
      data-theme-preview={theme.name}
    >
      <rect x="0.5" y="0.5" width={TERM_W - 1} height={H - 1} rx="9" fill={theme.background} stroke={a.separator} />
      <rect
        x={12 + SELECTED.column * CELL}
        y={lineY(SELECTED.line) - 14}
        width={SELECTED.length * CELL}
        height={LINE}
        fill={selection}
      />
      <g fontFamily={mono} fontSize="12">
        {LINES.map((segments, line) =>
          segments.map(([column, value, content]) => (
            <text
              key={`${line}-${column}`}
              x={12 + column * CELL}
              y={lineY(line)}
              fill={
                line === SELECTED.line && column === SELECTED.column && theme.selectionForeground
                  ? theme.selectionForeground
                  : color(value)
              }
            >
              {content}
            </text>
          )),
        )}
      </g>
      <rect
        x={12 + CURSOR.column * CELL}
        y={lineY(CURSOR.line) - 13}
        width={CELL}
        height={LINE - 2}
        rx="1"
        fill={theme.cursorColor ?? theme.foreground}
      />

      <g transform={`translate(${APP_X} 0)`} fontFamily="-apple-system, BlinkMacSystemFont, system-ui, sans-serif">
        <clipPath id={clip}>
          <rect width={APP_W} height={H} rx="9" />
        </clipPath>
        <g clipPath={`url(#${clip})`}>
          <rect width={APP_W} height={H} fill={a.content} />
          <rect width="96" height={H} fill={a.sidebar} />
          <rect x="96" width="1" height={H} fill={a.separator} />
          {["general", "appearance", "terminal", "browser"].map((id, index) => (
            <g key={id} transform={`translate(6 ${16 + index * 24})`}>
              {index === 1 && <rect width="84" height="20" rx="5" fill={a.selection} />}
              <circle
                cx="11"
                cy="10"
                r="4"
                fill="none"
                stroke={index === 1 ? a.accentText : a.icon}
                strokeWidth="1.4"
              />
              <text x="21" y="14" fontSize="11" fill={a.text}>
                {truncate(section(id), 11)}
              </text>
            </g>
          ))}
          <g transform="translate(110 0)">
            <text x="0" y="28" fontSize="13" fontWeight="600" fill={a.text}>
              {truncate(section("appearance"), 22)}
            </text>
            <text x="0" y="56" fontSize="11" fill={a.text}>
              {truncate(title("focusRing.enabled"), 20)}
            </text>
            <rect x={APP_W - 110 - 40} y="45" width="28" height="16" rx="8" fill={a.accent} />
            <circle cx={APP_W - 110 - 20} cy="53" r="6" fill={a.onAccent} />
            <rect y="70" width={APP_W - 124} height="1" fill={a.separator} />
            <text x="0" y="92" fontSize="11" fill={a.text}>
              {truncate(title("appearance.density"), 14)}
            </text>
            <rect x={APP_W - 110 - 76} y="80" width="64" height="18" rx="5" fill={a.control} />
            <rect x={APP_W - 110 - 74} y="82" width="30" height="14" rx="4" fill={a.elevated} />
            <rect y="106" width={APP_W - 124} height="1" fill={a.separator} />
            <text x="0" y="128" fontSize="11" fill={a.text}>
              {truncate(title("app.globalHotKey"), 20)}
            </text>
            <rect
              x={APP_W - 110 - 40}
              y="117"
              width="28"
              height="16"
              rx="8"
              fill={a.control}
              stroke={a.controlStroke}
            />
            <circle cx={APP_W - 110 - 32} cy="125" r="6" fill={a.icon} />
            <text x="0" y="146" fontSize="10" fill={a.textSecondary}>
              {truncate(help("app.globalHotKey"), 34)}
            </text>
            <rect y="160" width={APP_W - 124} height="1" fill={a.separator} />
            <text x="0" y="184" fontSize="11" fill={a.accentText}>
              {truncate(t("settingsWindow.showInFinder"), 18)}
            </text>
            <rect x={APP_W - 110 - 70} y="172" width="58" height="20" rx="5" fill={a.accent} />
            <text x={APP_W - 110 - 41} y="186" fontSize="11" fontWeight="500" textAnchor="middle" fill={a.onAccent}>
              {truncate(t("settingsPage.reset"), 8)}
            </text>
          </g>
        </g>
        <rect x="0.5" y="0.5" width={APP_W - 1} height={H - 1} rx="9" fill="none" stroke={a.separator} />
      </g>
    </svg>
  );
}

/** The 16 ANSI colors and the four named colors of a theme, labeled. */
export function ThemePalette({ theme, separator }: { theme: GhosttyTheme; separator: string }) {
  const swatch = 30;
  const step = 34;
  const left = 64;
  const named: Array<[string, string]> = [
    [t("settingsPage.theme.background"), theme.background],
    [t("settingsPage.theme.foreground"), theme.foreground],
    [t("settingsPage.theme.cursor"), theme.cursorColor ?? theme.foreground],
    [t("settingsPage.theme.selection"), theme.selectionBackground ?? mixHex(theme.background, theme.foreground, 0.25)],
  ];
  return (
    <svg
      className="theme-palette"
      viewBox={`0 0 ${W} 72`}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- an inline SVG drawing; an <img> cannot draw the theme.
      role="img"
      aria-label={t("settingsPage.theme.palette")}
    >
      <g fontFamily="-apple-system, BlinkMacSystemFont, system-ui, sans-serif" fontSize="11" fill="currentColor">
        <text x="0" y="20" className="theme-palette-label">
          {t("settingsPage.theme.normal")}
        </text>
        <text x="0" y="56" className="theme-palette-label">
          {t("settingsPage.theme.bright")}
        </text>
        {Array.from({ length: 16 }, (_, index) => (
          <rect
            key={index}
            x={left + (index % 8) * step}
            y={index < 8 ? 2 : 38}
            width={swatch}
            height={swatch}
            rx="6"
            fill={theme.palette[index] ?? theme.foreground}
            stroke={separator}
          >
            <title>{`${index} ${theme.palette[index] ?? ""}`}</title>
          </rect>
        ))}
        {named.map(([name, value], index) => (
          <g key={name} transform={`translate(${left + 8 * step + 24 + (index % 2) * 170} ${index < 2 ? 2 : 38})`}>
            <rect width={swatch} height={swatch} rx="6" fill={value} stroke={separator} />
            <text x="40" y="13">
              {name}
            </text>
            <text x="40" y="27" className="theme-palette-hex">
              {value}
            </text>
          </g>
        ))}
      </g>
    </svg>
  );
}

/** `a` mixed toward `b` in sRGB (for a theme without a selection color). */
function mixHex(a: string, b: string, fraction: number): string {
  const channels = (hex: string) => [1, 3, 5].map((index) => parseInt(hex.slice(index, index + 2), 16));
  const x = channels(a);
  const y = channels(b);
  return `#${x
    .map((value, index) =>
      Math.round(value + (y[index]! - value) * fraction)
        .toString(16)
        .padStart(2, "0"),
    )
    .join("")}`;
}

function truncate(value: string, length: number): string {
  return value.length > length ? `${value.slice(0, length - 1).trimEnd()}…` : value;
}
