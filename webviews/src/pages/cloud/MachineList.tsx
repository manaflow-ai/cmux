// The machine list in two prototype layouts (Debug setting `cloud.machines.layout`): dense rows
// (default) and cards. Both draw the same rows: status dot, title, a "Classic" badge for a machine
// from cmux Cloud classic (read-only until upgraded: no inline actions), status or pending intent,
// size (cards), the cost line the sidebar shows (cost.ts), the spending cap's pause (spendCap.ts), and an
// inline Pause or Resume. Automatic cleanup (retention.ts) adds a quiet "Deletes in N days" to the status line
// and the one-time notice inline under its row (Keep or Dismiss; no banner, no modal). Plain Up/Down select,
// Return connects (not a classic machine); chords are ignored.
import type { KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import { costLine, costTicks, useCostClock } from "./cost";
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
import { archiving, deleteDate, shownNotice, type DeleteDate } from "./retention";
import { machineCapNote } from "./spendCap";
import { format, L } from "./strings";

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
}

export function MachineList({
  rows,
  layout,
  selection,
  strings,
  onSelect,
  onOpen,
  onPause,
  onResume,
  dismissed = new Set<string>(),
  onKeep,
  onDismissNotice,
}: MachineListProps) {
  const { t, language } = strings;
  // A running cost or a delete date moves with the clock (once a minute), so neither goes stale.
  const now = useCostClock(rows.some((row) => costTicks(row.machine) || typeof row.machine?.evict_at === "number"));
  const open = (id: string) => {
    if (!rows.find((row) => row.id === id)?.classic) onOpen(id);
  };
  const onKeyDown = (event: KeyboardEvent) => {
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
      {rows.map((row) => {
        const selected = row.id === selection;
        // A running machine's cost line says "Running 2h 14m" itself, so it stands in for the status.
        const cost = row.machine && !row.pending ? costLine(row.machine, now, t, language) : undefined;
        const label = row.pending ? t(IntentLabel[row.pending]) : t(StatusLabel[row.status]);
        const base = cost && costTicks(row.machine) ? cost : cost ? `${label} · ${cost}` : label;
        // The team's spending cap paused it, or pauses it soon (spendCap.ts): said on the row, beside its status.
        const capNote = row.pending ? undefined : machineCapNote(row.machine, t, language);
        const status = capNote ? `${base} · ${capNote}` : base;
        // Kept shows at once on a toggle (a quick intent); the platform's record follows.
        const machine = row.machine && row.keep !== undefined ? { ...row.machine, keep: row.keep } : row.machine;
        const date = row.pending ? undefined : deleteDate(machine, now);
        const leaving = !row.pending && archiving(machine);
        const notice = row.pending || row.classic ? undefined : shownNotice(machine, dismissed);
        const kept = !!machine?.keep;
        // Keep and Archive and delete live in the machine's detail header: the row stays one line of
        // status and date, with Keep only on the one-time notice.
        const memory = row.machine?.size?.memory_mb;
        const size = memory ? formatMegabytes(memory, t, language) : "";
        return (
          <div
            key={row.id}
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
            role="option"
            tabIndex={-1}
            aria-selected={selected}
            aria-disabled={!row.machine}
            className={`cloud-machine layout-${layout}${selected ? " selected" : ""}${row.pending ? " pending" : ""}`}
            ref={selected ? revealOnSelect : undefined}
            onClick={() => row.machine && onSelect(row.id)}
            onDoubleClick={() => row.machine && open(row.id)}
            onKeyDown={(event) => {
              if (!plain(event) || event.key !== "Enter" || !row.machine || event.target !== event.currentTarget)
                return;
              event.preventDefault();
              event.stopPropagation();
              open(row.id);
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
                {status}
                {size && layout === "cards" ? ` · ${size}` : ""}
                {date && <span className="cloud-machine-deletes">{` · ${deleteText(date, t)}`}</span>}
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
      })}
    </div>
  );
}
