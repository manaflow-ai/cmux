import type { KeyboardEvent } from "react";

/** Props for a virtualized row's single tab stop. The owner still decides how keys move rows. */
export function rovingTabStopProps(
  active: boolean,
  onKeyDown?: (event: KeyboardEvent<HTMLElement>) => void,
): { tabIndex: 0 | -1; onKeyDown?: (event: KeyboardEvent<HTMLElement>) => void } {
  return { tabIndex: active ? 0 : -1, ...(onKeyDown ? { onKeyDown } : {}) };
}
