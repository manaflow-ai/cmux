// The diff viewer's text size (user 2026-11-19: "cmd + and - need to work in diff viewer"). The app's key
// dispatcher sends `zoomIn`, `zoomOut` and `zoomReset` (DiffPageCommand, Cmd-=, Cmd-Shift-=, Cmd--, Cmd-0) while a
// diff tab has the keyboard; each steps the code one pixel within 8-32, as the code editor's and the Markdown
// viewer's zoom do, and Cmd-0 goes back to the default. The size survives a reload of the page (sessionStorage is
// per page view), as the Markdown viewer's does.
//
// The default is the agent chat's code block size, 12 px on 20 px lines at the chat's text scale
// (`--cmux-chat-text-scale`, chatDisplay.ts), so a diff and the chat that made it read as one app (user
// 2026-11-19: "default font size needs to better match chat trajectory"). A size the host sends in the diff
// appearance wins.
//
// The size applies as two pixel values on the root, `--cmux-diff-code-size` and `--cmux-diff-code-line-height`
// (styles.css #viewer), and the line height also goes to the virtualizer's metrics (App.tsx), whose row estimates
// must match the drawn rows.

/** The zoom's range, in pixels. */
export const DIFF_CODE_SIZE = { min: 8, max: 32 } as const;
/** The chat's code block size and line at a text scale of 1 (chatDisplay.ts `chatMetrics`: 12 on 20). */
const CHAT_CODE = { size: 12, line: 20 } as const;

export type DiffZoomCommand = "zoomIn" | "zoomOut" | "zoomReset";

const clamp = (size: number) => Math.min(DIFF_CODE_SIZE.max, Math.max(DIFF_CODE_SIZE.min, Math.round(size)));

/** The default code size: the host's (a positive number), else the chat's code block size at `chatScale`. */
export function diffDefaultCodeSize(hostSize: number | undefined, chatScale: number): number {
  if (typeof hostSize === "number" && Number.isFinite(hostSize) && hostSize > 0) return clamp(hostSize);
  const scale = Number.isFinite(chatScale) && chatScale > 0 ? chatScale : 1;
  return clamp(CHAT_CODE.size * scale);
}

/** A whole-pixel line for `size`, in the chat's 12-on-20 proportion (20 at 12). */
export function diffCodeLineHeight(size: number): number {
  return Math.round((size * CHAT_CODE.line) / CHAT_CODE.size);
}

/** The chat's text scale the host writes on the root (Typography+PageDensity.swift); 1 without a host. */
function hostChatScale(): number {
  if (typeof document === "undefined") return 1;
  const parsed = Number.parseFloat(document.documentElement?.style?.getPropertyValue?.("--cmux-chat-text-scale") ?? "");
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 1;
}

const STORAGE_KEY = "cmux.diff.fontSize";

/** The storage the size survives a page reload in (sessionStorage; a stand-in in tests). */
export interface DiffZoomStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

function sessionStore(): DiffZoomStorage | null {
  try {
    return globalThis.sessionStorage ?? null;
  } catch {
    return null;
  }
}

type ZoomRoot = { style: { setProperty(name: string, value: string): void } };

/**
 * One diff tab's code size. `size` null follows the default (the chat's size, also after Text Size changes it);
 * a number is this tab's own size until Cmd-0.
 */
export class DiffFontZoom {
  private size: number | null = null;
  private hostSize: number | undefined;
  private readonly listeners = new Set<() => void>();

  constructor(
    private readonly root: ZoomRoot,
    private readonly storage: DiffZoomStorage | null = sessionStore(),
    private readonly chatScale: () => number = hostChatScale,
  ) {
    const saved = Number(storage?.getItem(STORAGE_KEY));
    if (Number.isFinite(saved) && saved > 0) this.size = clamp(saved);
    this.apply();
  }

  /** The default size now. */
  get baseSize(): number {
    return diffDefaultCodeSize(this.hostSize, this.chatScale());
  }

  /** The size the code shows at, in pixels. */
  get fontSize(): number {
    return this.size ?? this.baseSize;
  }

  /** The line the code shows on, in whole pixels. */
  get lineHeight(): number {
    return diffCodeLineHeight(this.fontSize);
  }

  /** The host's appearance size (or none); a tab at the default follows it. */
  setHostSize(size: number | undefined): void {
    if (size === this.hostSize) return;
    this.hostSize = size;
    this.changed();
  }

  /** The chat's text scale changed (Text Size): a tab at the default follows it. */
  refresh(): void {
    if (this.size === null) this.changed();
  }

  /** `zoomIn`, `zoomOut` or `zoomReset`. Returns the size it shows now. */
  run(command: DiffZoomCommand): number {
    const base = this.baseSize;
    const next = command === "zoomReset" ? null : clamp(this.fontSize + (command === "zoomIn" ? 1 : -1));
    this.size = next === base ? null : next;
    try {
      if (this.size === null) this.storage?.removeItem(STORAGE_KEY);
      else this.storage?.setItem(STORAGE_KEY, String(this.size));
    } catch {
      // A full or refused storage only loses the size on the next reload.
    }
    this.changed();
    return this.fontSize;
  }

  /** Calls `listener` after every size change; returns the unsubscribe. */
  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private changed(): void {
    this.apply();
    for (const listener of this.listeners) listener();
  }

  private apply(): void {
    this.root.style.setProperty("--cmux-diff-code-size", `${this.fontSize}px`);
    this.root.style.setProperty("--cmux-diff-code-line-height", `${this.lineHeight}px`);
  }
}

let pageZoom: DiffFontZoom | null = null;

/** The diff page's one zoom, on the document's root; it follows the host's Text Size changes. */
export function diffPageFontZoom(): DiffFontZoom {
  if (pageZoom) return pageZoom;
  const zoom = new DiffFontZoom(document.documentElement);
  window.addEventListener("cmux-ui-scale-change", () => zoom.refresh());
  pageZoom = zoom;
  return zoom;
}
