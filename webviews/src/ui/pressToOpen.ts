import type React from "react";

/// The DOM row whose press already ran its action; the `click` that follows runs nothing.
const openedOnPress = new WeakSet<EventTarget>();

/// True for a plain primary press: no modifier (Cmd/Shift select, Ctrl opens the context menu, Option
/// is the row's alternate action) and the left button only.
export function isPlainPress(
  event: Pick<MouseEvent, "button" | "metaKey" | "shiftKey" | "ctrlKey" | "altKey">,
): boolean {
  return event.button === 0 && !event.metaKey && !event.shiftKey && !event.ctrlKey && !event.altKey;
}

/// Handlers that open a row on mouse-down, as the native sidebar and tab strip do (Lawrence
/// 2026-10-19: "mouse down to immediately open"). A plain press runs `open` at once and its `click`
/// runs nothing more. A modified click, and a keyboard click (Enter or Space, `detail` 0), go to
/// `onClick` (by default `open`), so Cmd/Shift selection keeps acting on the release (the Finder rule).
/// `deferPress` returns true for a press that must wait for the release, such as a press on a row
/// of a multi-selection, which may become a drag of the selection.
///
/// ```tsx
/// <button {...pressToOpen(() => onSelect(id))}>…</button>
/// ```
export function pressToOpen(
  open: () => void,
  options: { onClick?: (event: React.MouseEvent) => void; deferPress?: () => boolean } = {},
): Pick<React.DOMAttributes<HTMLElement>, "onMouseDown" | "onClick"> {
  const { onClick = () => open(), deferPress } = options;
  return {
    onMouseDown(event) {
      // A press that was dragged away never got its click: forget it first.
      openedOnPress.delete(event.currentTarget);
      if (!isPlainPress(event) || deferPress?.()) return;
      openedOnPress.add(event.currentTarget);
      open();
    },
    onClick(event) {
      const opened = openedOnPress.delete(event.currentTarget);
      // A keyboard click (Enter, Space) has no press: it always runs.
      if (opened && event.detail !== 0) return;
      onClick(event);
    },
  };
}
