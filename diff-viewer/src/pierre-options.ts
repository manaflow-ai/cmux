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

export function codeViewOptions(
  options: DiffViewerOptions,
  appearance: DiffViewerAppearance,
): CodeViewOptions<any> {
  return {
    layout: { paddingTop: 0, gap: 1, paddingBottom: 0 },
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
      --diffs-bg-addition-override: color-mix(in srgb, var(--diffs-addition-base) 34%, transparent);
      --diffs-bg-deletion-override: color-mix(in srgb, var(--diffs-deletion-base) 34%, transparent);
      --diffs-bg-addition-emphasis-override: color-mix(in srgb, var(--diffs-addition-base) 30%, transparent);
      --diffs-bg-deletion-emphasis-override: color-mix(in srgb, var(--diffs-deletion-base) 30%, transparent);
    }
    :host,
    pre,
    code {
      background-color: var(--cmux-diff-bg);
    }
    [data-diffs-header] {
      container-type: scroll-state;
      container-name: sticky-header;
      min-height: 30px;
      background-color: var(--cmux-diff-surface-bg) !important;
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
