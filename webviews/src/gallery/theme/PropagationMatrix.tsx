// l10n-allow-file: a gallery page; its labels are setting keys and token names, not shipped UI.
// The theme propagation matrix on a gallery stage (`theme.propagation`): the stage turns every knob
// live on its own document, through the app's `window.cmuxTheme.apply` and `applyAgentTheme`, reads
// every surface back, and draws the result, then puts its own theme back. The same run is the
// regression test (test/theme-propagation.test.ts); this page shows it, with the native-only knobs
// and the contrast of text over glass and wallpaper for a row of famous themes.
import { useEffect, useState } from "react";
import { applyAgentTheme } from "../../agent-session/shared/theme";
import type { GhosttyTheme } from "./ghostty";
import {
  failures,
  glassContrast,
  KNOBS,
  NATIVE_KNOBS,
  readSurfaces,
  runPropagationMatrix,
  SURFACE_LABELS,
  SURFACES,
  type Cell,
  type MatrixRow,
} from "./propagation";
import { themeTokens } from "./web";

export type PropagationMatrixProps = { show?: "matrix" | "contrast" };

const CONTRAST_THEMES = [
  "Catppuccin Mocha",
  "Catppuccin Latte",
  "Gruvbox Dark",
  "Rose Pine Dawn",
  "Dracula",
  "Nord",
  "Solarized Light",
  "GitHub Dark High Contrast",
];

const CELL_TEXT: Record<Cell, string> = { live: "live", missed: "MISSED", still: "-", stray: "STRAY" };

type CmuxThemeHost = { cmuxTheme?: { current: unknown; apply(payload: unknown): void } };

/** Runs the matrix on this document and restores the stage's own theme and attributes after. */
function runHere(themes: readonly GhosttyTheme[]): MatrixRow[] {
  const host = window as unknown as CmuxThemeHost;
  const root = document.documentElement;
  const theme = host.cmuxTheme;
  if (!theme) return [];
  const before = theme.current;
  const style = root.getAttribute("style");
  const attributes = ["data-borders", "data-theme", "data-status-indicators", "data-working-look", "class"].map(
    (name) => [name, root.getAttribute(name)] as const,
  );
  try {
    return runPropagationMatrix(
      (applied) => {
        theme.apply(applied.web);
        applyAgentTheme(applied.agent);
      },
      () => readSurfaces(document),
      themes,
    );
  } finally {
    if (style === null) root.removeAttribute("style");
    else root.setAttribute("style", style);
    for (const [name, value] of attributes) {
      if (value === null) root.removeAttribute(name);
      else root.setAttribute(name, value);
    }
    if (before) theme.apply(before);
  }
}

const ratio = (value: number) => `${value.toFixed(2)}:1`;

export function propagationMatrix(themes: readonly GhosttyTheme[]) {
  return function PropagationMatrix({ show = "matrix" }: PropagationMatrixProps) {
    const [rows, setRows] = useState<MatrixRow[] | null>(null);
    useEffect(() => setRows(runHere(themes)), []);
    if (show === "contrast") {
      return (
        <table className="theme-matrix" data-testid="theme-contrast">
          <thead>
            <tr>
              <th>Theme</th>
              <th>Tooltip</th>
              <th>Card</th>
              <th>Text on wallpaper tint</th>
              <th>Secondary on wallpaper tint</th>
            </tr>
          </thead>
          <tbody>
            {CONTRAST_THEMES.map((name) => {
              const theme = themes.find((candidate) => candidate.name === name);
              if (!theme) return null;
              const measured = glassContrast(themeTokens(theme));
              const mark = (value: number) => (value >= 4.5 ? "theme-matrix-pass" : "theme-matrix-fail");
              return (
                <tr key={name}>
                  <th scope="row">{name}</th>
                  <td className={mark(measured.tooltip)}>{ratio(measured.tooltip)}</td>
                  <td className={mark(measured.card)}>{ratio(measured.card)}</td>
                  <td className={mark(measured.wallpaperText)}>{ratio(measured.wallpaperText)}</td>
                  <td className={mark(measured.wallpaperSecondary)}>{ratio(measured.wallpaperSecondary)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      );
    }
    const failed = rows ? failures(rows) : [];
    return (
      <div className="theme-matrix-page">
        <p className="theme-matrix-summary" data-testid="theme-matrix-summary">
          {rows === null
            ? "Running…"
            : failed.length === 0
              ? `${rows.length} knobs, every surface live`
              : failed.join(", ")}
        </p>
        <table className="theme-matrix" data-testid="theme-matrix">
          <thead>
            <tr>
              <th>Knob</th>
              {SURFACES.map((surface) => (
                <th key={surface}>{SURFACE_LABELS[surface]}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {(rows ?? KNOBS.map((knob) => ({ knob, cells: null }))).map(({ knob, cells }) => (
              <tr key={knob.key}>
                <th scope="row">
                  <code>{knob.key}</code>
                  <span className="theme-matrix-note">{knob.label}</span>
                </th>
                {SURFACES.map((surface) => (
                  <td key={surface} className={cells ? `theme-matrix-${cells[surface]}` : undefined}>
                    {cells ? CELL_TEXT[cells[surface]] : "…"}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
        <table className="theme-matrix" data-testid="theme-matrix-native">
          <thead>
            <tr>
              <th>Native-only knob</th>
              <th>Live?</th>
              <th>Proof</th>
            </tr>
          </thead>
          <tbody>
            {NATIVE_KNOBS.map((knob) => (
              <tr key={knob.key}>
                <th scope="row">
                  <code>{knob.key}</code>
                </th>
                <td className={knob.status === "live" ? "theme-matrix-live" : "theme-matrix-missed"}>{knob.status}</td>
                <td>{knob.proof}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    );
  };
}
