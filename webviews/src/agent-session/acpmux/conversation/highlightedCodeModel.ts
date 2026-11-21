// The fenced code card's styles inside Pierre's shadow root (HighlightedCode.tsx draws the card), kept
// out of the component module so it hot-swaps.
import { diffUnsafeCSS } from "../diffTheme";

/// Pierre's line height: a line of the card's body.
const LINE_HEIGHT = 20;

/// Pierre paints its own lines; they are transparent so the card's fill shows through.
export const codeUnsafeCSS = `${diffUnsafeCSS}
:host {
  --diffs-dark-bg: transparent;
  --diffs-light-bg: transparent;
  --diffs-font-family: var(--cv-mono, var(--cmux-diff-code-font-family, "SF Mono", ui-monospace, Menlo, monospace));
  --diffs-font-size: var(--cv-codeblock-size, 12px);
  --diffs-line-height: var(--cv-codeblock-line-height, ${LINE_HEIGHT}px);
  background: transparent;
}
[data-line] > span { top: 0; }
pre, code, [data-code], [data-content], [data-line] { background: transparent !important; --diffs-line-bg: transparent; }
/* Pierre keeps a strip for its horizontal scrollbar under the lines at all times
   (--diffs-scrollbar-gutter: 6px in WebKit, 0 where scrollbars overlay). It hangs into the card's
   bottom padding instead, so the card is as tall as its lines in every engine, as the plain card
   it replaces is (StreamingCode.tsx), and the text under a closing fence does not move. */
pre[data-file] { display: flow-root; }
[data-code] { margin-bottom: calc(-1 * var(--diffs-scrollbar-gutter, 0px)); }
`;

/// An unlabeled card's first line keeps room after its end for the actions floating over its corner
/// (conversation.css `--cv-code-corner-reserve`, which the shadow root inherits), so it never runs
/// under them once scrolled to its end, and wraps short of them (cmux#30689).
export const cornerUnsafeCSS = `${codeUnsafeCSS}
[data-line="1"] { padding-inline-end: var(--cv-code-corner-reserve, 0px); }
`;
