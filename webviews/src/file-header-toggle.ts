/**
 * The whole file header bar is one collapse toggle (GitHub "Files changed"
 * parity): a click anywhere on it expands or collapses that file, except on a
 * control inside the bar, which keeps its own action, and except at the end
 * of a drag that selected text in the bar (the path stays selectable).
 * Keyboard users reach the bar as one focusable toggle; Enter and Space
 * toggle it.
 */

/**
 * Elements inside the bar that own their click. `data-file-header-control`
 * marks any other element that must not toggle (a menu trigger, a badge
 * with its own popover).
 */
export const FILE_HEADER_CONTROL_SELECTOR = [
  "a[href]",
  "button",
  "input",
  "label",
  "select",
  "summary",
  "textarea",
  "[contenteditable='true']",
  "[role='button']",
  "[role='checkbox']",
  "[role='link']",
  "[role='menu']",
  "[role='menuitem']",
  "[role='switch']",
  "[data-file-header-control]",
].join(",");

/** How far the pointer may move between press and click and still toggle. */
export const HEADER_DRAG_THRESHOLD_PX = 4;

export type HeaderPress = { x: number; y: number };

/**
 * Whether a click that reached the bar should toggle the file. `press` is
 * where the primary button went down on the bar (null when the click did not
 * start with a press there, as for a synthesized click).
 */
export function shouldToggleFromHeaderClick(
  event: {
    target: EventTarget | null;
    currentTarget: EventTarget | null;
    button?: number;
    defaultPrevented?: boolean;
    clientX?: number;
    clientY?: number;
  },
  press: HeaderPress | null,
): boolean {
  if (event.defaultPrevented || (event.button ?? 0) !== 0) {
    return false;
  }
  const bar = event.currentTarget as Element | null;
  const target = event.target as Element | null;
  if (bar == null || target == null) {
    return false;
  }
  const control = typeof target.closest === "function" ? target.closest(FILE_HEADER_CONTROL_SELECTOR) : null;
  if (control != null && control !== bar && bar.contains(control)) {
    return false;
  }
  // A drag (selecting the path) ends in a click on the bar; that click
  // finishes the selection and must not also toggle the file. The pointer's
  // travel decides it, not the selection: in Chromium a click inside an old
  // selection still sees it, and that click must toggle.
  if (press != null && event.clientX != null && event.clientY != null) {
    const moved = Math.hypot(event.clientX - press.x, event.clientY - press.y);
    if (moved > HEADER_DRAG_THRESHOLD_PX) {
      return false;
    }
  }
  return true;
}

/** Whether a key press on the focused bar toggles the file. */
export function isHeaderToggleKey(event: {
  key: string;
  target: EventTarget | null;
  currentTarget: EventTarget | null;
}) {
  return (
    event.target === event.currentTarget && (event.key === "Enter" || event.key === " " || event.key === "Spacebar")
  );
}
