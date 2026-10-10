import { type KeyboardEvent, type ReactNode } from "react";

/**
 * Routes keyboard commands for a composite surface while keeping the event wiring in ui/.
 * Consumers can handle a command from any focused control and call preventDefault when it is used.
 */
export function KeyboardScope({
  children,
  handleKeyDown,
  className,
}: {
  children: ReactNode;
  handleKeyDown(event: KeyboardEvent<HTMLDivElement>): void;
  className?: string;
}) {
  return (
    <div className={className} onKeyDownCapture={handleKeyDown}>
      {children}
    </div>
  );
}
