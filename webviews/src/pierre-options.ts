import { PIERRE_DIFFS_SCROLLER_CSS, PIERRE_TREES_SCROLLER_CSS } from "./scrollers";
import { DIFF_NUMBER_TINT, DIFF_WEIGHT_CSS, diffModeTint } from "./diffWeight";
import type { CodeViewOptions } from "@pierre/diffs";
import type { WorkerInitializationRenderOptions } from "@pierre/diffs/worker";
import {
  appearanceBackgroundColor,
  readableColor,
  type DiffChangeColors,
  type DiffViewerAppearance,
} from "./appearance";
import { pageSyntaxVariable, syntaxRoleColors, syntaxTokenRules, type SyntaxRoleName } from "./syntax-theme";

export type DiffViewerOptions = {
  collapsed: boolean;
  /** Diff Colors, the Settings-only add/remove palette (appearance.ts `setDiffChangeColors`). */
  colors: DiffChangeColors;
  diffIndicators: "bars" | "classic" | "none";
  expandUnchanged: boolean;
  /** The delineated diff: files in kind order, code first (diff-kind-groups.ts). */
  groupByKind: boolean;
  /**
   * Hide white space: the sidecar diffs with `--ignore-all-space` (session.ts
   * `diffSessionRequest`), so it reloads the diff and is not a render option.
   */
  hideWhitespace: boolean;
  /**
   * Hide imports: the page leaves import-only hunks out of each file's patch
   * (diff-viewer/importHunks.ts), so it reloads the diff. Not saved: it lasts for the tab.
   */
  hideImports: boolean;
  /**
   * Load full files: each shown file's two sides load (diff-viewer/fullFiles.ts), so its
   * "N unmodified lines" rows expand from their chevrons, `EXPANSION_LINE_COUNT` lines a click.
   * Nothing expands by itself. Not saved: it lasts for the tab.
   */
  loadFullFiles: boolean;
  /**
   * Rich preview: Markdown and image files get a Preview button that opens their sheet
   * (diff-viewer/RichPreviewSheet.tsx). Not saved: it lasts for the tab.
   */
  richPreview: boolean;
  /** `auto` draws split while the viewer is wide enough for two readable sides, unified below. */
  layout: "split" | "unified" | "auto";
  lineNumbers: boolean;
  showBackgrounds: boolean;
  /** The floating Stage all / Revert all bar (`diff.showBulkActions`, Settings only). */
  showBulkActions: boolean;
  wordDiffs: boolean;
  wordWrap: boolean;
};

/** How many unchanged lines one press of a gap's chevron shows (Load full files). */
export const EXPANSION_LINE_COUNT = 20;

/** The options a diff is drawn with: `auto` resolved to the layout the viewer width allows. */
export type DrawnDiffOptions = Omit<DiffViewerOptions, "layout"> & { layout: "split" | "unified" };

/** Height of a file header row; also the virtualizer's header metric. */
export const DIFF_FILE_HEADER_HEIGHT = 38;

export function codeViewOptions(options: DrawnDiffOptions, appearance: DiffViewerAppearance): CodeViewOptions<any> {
  return {
    layout: { paddingTop: 0, gap: 1, paddingBottom: 0 },
    itemMetrics: { diffHeaderHeight: DIFF_FILE_HEADER_HEIGHT },
    diffStyle: options.layout,
    diffIndicators: options.diffIndicators,
    overflow: options.wordWrap ? "wrap" : "scroll",
    expandUnchanged: options.expandUnchanged,
    expansionLineCount: EXPANSION_LINE_COUNT,
    disableBackground: !options.showBackgrounds,
    disableLineNumbers: !options.lineNumbers,
    lineHoverHighlight: "number",
    enableLineSelection: true,
    enableGutterUtility: true,
    lineDiffType: lineDiffType(options),
    stickyHeaders: true,
    unsafeCSS: codeViewUnsafeCSS(),
    theme: appearance.theme as any,
    themeType: "system",
  };
}

/**
 * Word changes: `word-alt`, which joins changed words split only by a space into one mark, so a
 * renamed call reads as one change rather than a row of fragments (GitHub's look); `none` when off.
 */
function lineDiffType(options: Pick<DiffViewerOptions, "wordDiffs">): "word-alt" | "none" {
  return options.wordDiffs ? "word-alt" : "none";
}

export function workerHighlighterOptions(
  options: DiffViewerOptions,
  appearance: DiffViewerAppearance,
  langs: string[] = ["text"],
): WorkerInitializationRenderOptions {
  return {
    langs: langs as WorkerInitializationRenderOptions["langs"],
    theme: appearance.theme as any,
    preferredHighlighter: "shiki-wasm",
    lineDiffType: lineDiffType(options),
    maxLineDiffLength: 1000,
    tokenizeMaxLineLength: 1000,
    useTokenTransformer: false,
  };
}

export function codeViewUnsafeCSS(): string {
  return `
    /* An inline preview (diff-viewer/InlinePreview.tsx) is the only file item the diff tab draws:
       its one placeholder line and its line numbers are hidden, and its annotation (the
       preview) takes the whole width. Diffs are \`pre[data-diff]\` and keep theirs. */
    pre[data-file] {
      --diffs-code-grid: 0 minmax(0, 1fr);
    }
    pre[data-file] [data-gutter],
    pre[data-file] [data-content] > [data-line] {
      display: none;
    }
    pre[data-file] [data-code] {
      padding-block: 0;
    }
    :host {
      /* Code rows and separators are clear over the page's one backdrop
         (only html paints it, so a translucent backdrop never stacks). */
      --diffs-light-bg: transparent;
      --diffs-dark-bg: transparent;
      --diffs-bg-buffer-override: color-mix(in srgb, var(--cmux-diff-fg) 12%, transparent);
      --diffs-bg-context-override: transparent;
      --diffs-bg-context-gutter-override: transparent;
      --diffs-bg-separator-override: transparent;
      background-color: transparent;
      --diffs-addition-color-override: light-dark(var(--cmux-diff-addition-fg-light), var(--cmux-diff-addition-fg-dark));
      --diffs-deletion-color-override: light-dark(var(--cmux-diff-deletion-fg-light), var(--cmux-diff-deletion-fg-dark));
      /* Calm tints and regular weight (diffWeight.ts), the same as the agent pane's diffs. */
      --cmux-diff-number-addition: color-mix(in srgb, var(--diffs-addition-base) ${DIFF_NUMBER_TINT}%, var(--diffs-fg-number));
      --cmux-diff-number-deletion: color-mix(in srgb, var(--diffs-deletion-base) ${DIFF_NUMBER_TINT}%, var(--diffs-fg-number));
      --diffs-fg-number-addition-override: var(--cmux-diff-number-addition);
      --diffs-fg-number-deletion-override: var(--cmux-diff-number-deletion);
      --diffs-bg-addition-override: ${diffModeTint("var(--diffs-addition-base)", "line")};
      --diffs-bg-deletion-override: ${diffModeTint("var(--diffs-deletion-base)", "line")};
      --diffs-bg-addition-number-override: ${diffModeTint("var(--diffs-addition-base)", "gutter")};
      --diffs-bg-deletion-number-override: ${diffModeTint("var(--diffs-deletion-base)", "gutter")};
      --diffs-bg-addition-emphasis-override: ${diffModeTint("var(--diffs-addition-base)", "word")};
      --diffs-bg-deletion-emphasis-override: ${diffModeTint("var(--diffs-deletion-base)", "word")};
    }
    ${DIFF_WEIGHT_CSS}
    pre,
    code {
      background-color: transparent;
    }
    /* R139: the page selects nothing by default (pages/shared/desktop.css) and the shadow
       root inherits that; the code text of each line is content, so it opts back in. Line
       numbers, separators and buffers stay chrome (Pierre keeps them user-select: none). */
    [data-line] {
      -webkit-user-select: text;
      user-select: text;
      cursor: text;
    }
    /* A line listener (Cmd-click opens the file, openFile.ts) makes Pierre show a pointer on
       every line; the text cursor stays, since a plain click selects text. */
    [data-interactive-lines] [data-line] {
      cursor: text;
    }
    /* Over an opaque window the file header paints the backdrop composited onto
       the theme color at full alpha, so scrolled code never shows through it
       (Lawrence). Over an image or a see-through window it is a clear film
       (--cmux-diff-header-bg, a 5% text tint) with a plain blur(20px)
       (styles.css): WebKit frosts the code under it; Chromium cannot blur behind
       the page, so there the code shows through the film. Its
       content is the slotted FileHeader (renderCustomHeader), so the row's
       height is fixed to the virtualizer's diffHeaderHeight metric. */
    [data-diffs-header] {
      height: var(--cmux-diff-file-header-height, ${DIFF_FILE_HEADER_HEIGHT}px);
      min-height: 0;
      display: flex;
      align-items: stretch;
      background-color: var(--cmux-diff-header-bg, var(--cmux-diff-solid-bg));
      -webkit-backdrop-filter: var(--cmux-diff-glass-filter, none);
      backdrop-filter: var(--cmux-diff-glass-filter, none);
      border-bottom: 1px solid var(--cmux-diff-border);
    }
    /* Reduce Transparency: no frost (the host's data-reduce-transparency clears the variable too). */
    @media (prefers-reduced-transparency: reduce) {
      [data-diffs-header] {
        -webkit-backdrop-filter: none;
        backdrop-filter: none;
      }
    }
    [data-line-type='change-addition']:where([data-column-number], [data-gutter-buffer]) {
      color: var(--cmux-diff-number-addition);
    }
    [data-line-type='change-deletion']:where([data-column-number], [data-gutter-buffer]) {
      color: var(--cmux-diff-number-deletion);
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
      background-color: transparent;
    }
    [data-utility-button] {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 18px;
      height: 18px;
      padding: 0;
      border: 0;
      border-radius: 4px;
      background: var(--cmux-diff-accent, light-dark(#0a84ff, #7ab7ff));
      color: light-dark(#fff, #08233f);
      cursor: pointer;
      transform: scale(0.9);
      transition: transform 80ms ease;
    }
    [data-utility-button]:hover {
      transform: scale(1.1);
    }
    [data-utility-button] [data-icon] {
      width: 12px;
      height: 12px;
    }
    [data-separator='line-info'] [data-separator-wrapper],
    [data-separator='line-info'] [data-separator-content],
    [data-separator='line-info'] [data-expand-button] {
      background-color: transparent;
    }
    [data-diffs-header],
    [data-separator-wrapper],
    [data-separator-content],
    [data-unmodified-lines],
    [data-expand-button] {
      font-family: var(--diffs-header-font-family, var(--diffs-header-font-fallback));
    }
    ${PIERRE_DIFFS_SCROLLER_CSS}
  `;
}

/**
 * Narrow tree overrides the CSS-variable surface cannot express (see the
 * `#file-list` host variables in styles.css for colors, weights and spacing).
 */
export function fileTreeUnsafeCSS(): string {
  return `
    :host {
      display: block;
      height: 100%;
      min-height: 0;
      background-color: var(--cmux-diff-files-layer-bg, var(--cmux-diff-files-bg, var(--cmux-diff-solid-bg)));
      /* Icon hues from the terminal theme (styles.css \`--cmux-file-icon-*\`), as in file headers. */
      --trees-icon-gray: var(--cmux-file-icon-gray);
      --trees-icon-red: var(--cmux-file-icon-red);
      --trees-icon-vermilion: var(--cmux-file-icon-vermilion);
      --trees-icon-orange: var(--cmux-file-icon-orange);
      --trees-icon-yellow: var(--cmux-file-icon-yellow);
      --trees-icon-green: var(--cmux-file-icon-green);
      --trees-icon-teal: var(--cmux-file-icon-teal);
      --trees-icon-cyan: var(--cmux-file-icon-cyan);
      --trees-icon-blue: var(--cmux-file-icon-blue);
      --trees-icon-indigo: var(--cmux-file-icon-indigo);
      --trees-icon-purple: var(--cmux-file-icon-purple);
      --trees-icon-pink: var(--cmux-file-icon-pink);
      --trees-icon-mauve: var(--cmux-file-icon-mauve);
      /* A modified or renamed file's name and change square: the terminal palette's blue. */
      --cmux-tree-modified: var(--cmux-diff-count-modified);
    }
    [data-file-tree-virtualized-scroll='true'] {
      height: 100%;
      min-height: 0;
      overflow: auto;
      background-color: var(--cmux-diff-files-layer-bg, var(--cmux-diff-files-bg, var(--cmux-diff-solid-bg)));
      padding-inline-start: 0;
      padding-inline-end: 0;
      scrollbar-gutter: stable;
    }
    [data-item-section='content'] {
      flex: 1 1 auto;
      min-width: 0;
    }
    /* R139: rows are chrome, an arrow cursor like a native source list. */
    [data-type='item'] {
      cursor: default;
    }
    /* Folder names are bright, file names dim (the selected row is bright
       through --trees-selected-fg). The tree has no folder color variable. */
    [data-item-type='folder'] > [data-item-section='content'] {
      color: var(--trees-selected-fg);
    }
    /* "+N -N" (the row decoration, file-tree-stats.ts), right-aligned. */
    [data-item-section='decoration'] {
      flex: 0 0 auto;
      padding-inline-end: 1.5px;
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }
    [data-item-section='decoration'] svg {
      display: block;
    }
    /* An added file's name and icon are green, a deleted one's red (the counts' colors), a modified
       or renamed one's blue (file-tree-stats \`nameColoredGitStatus\`). The row's square says the
       change, so the tree's status letters and folder dots are hidden. */
    [data-item-section='git'] {
      display: none;
    }
    [data-item-git-status='added'] {
      --trees-item-git-status-color: var(--trees-status-added);
    }
    [data-item-git-status='deleted'] {
      --trees-item-git-status-color: var(--trees-status-deleted);
    }
    [data-item-git-status='modified'],
    [data-item-git-status='renamed'] {
      --trees-item-git-status-color: var(--cmux-tree-modified);
    }
    /* Over an image or a see-through window a status-colored name loses contrast against the
       backdrop, so it is mixed toward the text color there (--cmux-diff-tree-name-strength,
       styles.css): the same hue, brighter in a dark theme, darker in a light one. Elsewhere the
       strength is 100%, the status color itself. */
    /* A shortened name's marker covers the hidden text: over glass the solid backdrop
       (--cmux-diff-truncate-marker-bg), since the tree's own surfaces are clear there. */
    [data-type='item'] {
      --truncate-marker-background-color: var(--cmux-diff-truncate-marker-bg, var(--trees-bg));
    }
    [data-item-git-status] > [data-item-section='content'] {
      color: color-mix(
        in oklab,
        var(--trees-item-git-status-color) var(--cmux-diff-tree-name-strength, 100%),
        var(--cmux-diff-fg)
      );
    }
    [data-file-tree-sticky-overlay-content] {
      background-color: var(--cmux-diff-files-sticky-bg, var(--cmux-diff-files-bg, var(--cmux-diff-solid-bg))) !important;
      -webkit-backdrop-filter: var(--cmux-diff-glass-filter, none);
      backdrop-filter: var(--cmux-diff-glass-filter, none);
      box-shadow: 0 1px 0 var(--trees-border-color);
    }
    @media (prefers-reduced-transparency: reduce) {
      [data-file-tree-sticky-overlay-content] {
        -webkit-backdrop-filter: none;
        backdrop-filter: none;
      }
    }
    ${PIERRE_TREES_SCROLLER_CSS}
  `;
}

/// A Shiki theme from a terminal theme. Token colors are page variables (`syntaxTokenColors`)
/// unless `variables` is false, for a renderer that needs literal colors (Monaco).
export function shikiThemeFromGhostty(
  theme: any,
  appearance: DiffViewerAppearance,
  { variables = true }: { variables?: boolean } = {},
) {
  const palette = theme.palette ?? {};
  const renderedBackground = appearanceBackgroundColor(theme.background, appearance);
  const contrastBackground = themeBackgroundForContrast(theme);
  const foreground = readableColor(
    theme.foreground,
    contrastBackground,
    theme.type === "light" ? "#000000" : "#ffffff",
  );
  const tokenColor = (value: unknown, fallback = foreground) => readableColor(value, contrastBackground, fallback);
  return {
    name: theme.name,
    displayName: theme.ghosttyName,
    type: theme.type,
    colors: {
      "editor.background": renderedBackground,
      "editor.foreground": foreground,
      "terminal.background": renderedBackground,
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
    tokenColors: syntaxTokenColors(theme, foreground, renderedBackground, contrastBackground, variables),
  };
}

/// Shiki token rules colored from the terminal's ANSI palette (syntax-theme.ts): each rule reads
/// its role's page variable (`--cmux-syntax-{light,dark}-<role>`, set by applyDiffViewerAppearance
/// with every host theme change), with this theme's color behind it, so a palette change recolors
/// code without registering a new theme.
function syntaxTokenColors(
  theme: any,
  foreground: string,
  renderedBackground: string,
  contrastBackground: string,
  variables: boolean,
) {
  const type = theme.type === "light" ? "light" : "dark";
  const colors = syntaxRoleColors(theme.palette ?? {}, type, contrastBackground, foreground);
  const color = (role: SyntaxRoleName) =>
    variables ? `var(${pageSyntaxVariable(type, role)}, ${colors[role]})` : colors[role];
  // Plain text reads the `variable` role (the foreground), so it follows a theme change too.
  return syntaxTokenRules({ foreground: color("variable"), background: renderedBackground }, color);
}

function themeBackgroundForContrast(theme: any): string {
  if (typeof theme.background === "string" && theme.background.trim() !== "") {
    return theme.background.trim();
  }
  return theme.type === "light" ? "#ffffff" : "#000000";
}
