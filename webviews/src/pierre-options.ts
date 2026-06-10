import type { CodeViewOptions } from "@pierre/diffs";
import type { WorkerInitializationRenderOptions } from "@pierre/diffs/worker";
import { appearanceBackgroundColor, readableColor, type DiffViewerAppearance } from "./appearance";

export type DiffViewerOptions = {
  collapsed: boolean;
  diffIndicators: "bars" | "classic" | "none";
  expandUnchanged: boolean;
  layout: "split" | "unified";
  lineNumbers: boolean;
  showBackgrounds: boolean;
  wordDiffs: boolean;
  wordWrap: boolean;
};

// Fixed height of the custom Graphite-style file header, in px. The CodeView
// virtualizer estimates each file's height from the `diffHeaderHeight` metric
// (it never remeasures the header DOM), so the header element is pinned to this
// exact height in `codeViewUnsafeCSS` AND reported via `itemMetrics` below.
// Keeping the two in lockstep is what prevents per-file layout drift. The header
// content itself is the <DiffFileHeader> React component, wired through the
// `renderCustomHeader` prop on <CodeView> (see App.tsx) — the React layer
// portals it into the virtualized file's header slot, which is why it cannot be
// passed here as a plain option.
export const DIFF_HEADER_HEIGHT = 44;

export function codeViewOptions(
  options: DiffViewerOptions,
  appearance: DiffViewerAppearance,
): CodeViewOptions<any> {
  return {
    itemMetrics: { diffHeaderHeight: DIFF_HEADER_HEIGHT },
    // Graphite-style per-file cards: vertical gap between files plus a little
    // breathing room at the very top/bottom of the scroll content. The
    // virtualizer applies `gap`/padding as item margins, so this is the safe,
    // library-sanctioned way to separate cards without perturbing height
    // measurement. The card frame itself (radius + hairline ring) lives in
    // styles.css on `#viewer diffs-container`.
    layout: { paddingTop: 10, gap: 10, paddingBottom: 16 },
    diffStyle: options.layout,
    diffIndicators: options.diffIndicators,
    overflow: options.wordWrap ? "wrap" : "scroll",
    expandUnchanged: options.expandUnchanged,
    disableBackground: !options.showBackgrounds,
    disableLineNumbers: !options.lineNumbers,
    lineHoverHighlight: "number",
    enableLineSelection: true,
    enableGutterUtility: true,
    lineDiffType: options.wordDiffs ? "word" : "none",
    stickyHeaders: true,
    unsafeCSS: codeViewUnsafeCSS(),
    theme: appearance.theme as any,
    themeType: "system",
  };
}

export function workerHighlighterOptions(
  options: DiffViewerOptions,
  appearance: DiffViewerAppearance,
): WorkerInitializationRenderOptions {
  return {
    theme: appearance.theme as any,
    preferredHighlighter: "shiki-wasm",
    lineDiffType: options.wordDiffs ? "word" : "none",
    maxLineDiffLength: 1000,
    tokenizeMaxLineLength: 1000,
    useTokenTransformer: false,
  };
}

export function codeViewUnsafeCSS(): string {
  return `
    :host {
      --diffs-light-bg: var(--cmux-diff-bg);
      --diffs-dark-bg: var(--cmux-diff-bg);
      --diffs-bg-buffer-override: color-mix(in srgb, var(--cmux-diff-fg) 12%, transparent);
      --diffs-bg-context-override: var(--cmux-diff-bg);
      --diffs-bg-context-gutter-override: var(--cmux-diff-bg);
      --cmux-diff-surface-bg: light-dark(
        color-mix(in srgb, var(--cmux-diff-bg) 96%, #f5f5f0),
        color-mix(in srgb, var(--cmux-diff-bg) 94%, #3e3d32)
      );
      --diffs-bg-separator-override: var(--cmux-diff-surface-bg);
      --diffs-addition-color-override: light-dark(var(--cmux-diff-addition-fg-light), var(--cmux-diff-addition-fg-dark));
      --diffs-deletion-color-override: light-dark(var(--cmux-diff-deletion-fg-light), var(--cmux-diff-deletion-fg-dark));
      --diffs-fg-number-addition-override: var(--diffs-addition-base);
      --diffs-fg-number-deletion-override: var(--diffs-deletion-base);
      /* Muted, low-contrast line-number gutter (Graphite keeps the gutter quiet
         so the code reads first). The library default is 65% toward the
         foreground; pull it back toward the background for a calmer column. */
      --diffs-fg-number-override: light-dark(
        color-mix(in lab, var(--cmux-diff-fg) 50%, var(--cmux-diff-bg)),
        color-mix(in lab, var(--cmux-diff-fg) 46%, var(--cmux-diff-bg))
      );
      /* Soft, desaturated full-line tints with a visibly darker tint on the
         changed tokens (word/intraline emphasis), matching Graphite's
         translucent diff fills. The library default makes the emphasis tint
         *weaker* than the line tint; invert that so changed tokens stand out. */
      --diffs-bg-addition-override: light-dark(
        color-mix(in srgb, var(--diffs-addition-base) 15%, transparent),
        color-mix(in srgb, var(--diffs-addition-base) 20%, transparent)
      );
      --diffs-bg-deletion-override: light-dark(
        color-mix(in srgb, var(--diffs-deletion-base) 15%, transparent),
        color-mix(in srgb, var(--diffs-deletion-base) 20%, transparent)
      );
      --diffs-bg-addition-emphasis-override: light-dark(
        color-mix(in srgb, var(--diffs-addition-base) 38%, transparent),
        color-mix(in srgb, var(--diffs-addition-base) 42%, transparent)
      );
      --diffs-bg-deletion-emphasis-override: light-dark(
        color-mix(in srgb, var(--diffs-deletion-base) 38%, transparent),
        color-mix(in srgb, var(--diffs-deletion-base) 42%, transparent)
      );
    }
    :host,
    pre,
    code {
      background-color: var(--cmux-diff-bg);
    }
    [data-diffs-header] {
      container-type: scroll-state;
      container-name: sticky-header;
      /* Pinned to the exact \`diffHeaderHeight\` metric (see DIFF_HEADER_HEIGHT):
         the virtualizer estimates file heights from that constant and never
         remeasures the header, so a fixed height keeps the per-file layout from
         drifting. The divider is an inset shadow rather than a border-bottom for
         the same reason (a border would add a pixel the metric doesn't know
         about). */
      height: ${DIFF_HEADER_HEIGHT}px;
      min-height: ${DIFF_HEADER_HEIGHT}px;
      padding-inline: 14px !important;
      display: flex;
      align-items: center;
      background-color: var(--cmux-diff-surface-bg) !important;
      box-shadow: inset 0 -1px 0 var(--cmux-diff-border);
    }
    /* The custom header (renderDiffFileHeader) is projected through this slot
       wrapper, which @pierre/diffs creates in the *light* DOM — so the wrapper
       and the header itself are styled from styles.css, not here. Make the slot
       stretch across the band. */
    ::slotted([slot='header-custom']) {
      flex: 1 1 auto;
      min-width: 0;
    }
    [data-line-type='change-addition']:where([data-column-number], [data-gutter-buffer]) {
      color: var(--diffs-addition-base);
    }
    [data-line-type='change-deletion']:where([data-column-number], [data-gutter-buffer]) {
      color: var(--diffs-deletion-base);
    }
    [data-gutter-buffer='buffer'] {
      background-position: 5px 0;
      background-size: 8px 8px;
      background-origin: border-box;
      background-image: repeating-linear-gradient(
        -45deg,
        transparent,
        transparent 4.242px,
        var(--diffs-bg-buffer) 4.242px,
        var(--diffs-bg-buffer) 5.656px
      );
    }
    [data-separator='line-info'] {
      background-color: var(--diffs-bg-separator);
    }
    [data-separator='line-info'] [data-separator-wrapper],
    [data-separator='line-info'] [data-separator-content],
    [data-separator='line-info'] [data-expand-button] {
      background-color: transparent;
    }
    /* "Expand context" / show-more-lines affordances between hunks: quiet by
       default, clearly interactive on hover (a deliberate control rather than a
       default-styled link). */
    [data-separator='line-info'] [data-separator-content],
    [data-separator='line-info'] [data-expand-button] {
      color: var(--diffs-fg-number);
    }
    [data-expand-index] [data-separator-content]:hover {
      color: var(--cmux-diff-fg);
      background-color: var(--cmux-diff-hover-bg);
      text-decoration: none;
    }
    [data-expand-button]:hover {
      color: var(--cmux-diff-fg);
      background-color: var(--cmux-diff-hover-bg);
    }
    [data-diffs-header=default],
    [data-diffs-header=default] [data-additions-count],
    [data-diffs-header=default] [data-deletions-count],
    [data-separator-wrapper],
    [data-separator-content],
    [data-unmodified-lines],
    [data-expand-button] {
      font-family: var(--diffs-header-font-family, var(--diffs-header-font-fallback));
    }
  `;
}

export function fileTreeUnsafeCSS(): string {
  return `
    :host {
      display: block;
      height: 100%;
      min-height: 0;
      background-color: var(--cmux-diff-sidebar-bg);
    }
    [data-file-tree-search-container][data-open='false'] {
      display: none;
    }
    [data-file-tree-search-container] {
      margin: 0 4px 8px 0;
      padding: 0 5px 8px 1px;
      border-bottom: 1px solid var(--trees-border-color);
    }
    [data-file-tree-virtualized-scroll='true'] {
      height: 100%;
      min-height: 0;
      overflow: auto;
      background-color: var(--cmux-diff-sidebar-bg);
      padding-inline-start: 0;
      padding-inline-end: 2px;
      margin-inline-end: 2px;
      scrollbar-gutter: stable;
    }
    [data-item-section='content'] {
      flex: 1 1 auto;
      min-width: 0;
    }
    [data-item-section='git'] {
      opacity: 0.75;
    }
    [data-item-type='folder'] {
      color: color-mix(in lab, var(--trees-fg) 85%, var(--trees-bg));
      font-weight: 500;
    }
    [data-file-tree-sticky-overlay-content] {
      background-color: var(--cmux-diff-tree-sticky-bg, var(--cmux-diff-sidebar-bg)) !important;
      box-shadow: 0 1px 0 var(--trees-border-color);
    }
  `;
}

export function shikiThemeFromGhostty(theme: any, appearance: DiffViewerAppearance) {
  const palette = theme.palette ?? {};
  const background = appearanceBackgroundColor(theme.background, appearance);
  const foreground = readableColor(theme.foreground, background, theme.type === "light" ? "#000000" : "#ffffff");
  const tokenColor = (value: unknown, fallback = foreground) => readableColor(value, background, fallback);
  return {
    name: theme.name,
    displayName: theme.ghosttyName,
    type: theme.type,
    colors: {
      "editor.background": background,
      "editor.foreground": foreground,
      "terminal.background": background,
      "terminal.foreground": foreground,
      "terminal.ansiBlack": tokenColor(palette["0"]),
      "terminal.ansiRed": tokenColor(palette["1"]),
      "terminal.ansiGreen": tokenColor(palette["2"]),
      "terminal.ansiYellow": tokenColor(palette["3"]),
      "terminal.ansiBlue": tokenColor(palette["4"]),
      "terminal.ansiMagenta": tokenColor(palette["5"]),
      "terminal.ansiCyan": tokenColor(palette["6"]),
      "terminal.ansiWhite": tokenColor(palette["7"]),
      "terminal.ansiBrightBlack": tokenColor(palette["8"]),
      "terminal.ansiBrightRed": tokenColor(palette["9"], tokenColor(palette["1"])),
      "terminal.ansiBrightGreen": tokenColor(palette["10"], tokenColor(palette["2"])),
      "terminal.ansiBrightYellow": tokenColor(palette["11"], tokenColor(palette["3"])),
      "terminal.ansiBrightBlue": tokenColor(palette["12"], tokenColor(palette["4"])),
      "terminal.ansiBrightMagenta": tokenColor(palette["13"], tokenColor(palette["5"])),
      "terminal.ansiBrightCyan": tokenColor(palette["14"], tokenColor(palette["6"])),
      "terminal.ansiBrightWhite": tokenColor(palette["15"]),
      "gitDecoration.addedResourceForeground": tokenColor(palette["10"], tokenColor(palette["2"], "#32d74b")),
      "gitDecoration.deletedResourceForeground": tokenColor(palette["9"], tokenColor(palette["1"], "#ff453a")),
      "gitDecoration.modifiedResourceForeground": tokenColor(palette["12"], tokenColor(palette["4"], "#0a84ff")),
      "editor.selectionBackground": theme.selectionBackground,
      "editor.selectionForeground": theme.selectionForeground,
    },
    tokenColors: [
      { settings: { foreground, background } },
      { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: tokenColor(palette["8"]), fontStyle: "italic" } },
      { scope: ["string", "constant.other.symbol"], settings: { foreground: tokenColor(palette["2"]) } },
      { scope: ["constant.numeric", "constant.language", "support.constant"], settings: { foreground: tokenColor(palette["3"]) } },
      { scope: ["keyword", "storage", "storage.type"], settings: { foreground: tokenColor(palette["5"]) } },
      { scope: ["entity.name.function", "support.function"], settings: { foreground: tokenColor(palette["4"]) } },
      { scope: ["entity.name.type", "entity.name.class", "support.type"], settings: { foreground: tokenColor(palette["6"]) } },
      { scope: ["variable", "meta.definition.variable"], settings: { foreground } },
      { scope: ["invalid", "message.error"], settings: { foreground: tokenColor(palette["9"], tokenColor(palette["1"])) } },
    ],
  };
}
