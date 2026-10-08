// The category jump bar above the grid: one button per titled section (emoji groups, SF Symbol
// categories). A click scrolls the grid to the section's header and makes its first cell active.
// The bar is the shared Toolbar (src/ui): one tab stop, arrow keys move between its buttons,
// Return and Space jump. The current section follows the scroll and is marked aria-current.
import { useSyncExternalStore, type CSSProperties } from "react";
import { Toolbar, ToolbarButton } from "../ui/Toolbar";
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
  return (
    <Toolbar label={label} className="icon-jump-bar">
      {jumps.map((jump) => (
        <ToolbarButton
          key={jump.id}
          label={jump.label}
          className="icon-jump"
          current={jump.id === current}
          keepsFocus
          onPress={() => onJump(jump.id)}
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
        </ToolbarButton>
      ))}
    </Toolbar>
  );
}
