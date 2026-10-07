// A virtualized grid: only the rows in the viewport (plus overscan) mount, absolutely positioned
// by their precomputed top. Scrolling re-renders only when the first visible row changes, and the
// row keys are stable, so React keeps the DOM of rows that stay on screen. The viewport is a tiny
// external store driven by the scroll and resize events (no effects).
import { useSyncExternalStore, type ReactNode } from "react";
import { rowAt, scrollToReveal, visibleRows, type GridLayout } from "./gridModel";

export class GridViewport {
  private element: HTMLElement | null = null;
  private observer?: ResizeObserver;
  private state = { row: 0, height: 0, top: 0 };
  private readonly listeners = new Set<() => void>();
  /** Called with the usable width when it changes (the store derives columns from it). */
  onWidth?: (width: number) => void;

  constructor(private readonly cell: number) {}

  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  readonly getSnapshot = () => this.state;

  /** Callback ref for the scroll container. */
  readonly attach = (element: HTMLElement | null) => {
    if (this.element === element) return;
    this.element?.removeEventListener("scroll", this.onScroll);
    this.observer?.disconnect();
    this.element = element;
    if (!element) return;
    element.addEventListener("scroll", this.onScroll, { passive: true });
    if (typeof ResizeObserver !== "undefined") {
      this.observer = new ResizeObserver(() => this.measure());
      this.observer.observe(element);
    }
    this.measure();
  };

  /** Scrolls so `item` is fully visible (keyboard moves). */
  reveal<T>(layout: GridLayout<T>, item: number) {
    if (!this.element || item < 0) return;
    const top = scrollToReveal(layout, item, this.element.scrollTop, this.element.clientHeight);
    if (top !== null) this.element.scrollTop = top;
  }

  scrollToTop() {
    if (this.element) this.element.scrollTop = 0;
    this.onScroll();
  }

  private measure() {
    if (!this.element) return;
    this.onWidth?.(this.element.clientWidth);
    this.publish({ row: this.state.row, height: this.element.clientHeight, top: this.element.scrollTop });
  }

  private readonly onScroll = () => {
    if (!this.element) return;
    const top = this.element.scrollTop;
    // 4 px buckets: the window and the docked header follow the scroll closely, and a frame
    // that scrolls less than 4 px renders nothing.
    this.publish({ row: Math.floor(top / 4), height: this.element.clientHeight, top });
  };

  /** Publishes only when the first visible row or the height changes (the window's inputs). */
  private publish(next: { row: number; height: number; top: number }) {
    if (next.row === this.state.row && next.height === this.state.height) return;
    this.state = next;
    for (const listener of this.listeners) listener();
  }
}

export function VirtualGrid<T>({
  layout,
  viewport,
  containerRef,
  active,
  id,
  label,
  renderCell,
  onPick,
  onHover,
  empty,
}: {
  layout: GridLayout<T>;
  viewport: GridViewport;
  /** `viewport.attach`, passed apart so the compiler does not treat the viewport as a ref. */
  containerRef: (element: HTMLElement | null) => void;
  active: number;
  id: string;
  label: string;
  renderCell: (item: T) => ReactNode;
  onPick: (index: number) => void;
  onHover: (index: number) => void;
  empty: ReactNode;
}) {
  const view = useSyncExternalStore(viewport.subscribe, viewport.getSnapshot);
  // `top` is at most one row stale (it updates when the first row changes); overscan covers it.
  const { start, end } = visibleRows(layout, view.top, Math.max(view.height, layout.metrics.cell * 12));
  const rows = layout.rows.slice(start, end);
  const docked = dockedTitle(layout, view.top);
  return (
    <div className="icon-grid-frame">
      {docked && (
        <div className="icon-grid-docked" aria-hidden>
          {docked}
        </div>
      )}
      <div className="icon-grid-scroll" ref={containerRef} aria-label={label} id={id}>
        {layout.items.length === 0 ? (
          <div className="icon-grid-empty">{empty}</div>
        ) : (
          <div className="icon-grid-body" style={{ height: layout.height }}>
            {rows.map((row) =>
              row.kind === "header" ? (
                <div key={row.key} className="icon-grid-header" style={{ transform: `translateY(${row.top}px)` }}>
                  <span>{row.title}</span>
                </div>
              ) : (
                <div key={row.key} className="icon-grid-row" style={{ transform: `translateY(${row.top}px)` }}>
                  {row.items.map((item, offset) => {
                    const index = row.first + offset;
                    return (
                      // A button outside the tab order: focus stays in the search field, which
                      // names the active cell with aria-activedescendant.
                      <button
                        key={index}
                        type="button"
                        tabIndex={-1}
                        id={`${id}-cell-${index}`}
                        className="icon-cell"
                        aria-pressed={index === active}
                        data-active={index === active || undefined}
                        onMouseDown={(event) => event.preventDefault()}
                        onMouseEnter={() => onHover(index)}
                        onClick={() => onPick(index)}
                      >
                        {renderCell(item)}
                      </button>
                    );
                  })}
                </div>
              ),
            )}
          </div>
        )}
      </div>
    </div>
  );
}

/** The title of the section at the top of the viewport (the docked header), or null. */
export function dockedTitle<T>(layout: GridLayout<T>, top: number): string | null {
  if (top <= 0) return null; // the section's own header is in place
  for (let index = rowAt(layout, top); index >= 0; index--) {
    const row = layout.rows[index];
    if (row.kind === "header") return row.title;
  }
  return null;
}
