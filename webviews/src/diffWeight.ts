// How loud a diff reads, shared by every diff surface of cmux NEXT: the diff viewer page
// (pierre-options.ts `codeViewUnsafeCSS`) and the agent pane's diff cards and changes view
// (agent-session/acpmux/diffTheme.ts). Leo (2026-10-15): the diff viewer was too bold.
// Code, line numbers and file headers draw at the regular weight, a changed row takes a low
// tint of its add/remove color, and the word highlight sits a step above that row tint so a
// changed word still reads. Only weight and color strength live here; the code font is the
// terminal's (appearance.ts, `--cmux-diff-code-font-family`).

/** The weight of diff code, line numbers and file headers. */
export const DIFF_TEXT_WEIGHT = 400;

/** Percent of the add/remove color behind a changed row. */
export const DIFF_LINE_TINT = 14;

/** Percent of the add/remove color behind a changed word, drawn over the row tint. */
export const DIFF_WORD_TINT = 22;

/** Percent of the add/remove color behind a changed row's line number. */
export const DIFF_GUTTER_TINT = 8;

/** Percent of the add/remove color in a changed row's line number, over the muted number color. */
export const DIFF_NUMBER_TINT = 60;

/** `color-mix` of `color` at `percent` over transparent. */
export function diffTint(color: string, percent: number): string {
  return `color-mix(in srgb, ${color} ${percent}%, transparent)`;
}

/** Regular weight for the code rows, line numbers and Pierre's own header, in a diff's shadow root. */
export const DIFF_WEIGHT_CSS = /* css */ `
:host,
[data-line],
[data-column-number],
[data-diffs-header],
[data-separator-content] {
  font-weight: ${DIFF_TEXT_WEIGHT};
}`;
