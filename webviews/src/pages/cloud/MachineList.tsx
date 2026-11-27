// The machine list in two prototype layouts (Debug setting `cloud.machines.layout`): dense rows
// (default) and cards. Both draw the same rows: status dot, title, a "Classic" badge for a machine
// from cmux Cloud classic (read-only until upgraded: no inline actions), status or pending intent,
// size (cards), the cost line the sidebar shows (cost.ts), the spending cap's pause (spendCap.ts), and an
// inline Pause or Resume. Automatic cleanup (retention.ts) adds a quiet "Deletes in N days" to the status line
// and the one-time notice inline under its row (Keep or Dismiss; no banner, no modal). Plain Up/Down select,
// Return connects (not a classic machine); chords are ignored.
import { memo, useCallback, type KeyboardEvent } from "react";
import { useDeadlineNow } from "../../ui/pageClock";
import type { Strings } from "../shared/i18n";
import type { KeyStyle, ShortcutLayout } from "../../ui/keyStyle";
import { useListKeys } from "../../ui/useListKeys";
import { costLine, costTicks } from "./cost";
import {
  canPause,
  canResume,
  formatDate,
  formatMegabytes,
  IntentLabel,
  moveSelection,
  plain,
  StatusLabel,
  transitional,
  type MachineLayout,
  type MachineRow,
} from "./model";
import { archiving, deleteDate, shownNotice, type DeleteDate, noticeKey } from "./retention";
import { machineCapNote } from "./spendCap";
import { format, L } from "./strings";
import { DiskHealthSummary } from "./DiskHealth";

/** The row's quiet delete line ("Deletes in 12 days"). */
export function deleteText(date: DeleteDate, t: (key: string) => string): string {
  if (date.kind === "today") return t(L.deletesToday);
  if (date.kind === "tomorrow") return t(L.deletesTomorrow);
  return format(t(L.deletesInDays), { count: date.days });
}

const revealOnSelect = (node: HTMLDivElement | null) => node?.scrollIntoView({ block: "nearest" });

export interface MachineListProps {
  rows: MachineRow[];
  layout: MachineLayout;
  selection?: string;
  strings: Strings;
  onSelect: (id: string) => void;
  onOpen: (id: string) => void;
  onPause: (id: string) => void;
  onResume: (id: string) => void;
  /** Retention notices dismissed in this browser (`machine:notice.at`). */
  dismissed?: ReadonlySet<string>;
  onKeep?: (id: string, keep: boolean) => void;
  onDismissNotice?: (id: string, at: number) => void;
  /** `app.keyStyle` and `app.shortcutLayout`; without them the page's own (Standard). */
  keyStyle?: KeyStyle;
  shortcutLayout?: ShortcutLayout;
}

const NO_DISMISSED: ReadonlySet<string> = new Set<string>();

export function MachineList({
  rows,
  layout,
  selection,
  strings,
  onSelect,
  onOpen,
  onPause,
  onResume,
  dismissed = NO_DISMISSED,
  onKeep,
  onDismissNotice,
  keyStyle,
  shortcutLayout,
}: MachineListProps) {
  const open = (id: string) => {
    if (!rows.find((row) => row.id === id)?.classic) onOpen(id);
  };
  // `app.keyStyle` (the host's values as props): Vim's j/k, gg/G and l, Emacs' Ctrl-N/P/A/E/F, as
  // the arrows and Return. The list has no search field, Esc or paging, so those keys go on.
  const styleKeys = useListKeys({
    style: keyStyle,
    layout: shortcutLayout,
    onCommand: (command) => {
      const real = rows.filter((row) => row.machine);
      const to =
        command === "list.next"
          ? moveSelection(rows, selection, 1)
          : command === "list.previous"
            ? moveSelection(rows, selection, -1)
            : command === "list.first"
              ? real[0]?.id
              : command === "list.last"
                ? real.at(-1)?.id
                : undefined;
      if (to) return onSelect(to);
      if (command === "list.open" && selection) return open(selection);
      return ["list.next", "list.previous", "list.first", "list.last"].includes(command);
    },
  });
  const onKeyDown = (event: KeyboardEvent) => {
    styleKeys(event);
    if (event.defaultPrevented) return;
    // Only keys aimed at the list itself or a row; a focused inline button keeps its own Return.
    if (!plain(event) || (event.target as HTMLElement).tagName === "BUTTON") return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      const next = moveSelection(rows, selection, event.key === "ArrowDown" ? 1 : -1);
      if (next) onSelect(next);
    } else if (event.key === "Enter" && selection) open(selection);
    else return;
    event.preventDefault();
  };
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
    <div className={`cloud-machine-list layout-${layout}`} role="listbox" tabIndex={0} onKeyDown={onKeyDown}>
      {rows.map((row) => (
        <MachineItem
          key={row.id}
          row={row}
          layout={layout}
          selected={row.id === selection}
          strings={strings}
          noticeDismissed={noticeDismissed(row, dismissed)}
          onSelect={onSelect}
          onOpen={onOpen}
          onPause={onPause}
          onResume={onResume}
          onKeep={onKeep}
          onDismissNotice={onDismissNotice}
        />
      ))}
    </div>
  );
}

type MachineItemProps = Omit<MachineListProps, "rows" | "selection" | "dismissed"> & {
  row: MachineRow;
  selected: boolean;
  /** This browser dismissed the machine's current notice: a boolean per row, so dismissing one
   * notice draws that row alone, not every row given the new set. */
  noticeDismissed: boolean;
};

const noticeDismissed = (row: MachineRow, dismissed: ReadonlySet<string>) => {
  const notice = row.machine?.notice;
  return !!notice && dismissed.has(noticeKey(row.id, notice.at));
};

/** Rows rebuilt from an unchanged machine (the mirror rebuilds every row on each event) count as
 * unchanged: a row draws again only when its own machine, intent or selection changed. */
const sameItem = (a: MachineItemProps, b: MachineItemProps) =>
  (Object.keys(a) as (keyof MachineItemProps)[]).every((key) =>
    key === "row" ? sameRow(a.row, b.row) : Object.is(a[key], b[key]),
  ) && Object.keys(a).length === Object.keys(b).length;

// Every field of a row (its machine by identity: the mirror keeps an unchanged machine's object). A
// new field fails to compile here until it is listed, so a rebuilt row never hides a change.
const ROW_FIELDS: Record<keyof MachineRow, true> = {
  id: true,
  title: true,
  status: true,
  machine: true,
  pending: true,
  idle: true,
  keep: true,
  classic: true,
};
const FIELDS = Object.keys(ROW_FIELDS) as (keyof MachineRow)[];
const sameRow = (a: MachineRow, b: MachineRow) => a === b || FIELDS.every((key) => Object.is(a[key], b[key]));

const MachineItem = memo(function MachineItem({
  row,
  layout,
  selected,
  strings,
  noticeDismissed,
  onSelect,
  onOpen,
  onPause,
  onResume,
  onKeep,
  onDismissNotice,
}: MachineItemProps) {
  const { t, language } = strings;
  const open = () => {
    if (!row.classic) onOpen(row.id);
  };
  // Kept shows at once on a toggle (a quick intent); the platform's record follows.
  const machine = row.machine && row.keep !== undefined ? { ...row.machine, keep: row.keep } : row.machine;
  const leaving = !row.pending && archiving(machine);
  const notice = row.pending || row.classic || noticeDismissed ? undefined : shownNotice(machine, NO_DISMISSED);
  const kept = !!machine?.keep;
  // Keep and Archive and delete live in the machine's detail header: the row stays one line of
  // status and date, with Keep only on the one-time notice.
  const memory = row.machine?.size?.memory_mb;
  const size = memory ? formatMegabytes(memory, t, language) : "";
  // A running cost or a delete date moves with the clock (once a minute); only such a row keeps one.
  const ticks = !row.pending && (costTicks(row.machine) || typeof machine?.evict_at === "number");
  return (
    <div
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="option"
      tabIndex={-1}
      aria-selected={selected}
      aria-disabled={!row.machine}
      className={`cloud-machine layout-${layout}${selected ? " selected" : ""}${row.pending ? " pending" : ""}`}
      ref={selected ? revealOnSelect : undefined}
      onClick={() => row.machine && onSelect(row.id)}
      onDoubleClick={() => row.machine && open()}
      onKeyDown={(event) => {
        if (!plain(event) || event.key !== "Enter" || !row.machine || event.target !== event.currentTarget) return;
        event.preventDefault();
        event.stopPropagation();
        open();
      }}
    >
      <span
        className={`cloud-status-dot status-${row.status}${row.pending || transitional(row.status) ? " pending" : ""}`}
        aria-hidden="true"
      />
      <span className="cloud-machine-text">
        <span className="cloud-machine-title">{row.title || t(IntentLabel.create)}</span>
        {row.classic && <span className="cloud-badge cloud-classic-badge">{t(L.classic)}</span>}
        <span className="cloud-machine-subtitle">
          {/* Keyed by whether it ticks: one that starts ticking reads the time afresh. */}
          <MachineTimes key={ticks ? "ticks" : "still"} row={row} ticks={ticks} strings={strings} />
          {size && layout === "cards" ? ` · ${size}` : ""}
          <MachineDate
            key={ticks ? "ticks" : "still"}
            machine={row.pending ? undefined : machine}
            ticks={ticks}
            strings={strings}
          />
          {machine?.disk_health && (
            <span className="cloud-machine-disk">
              <DiskHealthSummary health={machine.disk_health} strings={strings} compact />
            </span>
          )}
          {leaving && <span className="cloud-machine-deletes">{` · ${t(L.archivingNote)}`}</span>}
          {kept && <span className="cloud-machine-deletes cloud-machine-kept">{` · ${t(L.kept)}`}</span>}
        </span>
        {notice && (
          // The one notice before a delete, once: Keep, or Dismiss (remembered per notice).
          <output className="cloud-machine-notice">
            <span className="cloud-machine-notice-text">
              {format(t(notice.kind === "heads_up" ? L.noticeHeadsUp : L.noticeLastNote), {
                date: formatDate(notice.delete_at, language, false),
              })}
            </span>
            <button
              type="button"
              className="cloud-link-button cloud-notice-keep"
              onClick={(event) => (event.stopPropagation(), onKeep?.(row.id, true))}
            >
              {t(L.keep)}
            </button>
            <button
              type="button"
              className="cloud-link-button cloud-notice-dismiss"
              onClick={(event) => (event.stopPropagation(), onDismissNotice?.(row.id, notice.at))}
            >
              {t(L.dismissError)}
            </button>
          </output>
        )}
      </span>
      {canPause(row) && (
        <button
          type="button"
          className="cloud-link-button cloud-machine-toggle"
          onClick={(event) => (event.stopPropagation(), onPause(row.id))}
        >
          {t(L.pause)}
        </button>
      )}
      {canResume(row) && (
        <button
          type="button"
          className="cloud-link-button cloud-machine-toggle"
          onClick={(event) => (event.stopPropagation(), onResume(row.id))}
        >
          {t(L.resume)}
        </button>
      )}
    </div>
  );
}, sameItem);

const MINUTE = 60_000;
const nextMinute = (now: number) => (Math.floor(now / MINUTE) + 1) * MINUTE;
const never = () => Number.POSITIVE_INFINITY;

/** The row's status, with the cost line the sidebar shows; a running machine's moves each minute. */
function MachineTimes({ row, ticks, strings }: { row: MachineRow; ticks: boolean; strings: Strings }) {
  const { t, language } = strings;
  // "Running 2h 14m" moves a minute after the machine started, then each minute.
  const since = row.machine?.running_since;
  const next = useCallback(
    (now: number) =>
      typeof since === "number" ? since + (Math.floor((now - since) / MINUTE) + 1) * MINUTE : nextMinute(now),
    [since],
  );
  const now = useDeadlineNow(ticks ? next : never);
  // A running machine's cost line says "Running 2h 14m" itself, so it stands in for the status.
  const cost = row.machine && !row.pending ? costLine(row.machine, now, t, language) : undefined;
  const label = row.pending ? t(IntentLabel[row.pending]) : t(StatusLabel[row.status]);
  const base = cost && costTicks(row.machine) ? cost : cost ? `${label} · ${cost}` : label;
  // The team's spending cap paused it, or pauses it soon (spendCap.ts): said on the row, beside its status.
  const capNote = row.pending ? undefined : machineCapNote(row.machine, t, language);
  return <>{capNote ? `${base} · ${capNote}` : base}</>;
}

/** The quiet "Deletes in 12 days"; it reads the clock only when the machine has a delete time. */
function MachineDate({
  machine,
  ticks,
  strings,
}: {
  machine: MachineRow["machine"];
  ticks: boolean;
  strings: Strings;
}) {
  const now = useDeadlineNow(ticks ? nextMinute : never);
  const date = deleteDate(machine, now);
  return date ? <span className="cloud-machine-deletes">{` · ${deleteText(date, strings.t)}`}</span> : null;
}
