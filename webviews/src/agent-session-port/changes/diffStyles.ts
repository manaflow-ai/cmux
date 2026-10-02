// CSS injected into each @pierre/diffs shadow root (options.unsafeCSS) so the renderer
// matches Codex: SF Mono 12px / 21.6px rows, a 4ch line-number column, dark gutters on
// changed rows, 52px "N unmodified lines" expand buttons, and an always-visible
// overlay-style horizontal scrollbar.
import { codexColors as c } from "./theme";

export const diffUnsafeCSS = /* css */ `
:host {
  --diffs-font-family: "SF Mono", SFMono-Regular, ui-monospace, Menlo, monospace;
  --diffs-header-font-family: system-ui, -apple-system, BlinkMacSystemFont, sans-serif;
  --diffs-font-size: 12px;
  --diffs-line-height: 21.6px;
  --diffs-dark-bg: ${c.bg};
  --diffs-dark: ${c.fg};
  --diffs-min-number-column-width: 4ch;
  --diffs-dark-addition-color: ${c.addition};
  --diffs-dark-deletion-color: ${c.deletion};
  --diffs-fg-number-override: ${c.number};
  --diffs-bg-separator-override: ${c.separatorBg};
  --diffs-gap-block: 0px;
  --diffs-scrollbar-gutter-override: 0px;
  background: ${c.bg};
}

[data-column-number][data-line-type="change-addition"],
[data-gutter-buffer][data-line-type="change-addition"] {
  --diffs-line-bg: ${c.additionGutter};
}
[data-column-number][data-line-type="change-deletion"],
[data-gutter-buffer][data-line-type="change-deletion"] {
  --diffs-line-bg: ${c.deletionGutter};
}
[data-line][data-line-type="change-addition"] { --diffs-line-bg: ${c.additionLine}; }
[data-line][data-line-type="change-deletion"] { --diffs-line-bg: ${c.deletionLine}; }

[data-indicators="bars"] [data-line-type="change-deletion"][data-column-number]::before {
  background-image: linear-gradient(0deg, ${c.deletionLine} 50%, ${c.deletion} 50%);
}

/* Electron puts SF Mono glyphs 1px lower in the 21.6px row than this Chromium does. */
[data-line] > span, [data-line-number-content] { position: relative; top: 1px; }

/* Expand rows ("869 unmodified lines"). */
[data-separator="line-info"] { height: 32px; }
[data-separator="line-info"] [data-separator-wrapper],
[data-separator="line-info"] [data-separator-wrapper][data-separator-multi-button] {
  grid-template-columns: 54px auto;
}
[data-expand-button] {
  color: ${c.separatorFg};
  border-right-width: 1px;
}
[data-separator-content] {
  color: ${c.separatorFg};
  font-size: 12px;
  padding: 0 9px;
}

/* The file header (ChangesPane's custom header in this slot) sticks to the top of the diff
   list while the rest of its file scrolls under it. */
[data-diffs-header] { position: sticky; top: 0; z-index: 3; }

/* Native scrollbars are hidden; ChangesPane draws overlay thumbs (OverlayScrollbar.tsx). */
[data-code] { scrollbar-width: none; }
`;
