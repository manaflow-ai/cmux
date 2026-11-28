import { type RefObject, useLayoutEffect } from "react";

// The composer's controls row gives its labels up in a fixed order when it runs out of room
// (hq#1957 item 15): first the permission mode's label (its lock alone), then effort shortens,
// the model last. The last two are CSS (composerLocation.css:
// flex-shrink weights far enough apart that each control reaches its min width before the next
// one gives a pixel). The first is a step, not a squeeze: a lock alone in a chip still as wide as
// its label would be the empty gap this fixes, so the row is measured here and marked
// `data-fit="icons"` when its controls would not fit with every label shown.
//
// Only reads layout, then writes one attribute: the hidden labels stay laid out (absolute,
// invisible), so their widths are still known and the decision never toggles to measure. It runs
// when the row is resized and when a control in it changes, never on a keystroke in the prompt.

/** Labels that give way to their icon first. */
const ICON_LABELS = ".acpmux-mode-text";
/** Labels that shorten with an ellipsis (effort, the model); their overflow is width they want. */
const SHORTENING = ".acpmux-picker-button > span";

function px(value: string): number {
  return parseFloat(value) || 0;
}

/** The flex items of `container`, looking through `display: contents` wrappers. */
function items(container: Element): HTMLElement[] {
  return [...container.children].flatMap((child) => {
    if (!(child instanceof HTMLElement)) return [];
    const display = getComputedStyle(child).display;
    if (display === "contents") return items(child);
    return display === "none" ? [] : [child];
  });
}

/** The width `element` takes with every label whole. */
function wanted(element: HTMLElement, hidden: Set<Element>): number {
  if (element.classList.contains("acpmux-chips")) return row(element, hidden);
  let width = element.getBoundingClientRect().width;
  for (const span of element.querySelectorAll(SHORTENING))
    if (!hidden.has(span)) width += Math.max(0, span.scrollWidth - span.clientWidth);
  for (const label of element.querySelectorAll(ICON_LABELS))
    if (hidden.has(label)) {
      const parent = label.parentElement;
      const gap = parent ? px(getComputedStyle(parent).columnGap) : 0;
      width += label.getBoundingClientRect().width + gap;
    }
  return width;
}

/** The width a flex row's items take with every label whole, gaps included. */
function row(container: HTMLElement, hidden: Set<Element>): number {
  const children = items(container);
  const gap = px(getComputedStyle(container).columnGap);
  return children.reduce((sum, child) => sum + wanted(child, hidden), 0) + gap * Math.max(0, children.length - 1);
}

/** Room the labels need, past the row's, before icons give way to them again. */
const LABELS_BACK = 4;

/**
 * Whether the row shows icons: `icons` is what it shows now, `wanted` the width every label whole
 * takes. With labels shown a shortening label's overflow is whole pixels (scrollWidth), so going
 * back from icons needs clear room or the row would flip every frame in that band.
 */
export function showsIcons(icons: boolean, wanted: number, room: number): boolean {
  return icons ? wanted > room - LABELS_BACK : wanted > room + 0.5;
}

/** Whether the row's controls fit with every label shown. */
export function rowFits(bar: HTMLElement): boolean {
  const style = getComputedStyle(bar);
  const room = bar.clientWidth - px(style.paddingLeft) - px(style.paddingRight);
  const icons = bar.dataset.fit === "icons";
  const hidden = new Set(icons ? bar.querySelectorAll(ICON_LABELS) : []);
  return !showsIcons(icons, row(bar, hidden), room);
}

export function useRowFit(bar: RefObject<HTMLElement | null>): void {
  useLayoutEffect(() => {
    const element = bar.current;
    if (!element) return;
    const fit = () => {
      const icons = !rowFits(element);
      if (icons !== (element.dataset.fit === "icons")) {
        if (icons) element.dataset.fit = "icons";
        else delete element.dataset.fit;
      }
    };
    fit();
    // The row's own width (the pane), and a chip's (a new model or mode name, a chip that comes or goes).
    const resize = new ResizeObserver(fit);
    resize.observe(element);
    const watchChips = () => {
      for (const chip of element.querySelectorAll(".acpmux-chips, .acpmux-composer-actions")) resize.observe(chip);
    };
    watchChips();
    const mutation = new MutationObserver(() => {
      watchChips();
      fit();
    });
    mutation.observe(element, { childList: true, subtree: true, characterData: true });
    return () => {
      resize.disconnect();
      mutation.disconnect();
    };
  }, [bar]);
}
