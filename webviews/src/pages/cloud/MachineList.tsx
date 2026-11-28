// The machine list in two prototype layouts (Debug setting `cloud.machines.layout`): dense rows
// (default) and cards. Both draw the same rows: status dot, title, a "Classic" badge for a machine
// from cmux Cloud classic (read-only until upgraded: no inline actions), status or pending intent,
// size (cards), and an inline Pause or Resume. Plain Up/Down select, Return connects (not a classic
// machine); chords are ignored.
import type { KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import {
  canPause,
  canResume,
  formatMegabytes,
  IntentLabel,
  moveSelection,
  plain,
  StatusLabel,
  transitional,
  type MachineLayout,
  type MachineRow,
} from "./model";
import { L } from "./strings";

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
}: MachineListProps) {
  const { t, language } = strings;
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
        const status = row.pending ? t(IntentLabel[row.pending]) : t(StatusLabel[row.status]);
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
              </span>
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
