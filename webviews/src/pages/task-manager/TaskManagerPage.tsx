// The Task Manager page: one row per cmux process with CPU and memory, sortable by any column (a
// header click; again flips it), one selected row, and Kill Process on it from the footer button or
// the row's menu. The app formats the numbers and decides what may be ended; the page only shows it.
import { useSyncExternalStore, type KeyboardEvent } from "react";
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

export function TaskManagerPage({ store, state, strings }: TaskManagerPageProps) {
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
    const index = state.rows.findIndex((row) => row.id === next);
    event.currentTarget.tBodies[0]?.rows[index]?.scrollIntoView?.({ block: "nearest" });
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
            {state.rows.map((row) => (
              <Row key={row.id} row={row} selected={row.id === state.selected} onSelect={() => store.select(row.id)} />
            ))}
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

function Row({ row, selected, onSelect }: { row: TaskManagerRow; selected: boolean; onSelect: () => void }) {
  return (
    <tr
      className="tm-row"
      aria-selected={selected}
      data-row-id={row.id}
      data-refused={row.refusal === null ? undefined : ""}
      onMouseDown={onSelect}
    >
      <td title={row.task}>{row.task}</td>
      <td title={row.name}>{row.name}</td>
      <td className="tm-numeric" title={pidText(row)}>
        <PidCell row={row} />
      </td>
      <td className="tm-numeric" title={row.cpuText}>
        {row.cpuText}
      </td>
      <td className="tm-numeric" title={row.memoryText}>
        {row.memoryText}
      </td>
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
