// The Theme section's preview (P3): a sample terminal in the theme's own colors (16 ANSI colors,
// background, foreground, cursor, selection) beside a sample app surface in the app tokens the
// theme derives (src/theme/appTheme.ts), then the palette itself. Drawn as SVG: the preview is
// an image of another theme, so it never paints the page's own surfaces (render rule).
import { useId } from "react";
import { AppIllustration } from "./AppIllustration";
import type { AppTheme } from "../../../theme/appTheme";
import type { GhosttyTheme } from "../../../theme/ghosttyTheme";

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

      <AppIllustration app={app} clip={clip} x={APP_X} width={APP_W} height={H} />
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
