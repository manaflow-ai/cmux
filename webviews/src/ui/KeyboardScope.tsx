import { type KeyboardEvent, type ReactNode } from "react";

/**
 * Routes keyboard commands for a composite surface while keeping the event wiring in ui/.
 * Consumers can handle a command from any focused control and call preventDefault when it is used.
 */
export function KeyboardScope({
  children,
  handleKeyDown,
  className,
  label,
  bubble = false,
}: {
  children: ReactNode;
  handleKeyDown(event: KeyboardEvent<HTMLDivElement>): void;
  className?: string;
  /** Names a region without adding a wrapper around the composite surface. */
  label?: string;
  /** Let controls consume a key before the surface handles it. */
  bubble?: boolean;
}) {
  return (
    // oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- The scope delegates descendant keys; the container itself is not an interactive control.
    <div
      className={className}
      role={label ? "region" : undefined}
      aria-label={label}
      onKeyDownCapture={bubble ? undefined : handleKeyDown}
      onKeyDown={bubble ? handleKeyDown : undefined}
    >
      {children}
    </div>
  );
}
