// The category jump bar above the grid: one button per titled section (emoji groups, SF Symbol
// categories). A click scrolls the grid to the section's header and makes its first cell active.
// The bar is one tab stop (the current section's button, roving tabindex); Left/Right, Home and
// End move between its buttons, Return and Space jump. The current section follows the scroll.
import { useSyncExternalStore, type CSSProperties, type KeyboardEvent } from "react";
import { sectionAt, type GridLayout } from "./gridModel";
import type { JumpTarget } from "./store";
import type { GridViewport } from "./VirtualGrid";

export function JumpBar<T>({
  jumps,
  layout,
  viewport,
  label,
  onJump,
  symbolStyle,
}: {
  jumps: readonly JumpTarget[];
  layout: GridLayout<T>;
  viewport: GridViewport;
  label: string;
  onJump: (id: string) => void;
  /** The CSS for a target's SF Symbol (the host's template image as a mask). */
  symbolStyle: (name: string) => CSSProperties | undefined;
}) {
  const view = useSyncExternalStore(viewport.subscribe, viewport.getSnapshot);
  const current = sectionAt(layout, view.top) ?? jumps[0]?.id;
  const onKeyDown = (event: KeyboardEvent<HTMLButtonElement>) => {
    const buttons = [...(event.currentTarget.parentElement?.querySelectorAll("button") ?? [])];
    const at = buttons.indexOf(event.currentTarget);
    const next =
      event.key === "ArrowRight"
        ? at + 1
        : event.key === "ArrowLeft"
          ? at - 1
          : event.key === "Home"
            ? 0
            : event.key === "End"
              ? buttons.length - 1
              : null;
    if (next === null) return;
    event.preventDefault();
    buttons[Math.max(0, Math.min(buttons.length - 1, next))]?.focus();
  };
  return (
    <div className="icon-jump-bar" role="toolbar" aria-label={label} aria-orientation="horizontal">
      {jumps.map((jump) => (
        <button
          key={jump.id}
          type="button"
          className="icon-jump"
          aria-label={jump.label}
          title={jump.label}
          aria-current={jump.id === current || undefined}
          tabIndex={jump.id === current ? 0 : -1}
          onMouseDown={(event) => event.preventDefault()}
          onKeyDown={onKeyDown}
          onClick={() => onJump(jump.id)}
        >
          {jump.glyph ? (
            <span className="icon-jump-glyph" aria-hidden>
              {jump.glyph}
            </span>
          ) : (
            <span
              className="icon-symbol icon-jump-symbol"
              aria-hidden
              style={jump.symbol ? symbolStyle(jump.symbol) : undefined}
            />
          )}
        </button>
      ))}
    </div>
  );
}
