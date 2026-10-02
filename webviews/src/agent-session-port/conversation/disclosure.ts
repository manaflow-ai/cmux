// Keyboard-accessible toggle props for a row that discloses content.
import type { KeyboardEvent } from "react";

/** Click / Enter / Space toggle for a row that discloses content (Codex uses a ghost button). */
export function disclosureProps(expanded: boolean | undefined, onToggle: (() => void) | undefined) {
  if (!onToggle) return {};
  return {
    role: "button",
    tabIndex: 0,
    "aria-expanded": expanded ?? false,
    onClick: onToggle,
    onKeyDown: (e: KeyboardEvent<HTMLElement>) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        onToggle();
      }
    },
  } as const;
}
