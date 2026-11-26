// The caret as each painted frame showed it, from an edit's input to its settled place.
//
// Leo, 2026-11-22: "when im pasting attachments or whatever, there's a breif moment where i see the
// caret at the beginning of the composer after the preview for the attachment has already shown up,
// and then it doesn't follow as fast, it follows with a delay. we can't have that."
//
// Every frame after the input, read after that frame painted (paintedFrames.ts), records two things:
// - `shown`: the caret the person sees. On a line that holds an attachment the field draws its own
//   bar (composer/inlineCaret.ts) and the native caret is clear, so that bar; elsewhere the native
//   caret, which the engine paints at the selection.
// - `truth`: where the selection is in that frame's layout, the collapsed range's own box.
// A frame whose shown caret is not at its truth (more than `CARET_SLOP_PX` off, or none while the
// field has focus) is a frame the caret was out of place in. The input-to-caret time is from the
// input to the first frame from which the shown caret stays at its final place.
import type { Page } from "playwright";
import { installPaintedFrames } from "./paintedFrames";

export type CaretBox = { x: number; top: number; bottom: number };
/** `chips`: the attachments' widths in the text, summed (how far they push what comes after them). */
/** `clipped`: how far, in CSS px, the shown caret stands outside the field's visible box (0 inside it).
 *  `unpainted`: the page changed between the frame's paint and this read (a task that ran first: a
 *  React commit, a decode), so the read is of a layout no frame painted; never judged. */
export type CaretFrame = {
  at: number;
  focused: boolean;
  shown: CaretBox | null;
  truth: CaretBox | null;
  chips: number;
  clipped: number;
  unpainted?: boolean;
};
export type CaretTrace = { inputAt: number; frames: CaretFrame[]; final: CaretFrame };

/** How far apart, in CSS px, two carets may be and still be the same place (a 2px bar centered on
 *  the point, an engine's caret on whole pixels). */
export const CARET_SLOP_PX = 1.5;
/** One frame at 60 Hz. */
export const FRAME_MS = 1000 / 60;

/** The composer's shell-mode input in one painted frame (composer-shell-caret-frames.browser.test.ts). */
export type ShellFrame = {
  at: number;
  readAt: number;
  mounted: boolean;
  focused: boolean;
  value: string;
  start: number;
  end: number;
  promptFocused: boolean;
  promptText: string;
  promptCaretAtEnd: boolean;
};
export type ShellTrace = { inputAt: number; frames: ShellFrame[]; final: ShellFrame };

declare global {
  interface Window {
    cmuxShellTrace?: { start(): void; stop(): ShellTrace; read(): ShellFrame };
    cmuxCaretTrace?: {
      start(field: string): void;
      /** Marks the input now (an event the test dispatches itself). */
      input(): void;
      stop(): CaretTrace;
      read(field: string): CaretFrame;
    };
  }
}

/** The page side; runs in the page, so it closes over nothing. */
function defineCaretTrace() {
  if (window.cmuxCaretTrace) return;
  const box = (rect: { left: number; top: number; bottom: number; width?: number }, centered = false) => ({
    x: centered ? rect.left + (rect.width ?? 0) / 2 : rect.left,
    top: rect.top,
    bottom: rect.bottom,
  });
  /** The collapsed selection's own box: its range's last rect, else the place a caret in an empty
   *  line or beside an element stands (the child after it, or the line's content start). */
  const truthOf = (editor: Element): CaretBox | null => {
    const selection = document.getSelection();
    if (!selection?.rangeCount || !selection.isCollapsed || !editor.contains(selection.anchorNode)) return null;
    const range = selection.getRangeAt(0);
    const rects = range.getClientRects();
    const last = rects[rects.length - 1];
    if (last && last.bottom > last.top) return box(last);
    const node = selection.anchorNode!;
    const offset = selection.anchorOffset;
    if (node.nodeType === Node.ELEMENT_NODE) {
      const element = node as Element;
      const after = element.childNodes[offset];
      const before = element.childNodes[offset - 1];
      const rectOf = (child: ChildNode | undefined) => {
        if (!child) return undefined;
        if (child.nodeType === Node.ELEMENT_NODE) return (child as Element).getBoundingClientRect();
        const around = document.createRange();
        around.selectNodeContents(child);
        return around.getBoundingClientRect();
      };
      const next = rectOf(after);
      if (next && next.height > 0 && !(after instanceof HTMLBRElement)) return box(next);
      const previous = rectOf(before);
      if (previous && previous.height > 0 && !(before instanceof HTMLBRElement))
        return { x: previous.right, top: previous.top, bottom: previous.bottom };
      // A neighbor with no size yet still stands at its place in the line: an attachment's node in
      // the frames between the transaction that placed it and its chip portaling in (0×0 at the end
      // of the chip before it). The caret is at its edge, on that line's text band (a run of text or
      // the trailing break, the height the native caret takes there). Never the paragraph's start:
      // that read a caret right after a chip as standing at the start of the prompt (CI, PR #50135).
      const edge =
        previous && !(before instanceof HTMLBRElement)
          ? { x: previous.right, y: (previous.top + previous.bottom) / 2 }
          : next && !(after instanceof HTMLBRElement)
            ? { x: next.left, y: (next.top + next.bottom) / 2 }
            : undefined;
      if (edge) {
        let band: { top: number; bottom: number } | undefined;
        let distance = Infinity;
        for (const child of element.childNodes) {
          if (child instanceof Element && (child.hasAttribute("data-inline-attachment") || child.tagName === "IMG"))
            continue;
          let rects: DOMRectList | DOMRect[];
          if (child.nodeType === Node.ELEMENT_NODE) rects = [(child as Element).getBoundingClientRect()];
          else {
            const around = document.createRange();
            around.selectNodeContents(child);
            rects = around.getClientRects();
          }
          for (const rect of rects) {
            if (rect.height <= 0) continue;
            const off = Math.max(0, rect.top - edge.y, edge.y - rect.bottom);
            if (off < distance) {
              distance = off;
              band = { top: rect.top, bottom: rect.bottom };
            }
          }
        }
        if (band) return { x: edge.x, ...band };
      }
      const line = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      const height = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.2;
      return { x: line.left + parseFloat(style.paddingLeft || "0"), top: line.top, bottom: line.top + height };
    }
    return null;
  };
  const read = (field: string): CaretFrame => {
    const editor = document.querySelector(field);
    const at = performance.now();
    if (!editor) return { at, focused: false, shown: null, truth: null, chips: 0, clipped: 0 };
    let chips = 0;
    for (const chip of editor.querySelectorAll("[data-inline-attachment]")) chips += chip.getBoundingClientRect().width;
    const focused = editor === document.activeElement || editor.contains(document.activeElement);
    const truth = truthOf(editor);
    const anchor = document.getSelection()?.anchorNode;
    const anchorElement =
      anchor && (anchor.nodeType === Node.ELEMENT_NODE ? (anchor as Element) : anchor.parentElement);
    const drawnLine = Boolean(anchorElement?.closest(".acpmux-md-caret-line"));
    let shown: CaretBox | null = truth;
    if (drawnLine) {
      const bar = (editor.closest(".acpmux-md-field") ?? editor.parentElement)?.querySelector<HTMLElement>(
        ".acpmux-md-caret",
      );
      shown =
        bar && !bar.hidden && getComputedStyle(bar).display !== "none" ? box(bar.getBoundingClientRect(), true) : null;
    }
    const clip = (editor.closest(".acpmux-md-field") ?? editor).getBoundingClientRect();
    const clipped =
      shown && focused
        ? Math.max(0, clip.top - shown.top, shown.bottom - clip.bottom, clip.left - shown.x, shown.x - clip.right)
        : 0;
    return { at, focused, shown: focused ? shown : null, truth, chips: Math.round(chips), clipped };
  };
  let frames: CaretFrame[] = [];
  let inputAt = 0;
  let stop: (() => void) | undefined;
  let current = "";
  // Whether the page changed after this frame's layout and observers: what the read sees then is not
  // what the frame painted. A probe resized in each frame's callback has its ResizeObserver run after
  // the page's own observers of the frame (made before it), so changes they make (the drawn caret's
  // move) are the frame's and are taken there; what comes after is not.
  let changed = false;
  const watcher = new MutationObserver(() => {
    changed = true;
  });
  const probe = document.createElement("div");
  probe.setAttribute("aria-hidden", "true");
  probe.style.cssText = "position:fixed;left:-10px;top:0;height:1px;width:1px;pointer-events:none;opacity:0";
  const laidOut = new ResizeObserver(() => {
    watcher.takeRecords();
    changed = false;
  });
  const mark = (event: Event) => {
    if (!inputAt) inputAt = event.timeStamp || performance.now();
  };
  const kinds = ["keydown", "beforeinput", "paste", "drop", "compositionstart", "mousedown"];
  window.cmuxCaretTrace = {
    start(field) {
      stop?.();
      current = field;
      frames = [];
      inputAt = 0;
      for (const kind of kinds) addEventListener(kind, mark, { capture: true });
      document.documentElement.append(probe);
      laidOut.observe(probe);
      watcher.observe(document.documentElement, {
        subtree: true,
        childList: true,
        attributes: true,
        characterData: true,
      });
      stop = window.cmuxAfterPaint(
        (frame) => {
          if (!inputAt) return;
          const unpainted = changed || watcher.takeRecords().length > 0;
          frames.push({ ...read(current), at: frame, ...(unpainted ? { unpainted } : {}) });
        },
        () => {
          probe.style.width = probe.style.width === "1px" ? "2px" : "1px";
        },
      );
    },
    input() {
      if (!inputAt) inputAt = performance.now();
    },
    stop() {
      stop?.();
      stop = undefined;
      for (const kind of kinds) removeEventListener(kind, mark, { capture: true });
      watcher.disconnect();
      laidOut.disconnect();
      probe.remove();
      return { inputAt, frames, final: read(current) };
    },
    read,
  };
}

export async function installCaretTrace(page: Page) {
  await installPaintedFrames(page);
  await page.addInitScript(defineCaretTrace);
  await page.evaluate(defineCaretTrace);
}

const near = (a: CaretBox | null, b: CaretBox | null) =>
  a !== null &&
  b !== null &&
  Math.abs(a.x - b.x) <= CARET_SLOP_PX &&
  Math.abs((a.top + a.bottom) / 2 - (b.top + b.bottom) / 2) <= Math.max(CARET_SLOP_PX, (b.bottom - b.top) / 2);

export type CaretVerdict = {
  /** Frames whose shown caret was not where that frame's selection was. */
  wrongFrames: { at: number; afterInputMs: number; shown: CaretBox | null; truth: CaretBox | null; clipped: number }[];
  /** From the input to the first painted frame from which the caret is in place (where its
   *  selection is, inside the field) in every frame. */
  inputToCaretMs: number | null;
  /** From the input to the first frame from which the shown caret stays at its final place on the
   *  page (an attachment arriving or the box growing moves it there over frames). */
  settleMs: number | null;
  /** Reads skipped: the page changed between a frame's paint and its read. */
  unpaintedFrames: number;
  /** Frames after the input before the caret settled. */
  framesToSettle: number;
  /** From the input to the first frame from which the attachments in the text keep their final
   *  width: the caret can be at its final place no sooner. Null with none. */
  inputToChipsMs: number | null;
  /** From the input to the first frame the engine painted after it. A loaded runner can paint
   *  nothing for several frames; the caret can be in place no sooner than that frame. */
  inputToFirstPaintMs: number | null;
};

/** What a trace says: the frames the caret was out of place in, and its input-to-caret time. */
export function judgeCaret(trace: CaretTrace): CaretVerdict {
  const { inputAt, frames, final } = trace;
  const after = frames.filter((frame) => frame.at >= inputAt - FRAME_MS && !frame.unpainted);
  const wrong = (frame: CaretFrame) =>
    frame.focused && (!near(frame.shown, frame.truth) || frame.clipped > CARET_SLOP_PX);
  const wrongFrames = after.filter(wrong).map((frame) => ({
    at: frame.at,
    afterInputMs: frame.at - inputAt,
    shown: frame.shown,
    truth: frame.truth,
    clipped: frame.clipped,
  }));
  // In place from the first painted frame on which it is, and every one after.
  let inPlace = after.length;
  for (let index = after.length - 1; index >= 0; index--) {
    if (wrong(after[index]!)) break;
    inPlace = index;
  }
  const target = final.shown ?? final.truth;
  let settled = after.length;
  for (let index = after.length - 1; index >= 0; index--) {
    if (!near(after[index]!.shown, target)) break;
    settled = index;
  }
  const settledFrame = after[settled];
  const inPlaceFrame = after[inPlace];
  let chipsAt: number | null = null;
  if (final.chips > 0) {
    let index = after.length;
    while (index > 0 && Math.abs(after[index - 1]!.chips - final.chips) <= 1) index--;
    chipsAt = after[index] ? Math.max(0, after[index]!.at - inputAt) : null;
  }
  const firstPaint = after.find((frame) => frame.at >= inputAt);
  return {
    wrongFrames,
    inputToFirstPaintMs: firstPaint ? firstPaint.at - inputAt : null,
    inputToCaretMs: inPlaceFrame ? Math.max(0, inPlaceFrame.at - inputAt) : null,
    settleMs: settledFrame ? Math.max(0, settledFrame.at - inputAt) : null,
    framesToSettle: settled,
    unpaintedFrames: frames.filter((frame) => frame.unpainted).length,
    inputToChipsMs: chipsAt,
  };
}
