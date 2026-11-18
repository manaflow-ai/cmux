// Pierre's `File` painted into a host element in the pane's worker pool, with the pane's syntax theme:
// what the fenced card (HighlightedCode.tsx) and a read's bare lines (HighlightedLines.tsx) share.
import { useId, useLayoutEffect, useRef, useState, useSyncExternalStore, type RefObject } from "react";
import { flushSync } from "react-dom";
import {
  DEFAULT_VIRTUAL_FILE_METRICS,
  DIFFS_TAG_NAME,
  File as PierreFile,
  VirtualizedFile,
  Virtualizer,
  type FileOptions,
} from "@pierre/diffs";
import { AGENT_DIFF_THEME, AGENT_DIFF_THEME_LIGHT, registerAgentDiffTheme } from "../diffTheme";
import { isHighlighted } from "../shikiLanguages";
import { MAX_TOKENIZED_LINE } from "./highlightLimits";
import { onHighlightTimeout, paneHighlightPool } from "./highlightPool";
import { highlightWorkerFailed, subscribeHighlightWorker } from "./highlightWorkerState";
import { WINDOW_CHUNK } from "./lineWindow";

/// The pane's theme (applyAgentTheme) is light or dark; syntax colors follow it.
const paneThemeType = () => (document.documentElement.dataset.theme === "light" ? "light" : "dark");

/// The lines Pierre drew in a windowed read: the first, and the one after the last (it may run past
/// the file's end), and the space its two buffers keep for the rest, in px.
export type DrawnLines = { from: number; to: number; before: number; after: number };

/// A read's box (FileResultCard.tsx): its lines scroll in `box`, and Pierre mounts only the lines in
/// its view and a chunk past each edge (Pierre's `Virtualizer` with the box as its scroll root). Lines
/// have one height (the code line height; a read never wraps), so Pierre's buffers are exact and no
/// line is measured. `whole` draws every line (Find in Chat opened the box). `onLines` hears what is
/// drawn once painted, so the gutter numbers the same lines; undefined when Pierre draws nothing.
/// `setsize`, while the box windows its lines, is the read's line count: each drawn row is then a
/// listitem at its place in the whole (aria-posinset), their column the list, the box the region
/// named with the count (lineWindow.ts `useLinesRegion`).
export type PierreLineWindow = {
  box: RefObject<HTMLElement | null>;
  whole: boolean;
  setsize?: number;
  onLines: (lines: DrawnLines | undefined) => void;
};

/// Pierre's drawn rows in `host`'s shadow root as items of a list of `setsize` (each at its line's
/// place in the file), or plain rows again without one. Rows that already say so are left alone.
function tagRows(host: HTMLElement, setsize: number | undefined) {
  const shadow = host.shadowRoot;
  if (!shadow) return;
  const size = setsize === undefined ? undefined : String(setsize);
  for (const column of shadow.querySelectorAll("[data-content]")) {
    if (size) column.setAttribute("role", "list");
    else column.removeAttribute("role");
  }
  for (const row of shadow.querySelectorAll<HTMLElement>("[data-line][data-line-index]")) {
    if (!size) {
      if (!row.hasAttribute("role")) continue;
      row.removeAttribute("role");
      row.removeAttribute("aria-posinset");
      row.removeAttribute("aria-setsize");
      continue;
    }
    if (row.getAttribute("aria-setsize") === size) continue;
    row.setAttribute("role", "listitem");
    row.setAttribute("aria-posinset", String(Number(row.dataset.lineIndex) + 1));
    row.setAttribute("aria-setsize", size);
  }
}

/// A window that holds every line: Pierre then draws the file from its first line to its last.
const WHOLE = { top: 0, bottom: Number.MAX_SAFE_INTEGER };

/// Pierre's virtualizer on one read's box, which can draw the file whole without dropping a line it
/// has drawn (a held selection's ends stay in the page).
class BoxVirtualizer extends Virtualizer {
  whole = false;
  override getWindowSpecs() {
    return this.whole ? WHOLE : super.getWindowSpecs();
  }
}

/// A virtualized file that says which lines it drew.
class WindowedFile extends VirtualizedFile {
  drawnLines(): DrawnLines | undefined {
    const range = this.renderRange;
    if (!range) return undefined;
    return {
      from: range.startingLine,
      to: range.startingLine + range.totalLines,
      before: range.bufferBefore,
      after: range.bufferAfter,
    };
  }
}

/// Pierre's `Virtualizer.setup` (and `CodeView.setup`) puts the instance on `window.__INSTANCE`, with a
/// `window.__TOGGLE` that closes over it, for debugging; neither one's `cleanUp` takes them off. While
/// they still name this read's virtualizer, they go with it, so an unmounted read leaves nothing of
/// itself reachable from the page. Another instance's are left alone.
function releaseDebugGlobals(instance: Virtualizer) {
  const globals = window as unknown as { __INSTANCE?: unknown; __TOGGLE?: unknown };
  if (globals.__INSTANCE !== instance) return;
  delete globals.__INSTANCE;
  delete globals.__TOGGLE;
}

/// Whether the page's selection touches `host`'s lines: across it, or with an end inside its shadow
/// root (Chromium names the shadow root's nodes, and its range does not intersect the host; WebKit
/// may call it collapsed while it reads text).
function selectionTouches(host: HTMLElement): boolean {
  const selection = host.ownerDocument.getSelection();
  if (!selection || selection.rangeCount === 0) return false;
  const shadow = host.shadowRoot;
  const inside = (node: Node | null) => Boolean(node && shadow?.contains(node));
  if (inside(selection.anchorNode) || inside(selection.focusNode))
    return !selection.isCollapsed || selection.toString() !== "";
  if (!selection.isCollapsed) return selection.getRangeAt(0).intersectsNode(host);
  const inner = (shadow as (ShadowRoot & { getSelection?: () => Selection | null }) | null)?.getSelection?.();
  if (inner && !inner.isCollapsed) return true;
  const anchor = selection.anchorNode;
  return Boolean(anchor && (anchor === host || anchor.contains(host)) && selection.toString() !== "");
}

/// Pierre's `File` in the pane's syntax theme, painted into `host` in the pane's worker pool: what the
/// fenced card and a read's bare lines (HighlightedLines.tsx) share. `painted` turns true once its lines
/// are on screen; `workerAvailable` false (no pool, a failed worker, a job past its budget) means the
/// caller draws plain lines instead. With `lineWindow` (a long read's box), only the lines in the box's
/// view are mounted, and every line while a selection touches them, so a drag or Select All copies
/// what it spans.
export function usePierreCode(
  code: string,
  lang: string,
  unsafeCSS: string,
  wrap: boolean,
  lineWindow?: PierreLineWindow,
) {
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<PierreFile | undefined>(undefined);
  const virtualizer = useRef<BoxVirtualizer | undefined>(undefined);
  const pool = paneHighlightPool("word-alt", isHighlighted(lang) ? lang : "text");
  const workerFailed = useSyncExternalStore(subscribeHighlightWorker, highlightWorkerFailed, () => false);
  const [painted, setPainted] = useState(false);
  // A highlight job past its budget (highlightWatchdog.ts) draws the card as plain text.
  const name = `snippet-${useId()}`;
  const [tooSlow, setTooSlow] = useState(false);
  const workerAvailable = Boolean(pool?.isWorkingPool()) && !workerFailed && !tooSlow;
  const box = lineWindow?.box;
  const windowed = Boolean(box);
  // A windowed file is made for its text (VirtualizedFile keeps the first file it renders).
  const windowedCode = windowed ? code : undefined;
  const [selected, setSelected] = useState(false);
  const whole = Boolean(lineWindow?.whole) || selected;
  const wholeRef = useRef(whole);
  wholeRef.current = whole;
  const onLines = useRef(lineWindow?.onLines);
  onLines.current = lineWindow?.onLines;
  const setsize = lineWindow?.setsize;
  const setsizeRef = useRef(setsize);
  setsizeRef.current = setsize;
  useLayoutEffect(() => onHighlightTimeout(name, () => setTooSlow(true)), [name]);
  useLayoutEffect(() => {
    const el = host.current;
    if (!el || !workerAvailable || highlightWorkerFailed() || !pool?.isWorkingPool()) return;
    const scroller = box?.current;
    if (windowed && !scroller) return;
    setPainted(false);
    registerAgentDiffTheme();
    // A windowed read tells its card what it drew once per frame, before the frame paints, so its
    // gutter moves with its lines (a microtask, out of whichever render or effect drew them).
    let reported = false;
    let file: PierreFile;
    const report = () => {
      if (reported) return;
      reported = true;
      queueMicrotask(() => {
        reported = false;
        if (view.current !== file || !el.shadowRoot?.querySelector("[data-line]")) return;
        tagRows(el, setsizeRef.current);
        const lines = (file as WindowedFile).drawnLines();
        flushSync(() => {
          setPainted(true);
          onLines.current?.(lines ?? { from: 0, to: Number.MAX_SAFE_INTEGER, before: 0, after: 0 });
        });
      });
    };
    const options: FileOptions<undefined> = {
      theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
      themeType: paneThemeType(),
      disableFileHeader: true,
      disableLineNumbers: true,
      overflow: "scroll",
      unsafeCSS,
      tokenizeMaxLineLength: MAX_TOKENIZED_LINE,
      onPostRender: (node, _instance, phase) => {
        if (phase === "unmount") return;
        if (windowed) report();
        else if (node.shadowRoot?.querySelector("[data-line]")) setPainted(true);
      },
    };
    let boxVirtualizer: BoxVirtualizer | undefined;
    if (scroller) {
      // The box is its own scroll root; its window is its view (no overscroll), Pierre's chunks of a
      // box's lines past each edge. Lines are the code line height, the shadow root's pre unpadded.
      boxVirtualizer = new BoxVirtualizer({ overscrollSize: 0 });
      boxVirtualizer.whole = wholeRef.current;
      boxVirtualizer.setup(scroller, (scroller.firstElementChild as HTMLElement | null) ?? undefined);
      const lineHeight =
        parseFloat(getComputedStyle(scroller).getPropertyValue("--cv-codeblock-line-height")) ||
        DEFAULT_VIRTUAL_FILE_METRICS.lineHeight;
      file = new WindowedFile(
        options,
        boxVirtualizer,
        { ...DEFAULT_VIRTUAL_FILE_METRICS, hunkLineCount: WINDOW_CHUNK, lineHeight, paddingTop: 0, paddingBottom: 0 },
        pool,
        // React owns the host element: Pierre must not remove it on cleanUp.
        true,
      );
    } else {
      // React owns the host element: Pierre must not remove it on cleanUp.
      file = new PierreFile(options, pool, true);
    }
    view.current = file;
    virtualizer.current = boxVirtualizer;
    const theme = new MutationObserver(() => file.setThemeType(paneThemeType()));
    theme.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => {
      theme.disconnect();
      view.current = undefined;
      virtualizer.current = undefined;
      file.cleanUp();
      boxVirtualizer?.cleanUp();
      if (boxVirtualizer) releaseDebugGlobals(boxVirtualizer);
      el.shadowRoot?.replaceChildren();
      if (windowed) onLines.current?.(undefined);
    };
  }, [lang, unsafeCSS, pool, workerAvailable, windowed, box, windowedCode]);
  useLayoutEffect(() => {
    const el = host.current;
    const file = view.current;
    if (!el || !file || !workerAvailable || highlightWorkerFailed() || !pool?.isWorkingPool()) return;
    file.setOptions({ ...file.options, overflow: wrap ? "wrap" : "scroll" });
    // Shiki throws for a language the bundle does not ship; those draw as plain text.
    file.render({
      fileContainer: el,
      file: { name, contents: code, lang: (isHighlighted(lang) ? lang : "text") as never },
    });
  }, [code, lang, unsafeCSS, pool, wrap, name, workerAvailable, windowed, box, windowedCode]);
  // Whole while Find has the box open or a selection holds its lines; the window again after. The
  // lines already drawn stay, so a selection's ends are never dropped under it.
  useLayoutEffect(() => {
    const boxVirtualizer = virtualizer.current;
    const file = view.current;
    if (!boxVirtualizer || !file || boxVirtualizer.whole === whole) return;
    boxVirtualizer.whole = whole;
    boxVirtualizer.instanceChanged(file as WindowedFile, false);
  }, [whole, workerAvailable, windowed, box, windowedCode]);
  // The rows already drawn, when the box starts or stops windowing (Find's reveal).
  useLayoutEffect(() => {
    const el = host.current;
    if (windowed && el) tagRows(el, setsize);
  }, [windowed, setsize]);
  useLayoutEffect(() => {
    const el = host.current;
    if (!windowed || !el) return;
    const doc = el.ownerDocument;
    const onSelection = () => setSelected(selectionTouches(el));
    doc.addEventListener("selectionchange", onSelection);
    return () => doc.removeEventListener("selectionchange", onSelection);
  }, [windowed]);
  return { host, painted, workerAvailable };
}

/// Pierre's host element (`<diffs-container>`); it attaches its own shadow root.
export const DiffsHost = DIFFS_TAG_NAME as unknown as "div";
