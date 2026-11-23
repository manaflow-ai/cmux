/**
 * When Chromium presented the frame that draws a composer key: the page's equivalent of the terminal's
 * `contents_ms` (the frame with the echo handed to its layer, after its Core Animation commit), which the
 * typing-frame bench (scripts/cmux-next/typing-frame-bench.py) puts beside the page's `paint` mark.
 *
 * Nothing in the app sees a Chromium page's frames: its GPU process commits them to its own Core Animation
 * context, which the app only hosts. The page does see them through element timing: each key adds a new
 * one-glyph element (`elementtiming`), in the key's own task, so the frame that draws the key's edit first
 * paints it; that element's `presentationTime` is the presentation feedback of that frame. On macOS that is
 * the display time of the refresh the GPU process commits the frame for (image_transport_surface_overlay_mac
 * `GetDisplaytime`, from its display link), not the commit itself: up to one refresh after the point the
 * terminal's mark takes. Only while measuring (`AcpmuxPerf.enable`): one tiny element per key, the previous
 * one removed in the same task, so no frame is added.
 *
 * Without cross-origin isolation (the agent page has none) Chromium rounds `presentationTime` up to a 4 ms
 * multiple, so `submitted` reads up to 4 ms late; `submittedFloor` is the earliest it can be: that rounded
 * time less 4 ms, never before the frame's main-thread paint (`paintTime`, not rounded).
 */
export type KeyPresentation = { submitted: number; submittedFloor: number };

/** The rounding of `presentationTime` when the page is not cross-origin isolated (Chromium). */
export const PRESENTATION_COARSENING_MS = 4;

type PaintEntry = PerformanceEntry & {
  identifier?: string;
  renderTime?: number;
  paintTime?: number;
  presentationTime?: number;
};

const PREFIX = "cmux-key-";

/** One key's presentation from an element timing entry; null when the entry has no presentation time. */
export function keyPresentation(
  entry: Pick<PaintEntry, "renderTime" | "paintTime" | "presentationTime">,
  start: number,
  isolated: boolean,
): KeyPresentation | null {
  const presented = entry.presentationTime || entry.renderTime || 0;
  if (!(presented > 0)) return null;
  const painted = entry.paintTime ?? 0;
  const floor = isolated ? presented : Math.max(painted, presented - PRESENTATION_COARSENING_MS);
  return { submitted: presented - start, submittedFloor: Math.min(presented, floor) - start };
}

/**
 * The waiting keys an entry for `id` settles, oldest first, taken out of `waiting` (typing order): `id` and every
 * key typed before it. A key typed before it in the same frame had its glyph removed before any paint, so it gets
 * no entry of its own; it was drawn in this frame. Nothing when `id` is not waiting.
 */
export function settleThrough<T>(waiting: Map<string, T>, id: string): T[] {
  if (!waiting.has(id)) return [];
  const settled: T[] = [];
  for (const [key, value] of waiting) {
    waiting.delete(key);
    settled.push(value);
    if (key === id) break;
  }
  return settled;
}

export class KeyPresentationMarks {
  private next = 0;
  private shown: Element | undefined;
  private readonly waiting = new Map<string, (entry: PaintEntry) => void>();
  private readonly observer: PerformanceObserver | undefined;

  constructor(private readonly page: Document) {
    if (typeof PerformanceObserver === "undefined" || !PerformanceObserver.supportedEntryTypes?.includes("element"))
      return;
    this.observer = new PerformanceObserver((list) => {
      for (const entry of list.getEntries() as PaintEntry[]) {
        for (const done of settleThrough(this.waiting, entry.identifier ?? "")) done(entry);
      }
    });
    this.observer.observe({ type: "element", buffered: false });
  }

  /** Marks the key whose keydown time is `start`; `done` gets its presentation once Chromium reports it. */
  mark(start: number, done: (presentation: KeyPresentation) => void): void {
    if (!this.observer || !this.page.body) return;
    const id = `${PREFIX}${this.next++}`;
    // At most a few keys wait: a key whose frame never came (a hidden page) drops the oldest.
    if (this.waiting.size > 64) this.waiting.delete(this.waiting.keys().next().value as string);
    const isolated = globalThis.crossOriginIsolated === true;
    this.waiting.set(id, (entry) => {
      const presentation = keyPresentation(entry, start, isolated);
      if (presentation) done(presentation);
    });
    const glyph = this.page.createElement("span");
    glyph.setAttribute("elementtiming", id);
    glyph.setAttribute("aria-hidden", "true");
    glyph.textContent = ".";
    // Its own block (text timing names the element whose box holds the text), clipped to one pixel, all
    // but clear (Chromium does not time clear text).
    glyph.style.cssText =
      "position:fixed;left:0;top:0;width:1px;height:1px;overflow:hidden;" +
      "color:rgba(0,0,0,0.01);pointer-events:none;user-select:none;contain:strict"; // colour-allow: a timing glyph, never UI (clear text is not timed)
    this.shown?.remove();
    this.page.body.appendChild(glyph);
    this.shown = glyph;
  }
}
