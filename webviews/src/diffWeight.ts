// How loud a diff reads, shared by every diff surface of cmux NEXT: the diff viewer page
// (pierre-options.ts `codeViewUnsafeCSS`) and the agent pane's diff cards and changes view
// (agent-session/acpmux/diffTheme.ts). Leo (2026-10-15): the diff viewer was too bold.
// Code, line numbers and file headers draw at the regular weight, a changed row takes a low
// tint of its add/remove color, and the word highlight sits a step above that row tint so a
// changed word still reads. Only weight and color strength live here; the code font is the
// terminal's (appearance.ts, `--cmux-diff-code-font-family`).

/** The weight of diff code, line numbers and file headers. */
export const DIFF_TEXT_WEIGHT = 400;

/** The weight of Pierre's intra-line diff highlight, one step above the surrounding code. */
export const DIFF_WORD_WEIGHT = 600;

/** Percent of the add/remove color behind a changed row. */
export const DIFF_LINE_TINT = 14;

/** Percent of the add/remove color behind a changed word, drawn over the row tint. */
export const DIFF_WORD_TINT = 22;

/** Percent of the add/remove color behind a changed row's line number. */
export const DIFF_GUTTER_TINT = 8;

/** Percent of the add/remove color in a changed row's line number, over the muted number color. */
export const DIFF_NUMBER_TINT = 60;

/**
 * Diff Colors Muted's tints (Leo, 2026-10-15): with Theme's calmer 14% row, Muted's dimmer color
 * at the same tints read almost like Theme, so Muted takes its own, clearly quieter tints.
 */
export const DIFF_MUTED_LINE_TINT = 7;
export const DIFF_MUTED_WORD_TINT = 12;
export const DIFF_MUTED_GUTTER_TINT = 4;

/** `color-mix` of `color` at `percent` over transparent. */
export function diffTint(color: string, percent: number): string {
  return `color-mix(in srgb, ${color} ${percent}%, transparent)`;
}

/** The page-root variable each mode-dependent tint reads (inherited into a diff's shadow root). */
const TINT_VARIABLES = {
  line: "--cmux-diff-line-tint",
  word: "--cmux-diff-word-tint",
  gutter: "--cmux-diff-gutter-tint",
} as const;
const THEME_TINTS = { line: DIFF_LINE_TINT, word: DIFF_WORD_TINT, gutter: DIFF_GUTTER_TINT } as const;
const MUTED_TINTS = { line: DIFF_MUTED_LINE_TINT, word: DIFF_MUTED_WORD_TINT, gutter: DIFF_MUTED_GUTTER_TINT } as const;

/** `diffTint` whose percent follows the Diff Colors mode (`applyDiffTints`), Theme's by default. */
export function diffModeTint(color: string, kind: keyof typeof TINT_VARIABLES): string {
  return `color-mix(in srgb, ${color} var(${TINT_VARIABLES[kind]}, ${THEME_TINTS[kind]}%), transparent)`;
}

/** Sets the tints for a Diff Colors mode on the page root: Muted's quieter ones, else Theme's. */
export function applyDiffTints(style: CSSStyleDeclaration, mode: string | undefined) {
  for (const kind of Object.keys(TINT_VARIABLES) as (keyof typeof TINT_VARIABLES)[]) {
    if (mode === "muted") style.setProperty(TINT_VARIABLES[kind], `${MUTED_TINTS[kind]}%`);
    else style.removeProperty(TINT_VARIABLES[kind]);
  }
}

/** Regular weight for the code rows, line numbers and Pierre's own header, in a diff's shadow root. */
export const DIFF_WEIGHT_CSS = /* css */ `
:host,
[data-line],
[data-column-number],
[data-diffs-header],
[data-separator-content] {
  font-weight: ${DIFF_TEXT_WEIGHT};
}
[data-diff-span] {
  font-weight: ${DIFF_WORD_WEIGHT};
}`;
