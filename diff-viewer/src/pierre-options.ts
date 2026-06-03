import type { CodeViewOptions } from "@pierre/diffs";
import type { WorkerInitializationRenderOptions } from "@pierre/diffs/worker";
import { appearanceBackgroundColor, type DiffViewerAppearance } from "./appearance";

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
    [data-diffs-header] {
      container-type: scroll-state;
      container-name: sticky-header;
    }
    @container sticky-header scroll-state(stuck: top) {
      [data-diffs-header]::after {
        position: absolute;
        bottom: -1px;
        left: 0;
        width: 100%;
        height: 1px;
        content: '';
        background-color: var(--cmux-diff-border);
      }
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
    [data-file-tree-search-container][data-open='false'] {
      display: none;
    }
    [data-file-tree-search-container] {
      margin: 0 4px 8px 0;
      padding: 0 5px 8px 1px;
      border-bottom: 1px solid var(--trees-border-color);
    }
    [data-file-tree-virtualized-scroll='true'] {
      padding-inline-start: 0;
      padding-inline-end: 2px;
      margin-inline-end: 2px;
    }
    [data-item-contains-git-change='true'] > [data-item-section='git'] {
      display: none;
    }
    [data-item-type='folder'] {
      color: color-mix(in lab, var(--trees-fg) 85%, var(--trees-bg));
      font-weight: 500;
    }
    [data-file-tree-sticky-overlay-content] {
      box-shadow: 0 1px 0 var(--trees-border-color);
    }
  `;
}

export function shikiThemeFromGhostty(theme: any, appearance: DiffViewerAppearance) {
  const palette = theme.palette ?? {};
  const foreground = theme.foreground;
  const background = appearanceBackgroundColor(theme.background, appearance);
  return {
    name: theme.name,
    displayName: theme.ghosttyName,
    type: theme.type,
    colors: {
      "editor.background": background,
      "editor.foreground": foreground,
      "terminal.background": background,
      "terminal.foreground": foreground,
      "terminal.ansiBlack": palette["0"] ?? foreground,
      "terminal.ansiRed": palette["1"] ?? foreground,
      "terminal.ansiGreen": palette["2"] ?? foreground,
      "terminal.ansiYellow": palette["3"] ?? foreground,
      "terminal.ansiBlue": palette["4"] ?? foreground,
      "terminal.ansiMagenta": palette["5"] ?? foreground,
      "terminal.ansiCyan": palette["6"] ?? foreground,
      "terminal.ansiWhite": palette["7"] ?? foreground,
      "terminal.ansiBrightBlack": palette["8"] ?? foreground,
      "terminal.ansiBrightRed": palette["9"] ?? palette["1"] ?? foreground,
      "terminal.ansiBrightGreen": palette["10"] ?? palette["2"] ?? foreground,
      "terminal.ansiBrightYellow": palette["11"] ?? palette["3"] ?? foreground,
      "terminal.ansiBrightBlue": palette["12"] ?? palette["4"] ?? foreground,
      "terminal.ansiBrightMagenta": palette["13"] ?? palette["5"] ?? foreground,
      "terminal.ansiBrightCyan": palette["14"] ?? palette["6"] ?? foreground,
      "terminal.ansiBrightWhite": palette["15"] ?? foreground,
      "gitDecoration.addedResourceForeground": palette["10"] ?? palette["2"] ?? "#32d74b",
      "gitDecoration.deletedResourceForeground": palette["9"] ?? palette["1"] ?? "#ff453a",
      "gitDecoration.modifiedResourceForeground": palette["12"] ?? palette["4"] ?? "#0a84ff",
      "editor.selectionBackground": theme.selectionBackground,
      "editor.selectionForeground": theme.selectionForeground,
    },
    tokenColors: [
      { settings: { foreground, background } },
      { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: palette["8"] ?? foreground, fontStyle: "italic" } },
      { scope: ["string", "constant.other.symbol"], settings: { foreground: palette["2"] ?? foreground } },
      { scope: ["constant.numeric", "constant.language", "support.constant"], settings: { foreground: palette["3"] ?? foreground } },
      { scope: ["keyword", "storage", "storage.type"], settings: { foreground: palette["5"] ?? foreground } },
      { scope: ["entity.name.function", "support.function"], settings: { foreground: palette["4"] ?? foreground } },
      { scope: ["entity.name.type", "entity.name.class", "support.type"], settings: { foreground: palette["6"] ?? foreground } },
      { scope: ["variable", "meta.definition.variable"], settings: { foreground } },
      { scope: ["invalid", "message.error"], settings: { foreground: palette["9"] ?? palette["1"] ?? foreground } },
    ],
  };
}
