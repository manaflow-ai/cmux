import type { ButtonHTMLAttributes, KeyboardEvent } from "react";

type ListRowKeyboardProps = Pick<ButtonHTMLAttributes<HTMLButtonElement>, "onKeyDown">;

/** The shared keyboard contract for a list of native button rows. */
export function listRowKeyboardProps(selector: string, onMove: (row: HTMLElement) => void): ListRowKeyboardProps {
  return {
    onKeyDown(event: KeyboardEvent<HTMLButtonElement>) {
      if (
        !["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key) ||
        event.altKey ||
        event.ctrlKey ||
        event.metaKey ||
        event.shiftKey
      ) {
        return;
      }
      const list = event.currentTarget.closest<HTMLElement>("[data-list-keyboard]");
      const rows = list ? [...list.querySelectorAll<HTMLElement>(selector)] : [];
      const current = rows.indexOf(event.currentTarget);
      if (current < 0 || rows.length === 0) return;
      const next =
        event.key === "ArrowUp"
          ? Math.max(0, current - 1)
          : event.key === "ArrowDown"
            ? Math.min(rows.length - 1, current + 1)
            : event.key === "Home"
              ? 0
              : rows.length - 1;
      event.preventDefault();
      if (next === current) return;
      const target = rows[next];
      target.focus();
      onMove(target);
    },
  };
}

/** Props for a virtualized row's single tab stop. The owner still decides how keys move rows. */
export function rovingTabStopProps(
  active: boolean,
  onKeyDown?: (event: KeyboardEvent<HTMLElement>) => void,
): { tabIndex: 0 | -1; onKeyDown?: (event: KeyboardEvent<HTMLElement>) => void } {
  return { tabIndex: active ? 0 : -1, ...(onKeyDown ? { onKeyDown } : {}) };
}
