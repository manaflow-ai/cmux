// The markdown viewer's text size: Cmd-= and Cmd-- (the app key dispatcher's `zoomIn` and `zoomOut`
// page commands) change it one pixel at a time in this viewer, in rich and source mode alike; Cmd-0
// (`zoomReset`) goes back to the default, the `markdown.font.size` setting (Settings > Appearance >
// Markdown Viewer, default 16). The size applies as one factor, `--cmux-md-zoom`, over the body
// and code sizes, so headings, code and a theme.css size scale together. The viewer keeps its size
// across a reload of the page (sessionStorage is per page view), not across tabs.

/** The setting's range and default, as the host's Settings row (MarkdownViewerSettingsSchema). */
export const MARKDOWN_FONT_SIZE = { min: 8, max: 40, fallback: 16 } as const;

export type MarkdownZoomCommand = "zoomIn" | "zoomOut" | "zoomReset";

export function isMarkdownZoomCommand(command: string): command is MarkdownZoomCommand {
  return command === "zoomIn" || command === "zoomOut" || command === "zoomReset";
}

const clamp = (size: number) => Math.min(MARKDOWN_FONT_SIZE.max, Math.max(MARKDOWN_FONT_SIZE.min, size));

/** The default size: `markdown.font.size` in pixels (a number, or a `"17px"` string), else 16. */
export function markdownDefaultFontSize(settings: unknown): number {
  const font = (settings as { font?: { size?: unknown } } | null | undefined)?.font;
  const value = font?.size;
  const pixels =
    typeof value === "number"
      ? value
      : typeof value === "string" && /^\s*\d+(\.\d+)?(px)?\s*$/.test(value)
        ? parseFloat(value)
        : NaN;
  return Number.isFinite(pixels) && pixels > 0 ? clamp(pixels) : MARKDOWN_FONT_SIZE.fallback;
}

/** The size after `command`: one pixel up or down within the range, or the default (null). */
export function nextFontSize(current: number | null, base: number, command: MarkdownZoomCommand): number | null {
  if (command === "zoomReset") return null;
  const from = Math.round(current ?? base);
  const next = clamp(from + (command === "zoomIn" ? 1 : -1));
  return next === base ? null : next;
}

const STORAGE_KEY = "cmux.markdown.fontSize";

/** The storage the size survives a page reload in (sessionStorage; a stand-in in tests). */
export interface ZoomStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

function sessionStore(): ZoomStorage | null {
  try {
    return globalThis.sessionStorage ?? null;
  } catch {
    return null;
  }
}

/**
 * One viewer's text size. `size` null follows the default (the setting, also after it changes);
 * a number is this viewer's own size until Cmd-0.
 */
export class MarkdownFontZoom {
  private size: number | null = null;
  private base: number = MARKDOWN_FONT_SIZE.fallback;

  constructor(
    private readonly root: { style: { setProperty(name: string, value: string): void } },
    private readonly storage: ZoomStorage | null = sessionStore(),
  ) {
    const saved = Number(storage?.getItem(STORAGE_KEY));
    if (Number.isFinite(saved) && saved > 0) this.size = clamp(saved);
  }

  /** The size the body text shows at, in pixels. */
  get fontSize(): number {
    return this.size ?? this.base;
  }

  /** The `markdown` settings changed (or arrived): a viewer at the default follows the new one. */
  setSettings(settings: unknown): void {
    this.base = markdownDefaultFontSize(settings);
    if (this.size === this.base) this.size = null;
    this.apply();
  }

  /** `zoomIn`, `zoomOut` or `zoomReset`. Returns the size it shows now. */
  run(command: MarkdownZoomCommand): number {
    this.size = nextFontSize(this.size, this.base, command);
    try {
      if (this.size === null) this.storage?.removeItem(STORAGE_KEY);
      else this.storage?.setItem(STORAGE_KEY, String(this.size));
    } catch {
      // A full or refused storage only loses the size on the next reload.
    }
    this.apply();
    return this.fontSize;
  }

  private apply(): void {
    this.root.style.setProperty("--cmux-md-zoom", String(Number((this.fontSize / this.base).toFixed(4))));
  }
}
