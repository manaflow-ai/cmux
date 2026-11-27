import { type KeyboardEvent, type ReactNode } from "react";

/**
 * Routes keyboard commands for a composite surface while keeping the event wiring in ui/.
 * Consumers can handle a command from any focused control and call preventDefault when it is used.
 */
export function KeyboardScope({
  children,
  handleKeyDown,
  className,
  popupSettle,
}: {
  children: ReactNode;
  handleKeyDown(event: KeyboardEvent<HTMLDivElement>): void;
  className?: string;
  /** For a scope that is a popup box (`.ui-popup`): which popup rule it follows (ui/popupSettle.ts). */
  popupSettle?: "results" | "own";
}) {
  return (
    <div className={className} data-popup-settle={popupSettle} onKeyDownCapture={handleKeyDown}>
      {children}
    </div>
  );
}
