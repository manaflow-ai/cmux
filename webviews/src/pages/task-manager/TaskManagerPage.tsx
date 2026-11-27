// The Task Manager page: one row per cmux process with CPU and memory, sortable by any column (a
// header click; again flips it), one selected row, and Kill Process on it from the footer button or
// the row's menu. The app formats the numbers and decides what may be ended; the page only shows it.
import { useVirtualizer } from "@tanstack/react-virtual";
import { memo, useCallback, useLayoutEffect, useRef, useState, useSyncExternalStore, type KeyboardEvent } from "react";
import { Button } from "../../ui/Button";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import type { Strings } from "../shared/i18n";
import { killableRow, pidText, steppedSelection } from "./model";
import type { TaskManagerState, TaskManagerStore } from "./store";
import { COLUMNS, type SortKey, type TaskManagerRow } from "./types";

export interface TaskManagerPageProps {
  store: TaskManagerStore;
  /** The store's state, passed in so the page redraws with each one. */
  state: TaskManagerState;
  strings: Strings;
}

/** The page on its store: redraws with each state the store makes. */
export function TaskManagerRoot({ store, strings }: { store: TaskManagerStore; strings: Strings }) {
  const state = useSyncExternalStore(store.subscribe, store.getState, store.getState);
  return <TaskManagerPage store={store} state={state} strings={strings} />;
}

/** From this many rows the table draws only the rows near the viewport (TanStack Virtual), with a
 * spacer row above and below that keeps the scroll height; below it every row is drawn, as before. */
export const WINDOW_FROM = 200;
/** Rows drawn past each edge of the viewport, so a wheel step or an arrow key lands on drawn rows. */
const OVERSCAN = 12;
/** The control-row height plus the 1px separator: the stride until the first two rows are measured. */
const ROW_STRIDE = 29;

/** The rows a windowed table draws, and the room the rows it skips take above and below them. */
function useRowWindow(table: HTMLTableElement | null, count: number) {
  const windowed = count >= WINDOW_FROM;
  const [geometry, setGeometry] = useState({ stride: ROW_STRIDE, head: ROW_STRIDE });
  const virtualizer = useVirtualizer({
    count,
    enabled: windowed,
    getScrollElement: () => table?.closest<HTMLElement>(".tm-table-scroll") ?? null,
    estimateSize: () => geometry.stride,
    // The rows start below the sticky header, and a row the arrow keys reveal stops below it.
    scrollMargin: geometry.head,
    scrollPaddingStart: geometry.head,
    overscan: OVERSCAN,
    // The window's height until the scroller is measured, so the first frame already has its rows.
    initialRect: { width: 0, height: typeof window === "undefined" ? 800 : window.innerHeight },
  });
  // The rows are one fixed height (CSS), so two drawn rows give the stride every row has.
  useLayoutEffect(() => {
    if (!windowed || !table) return;
    const body = table.tBodies[0];
    const first = body?.querySelector<HTMLElement>(".tm-row");
    const second = first?.nextElementSibling as HTMLElement | null | undefined;
    if (!body || !first || !second?.classList.contains("tm-row")) return;
    const stride = second.offsetTop - first.offsetTop;
    const head = table.offsetTop + body.offsetTop;
    if (stride > 0) setGeometry((last) => (last.stride === stride && last.head === head ? last : { stride, head }));
    // Measured when the table windows or its row count moves, not on each sample or scroll.
  }, [windowed, table, count]);
  useLayoutEffect(() => {
    if (windowed) virtualizer.measure();
  }, [geometry, virtualizer, windowed]);
  if (!windowed) return { windowed, start: 0, end: count, before: 0, after: 0, virtualizer };
  const items = virtualizer.getVirtualItems();
  const start = items[0]?.index ?? 0;
  const end = (items.at(-1)?.index ?? -1) + 1;
  const before = (items[0]?.start ?? geometry.head) - geometry.head;
  // An item's start and end count the header (scrollMargin); the total size does not.
  const after = virtualizer.getTotalSize() - ((items.at(-1)?.end ?? geometry.head) - geometry.head);
  return { windowed, start, end, before, after: Math.max(0, after), virtualizer };
}

export function TaskManagerPage({ store, state, strings }: TaskManagerPageProps) {
  const [table, setTable] = useState<HTMLTableElement | null>(null);
  const tableRef = useCallback((node: HTMLTableElement | null) => setTable(node), []);
  const rowWindow = useRowWindow(table, state.rows.length);
  const shown = rowWindow.windowed ? state.rows.slice(rowWindow.start, rowWindow.end) : state.rows;
  const killable = killableRow(state.snapshot.rows, state.selected);
  const selectedRow = state.rows.find((row) => row.id === state.selected);
  const onKeyDown = (event: KeyboardEvent<HTMLTableElement>) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const next = steppedSelection(state.rows, state.selected, event.key === "ArrowDown" ? 1 : -1);
    store.select(next);
    // The key held off the scroll, so bring the newly selected row into view (as the native table
    // did); otherwise Kill Process could end a row the person cannot see. The rows are drawn in
    // `state.rows` order, and a selection change keeps them, so the index finds its <tr>.
    // A windowed table draws only some rows: one drawn is found by its id; one not drawn yet is
    // scrolled to by its index, which draws it.
    const drawn = [...(event.currentTarget.tBodies[0]?.rows ?? [])].find((tr) => tr.dataset.rowId === next);
    if (drawn) drawn.scrollIntoView?.({ block: "nearest" });
    else if (rowWindow.windowed && next !== null) {
      const index = state.rows.findIndex((row) => row.id === next);
      if (index >= 0) rowWindow.virtualizer.scrollToIndex(index, { align: "auto" });
    }
  };
  // The row menu: a right-click's mouse-down selects its row first, so the menu is about that row.
  const menu: ContextMenuItem[] = selectedRow
    ? [
        {
          id: "kill",
          label: strings.t("taskManager.kill.menu"),
          destructive: true,
          disabled: !killable,
          // A native menu's choice is the person's own; the host still spends that gesture on the kill.
          onSelect: () => store.kill({ isTrusted: true }),
        },
      ]
    : [];
  return (
    <div className="tm-page">
      <ContextMenu className="tm-table-scroll" items={menu}>
        {/* oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- the table takes Up and Down to move the selected row. */}
        <table
          ref={tableRef}
          className="tm-table"
          // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- focusable so its arrow keys reach it.
          tabIndex={0}
          onKeyDown={onKeyDown}
          aria-label={strings.t("taskManager.title")}
          aria-rowcount={state.rows.length + 1}
        >
          <thead>
            <tr>
              {COLUMNS.map((column) => (
                <HeaderCell
                  key={column.key}
                  column={column.key}
                  label={strings.t(column.label)}
                  numeric={column.numeric}
                  sort={state.order?.key === column.key ? (state.order.ascending ? "ascending" : "descending") : "none"}
                  onSort={() => store.sortBy(column.key)}
                />
              ))}
            </tr>
          </thead>
          <tbody>
            {rowWindow.before > 0 ? <Spacer height={rowWindow.before} /> : null}
            {shown.map((row, offset) => (
              <Row
                key={row.id}
                row={row}
                selected={row.id === state.selected}
                store={store}
                rowIndex={rowWindow.windowed ? rowWindow.start + offset + 2 : undefined}
              />
            ))}
            {rowWindow.after > 0 ? <Spacer height={rowWindow.after} /> : null}
          </tbody>
        </table>
        {state.rows.length === 0 ? <p className="tm-empty">{strings.t("taskManager.empty")}</p> : null}
      </ContextMenu>
      <footer className="tm-footer">
        <span className="tm-total">
          {state.snapshot.total ? strings.format("taskManager.total", state.snapshot.total) : ""}
        </span>
        <Button
          size="sm"
          disabled={!killable}
          title={selectedRow?.refusal ?? undefined}
          onClick={(event) => store.kill(event.nativeEvent)}
        >
          {strings.t("taskManager.kill.button")}
        </Button>
      </footer>
    </div>
  );
}

function HeaderCell({
  column,
  label,
  numeric,
  sort,
  onSort,
}: {
  column: SortKey;
  label: string;
  numeric: boolean;
  sort: "ascending" | "descending" | "none";
  onSort: () => void;
}) {
  return (
    <th
      scope="col"
      aria-sort={sort}
      aria-label={label}
      className={numeric ? "tm-numeric" : undefined}
      data-column={column}
    >
      <button type="button" className="tm-sort" onClick={onSort}>
        <span className="tm-sort-label">{label}</span>
        <span className="tm-sort-mark" aria-hidden="true">
          {sort === "ascending" ? "▲" : sort === "descending" ? "▼" : ""}
        </span>
      </button>
    </th>
  );
}

// Its own boundary with stable props: a sample redraws only the rows whose numbers changed (the
// store keeps an unchanged row's object), and a click only the two rows whose selection flipped.
const Row = memo(function Row({
  row,
  selected,
  store,
  rowIndex,
}: {
  row: TaskManagerRow;
  selected: boolean;
  store: TaskManagerStore;
  /** A windowed table's row: its place among all rows (the header is row 1), for assistive tech. */
  rowIndex?: number;
}) {
  return (
    <tr
      className="tm-row"
      aria-rowindex={rowIndex}
      aria-selected={selected}
      data-row-id={row.id}
      data-refused={row.refusal === null ? undefined : ""}
      onMouseDown={() => store.select(row.id)}
    >
      <td>{row.task}</td>
      <td>{row.name}</td>
      <td className="tm-numeric" title={pidText(row)}>
        <PidCell row={row} />
      </td>
      <td className="tm-numeric">{row.cpuText}</td>
      <td className="tm-numeric">{row.memoryText}</td>
    </tr>
  );
});

/** The room of the rows a windowed table does not draw: one empty row, no separator, no hover. */
function Spacer({ height }: { height: number }) {
  return (
    <tr className="tm-spacer" aria-hidden="true">
      <td colSpan={COLUMNS.length} style={{ height, padding: 0, border: 0 }} />
    </tr>
  );
}

/** The PID cell: the pid here; another machine's `host:pid` with only the host ellipsized. */
function PidCell({ row }: { row: TaskManagerRow }) {
  if (row.host === "local") return <>{row.pid}</>;
  return (
    <span className="tm-remote-id">
      <span className="tm-remote-host">{row.host}</span>
      <span className="tm-remote-pid">:{row.pid}</span>
    </span>
  );
}
