// The Keyboard Shortcuts page (plans/cmux-next/keybindings.md 8). State lives in
// `KeybindingsStore`; this file only renders it and turns plain keys and clicks into store
// intents. Cmd/Ctrl chords never reach page handlers; recording goes through the app's dispatcher.
import { useSyncExternalStore, type KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import { displayStrokes, identity, isReadOnly, moveSelection, SourceLabel } from "./model";
import type { KeybindingsStore } from "./store";
import type { Binding } from "./types";

const focusOnMount = (node: HTMLInputElement | null) => node?.focus();
const editOnMount = (node: HTMLInputElement | null) => {
  if (!node) return;
  node.focus();
  node.select();
};
const revealOnSelect = (node: HTMLTableRowElement | null) => node?.scrollIntoView?.({ block: "nearest" });

/** A plain key: no Cmd, Ctrl or Option (those belong to the app's key dispatcher). */
function plain(event: KeyboardEvent): boolean {
  return !event.metaKey && !event.ctrlKey && !event.altKey;
}

const ICONS = {
  // Pencil.
  change: "M10.75 2.75 13.25 5.25 5.5 13H3v-2.5ZM9 4.5l2.5 2.5",
  // Minus in a circle.
  remove: "M8 1.75a6.25 6.25 0 1 0 0 12.5 6.25 6.25 0 0 0 0-12.5ZM5.25 8h5.5",
  // Counter-clockwise arrow.
  reset: "M3 3.25v3.5h3.5M3.4 6.6A5.25 5.25 0 1 1 3.75 10.5",
  // Cross.
  close: "M4.5 4.5l7 7M11.5 4.5l-7 7",
  // Warning triangle.
  conflict: "M8 2.25 14.25 13.25H1.75ZM8 6.5v3M8 11.25v.25",
};

function Icon({ name }: { name: keyof typeof ICONS }) {
  return (
    <svg className="keys-icon" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
      <path
        d={ICONS[name]}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function Keycaps({ display }: { display: string }) {
  return (
    <span className="keys-caps">
      {displayStrokes(display).map((stroke, index) => (
        // oxlint-disable-next-line react/no-array-index-key
        <kbd key={index} className="keys-cap">
          {stroke}
        </kbd>
      ))}
    </span>
  );
}

export function KeybindingsPage({ store, strings }: { store: KeybindingsStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = strings;
  const disconnected = snap.connection === "disconnected";
  const searchRecording = snap.recording?.target === "search";
  const selected = snap.rows.find((row) => identity(row) === snap.selection);

  const tableKeys = (event: KeyboardEvent) => {
    if (!plain(event) || snap.editing) return;
    // Return on a focused button belongs to that button.
    const onControl = (event.target as Element).closest?.("button, input") != null;
    if (event.key === "ArrowDown") store.select(moveSelection(snap.rows, snap.selection, 1));
    else if (event.key === "ArrowUp") store.select(moveSelection(snap.rows, snap.selection, -1));
    else if (event.key === "Enter" && !onControl && selected && !isReadOnly(selected))
      void store.changeKeybinding(selected);
    else return;
    event.preventDefault();
  };

  const searchKeys = (event: KeyboardEvent<HTMLInputElement>) => {
    if (!plain(event)) return;
    if (event.key === "Escape" && (snap.text || snap.keyFilter || snap.conflictsOnly)) {
      store.resetQuery();
      event.preventDefault();
    } else if (event.key === "ArrowDown") {
      store.select(moveSelection(snap.rows, snap.selection, 1));
      event.preventDefault();
    }
  };

  return (
    <div className="keys-page">
      <header className="keys-header">
        <h1 className="keys-title">{t("keybindings.page.title")}</h1>
        <div className="keys-search-row">
          <input
            className="keys-search"
            type="search"
            placeholder={t("keybindings.page.search")}
            aria-label={t("keybindings.page.search")}
            value={snap.text}
            disabled={disconnected}
            readOnly={searchRecording}
            ref={focusOnMount}
            onChange={(event) => store.setText(event.target.value)}
            onKeyDown={searchKeys}
            aria-controls="keys-table"
          />
          <button
            type="button"
            className={`keys-toggle keys-record${searchRecording ? " on" : ""}`}
            aria-pressed={searchRecording}
            disabled={disconnected}
            onClick={() => void store.toggleSearchRecording()}
          >
            {t("keybindings.page.record")}
          </button>
        </div>
        <div className="keys-filters">
          <button
            type="button"
            className={`keys-toggle keys-conflicts-only${snap.conflictsOnly ? " on" : ""}`}
            aria-pressed={snap.conflictsOnly}
            disabled={disconnected}
            onClick={() => store.setConflictsOnly(!snap.conflictsOnly)}
          >
            {t("keybindings.page.conflictsOnly")}
          </button>
          {snap.recording && <span className="keys-hint">{t("keybindings.page.recordHint")}</span>}
          <span className="keys-spacer" />
          <button
            type="button"
            className="keys-toggle keys-import"
            disabled={disconnected}
            onClick={() => void store.importKeymap()}
          >
            {t("keybindings.page.importKeymap")}
          </button>
          <button
            type="button"
            className="keys-toggle keys-export"
            disabled={disconnected}
            onClick={() => void store.exportKeymap()}
          >
            {t("keybindings.page.exportKeymap")}
          </button>
        </div>
      </header>
      {snap.notice && (
        <output className="keys-notice">
          <span>
            {snap.notice.kind === "unsupported"
              ? t("keybindings.page.unsupported")
              : strings.format("keybindings.page.failed", snap.notice.message)}
          </span>
          <button
            type="button"
            className="keys-icon-button"
            aria-label={t("keybindings.page.dismiss")}
            title={t("keybindings.page.dismiss")}
            onClick={() => store.dismissNotice()}
          >
            <Icon name="close" />
          </button>
        </output>
      )}
      {disconnected ? (
        <div className="keys-empty">{t("keybindings.page.disconnected")}</div>
      ) : snap.rows.length === 0 ? (
        <div className="keys-empty">
          {snap.loading
            ? ""
            : t(snap.text || snap.conflictsOnly ? "keybindings.page.emptySearch" : "keybindings.page.empty")}
        </div>
      ) : (
        <div className="keys-scroll">
          <table
            id="keys-table"
            className="keys-table"
            // ARIA in HTML allows role grid on a table: it takes Up/Down and Return.
            // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-to-interactive-role
            role="grid"
            aria-label={t("keybindings.page.title")}
            tabIndex={0}
            onKeyDown={tableKeys}
          >
            <thead>
              <tr>
                <th scope="col" className="keys-col-command">
                  {t("keybindings.page.column.command")}
                </th>
                <th scope="col" className="keys-col-key">
                  {t("keybindings.page.column.key")}
                </th>
                <th scope="col" className="keys-col-when">
                  {t("keybindings.page.column.when")}
                </th>
                <th scope="col" className="keys-col-source">
                  {t("keybindings.page.column.source")}
                </th>
                <th scope="col" className="keys-col-actions">
                  <span className="keys-visually-hidden">{t("keybindings.page.column.actions")}</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {snap.rows.map((binding) => {
                const row = identity(binding);
                return (
                  <BindingRow
                    key={row}
                    binding={binding}
                    strings={strings}
                    selected={row === snap.selection}
                    editing={row === snap.editing}
                    recordingDisplay={
                      snap.recording?.target === "row" && snap.recording.row === row
                        ? snap.recording.display
                        : undefined
                    }
                    resettable={snap.resettable.has(binding.command)}
                    store={store}
                  />
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

interface RowProps {
  binding: Binding;
  strings: Strings;
  selected: boolean;
  editing: boolean;
  /** Set while this row records its new keys ("" before the first stroke). */
  recordingDisplay?: string;
  resettable: boolean;
  store: KeybindingsStore;
}

function BindingRow({ binding, strings, selected, editing, recordingDisplay, resettable, store }: RowProps) {
  const { t } = strings;
  const recording = recordingDisplay !== undefined;
  const classes = ["keys-row", selected && "selected", binding.removed && "removed", recording && "recording"];
  return (
    <tr
      className={classes.filter(Boolean).join(" ")}
      aria-selected={selected}
      ref={selected ? revealOnSelect : undefined}
      onClick={() => store.select(identity(binding))}
    >
      <td className="keys-col-command">
        <span className="keys-command-title">{binding.title}</span>
        <span className="keys-command-id">{binding.command}</span>
      </td>
      <td className="keys-col-key">
        {recording ? (
          recordingDisplay ? (
            <Keycaps display={recordingDisplay} />
          ) : (
            <span className="keys-placeholder">{t("keybindings.page.pressKeys")}</span>
          )
        ) : (
          <Keycaps display={binding.display} />
        )}
        {binding.conflicts.length > 0 && !binding.removed && (
          <button
            type="button"
            className="keys-conflict"
            aria-label={strings.format("keybindings.page.conflicts", String(binding.conflicts.length))}
            title={strings.format("keybindings.page.conflicts", String(binding.conflicts.length))}
            onClick={(event) => {
              event.stopPropagation();
              store.showSameKeys(binding);
            }}
          >
            <Icon name="conflict" />
            {binding.conflicts.length}
          </button>
        )}
      </td>
      <td className="keys-col-when">
        {editing ? (
          <input
            className="keys-when-input"
            defaultValue={binding.when ?? ""}
            aria-label={t("keybindings.page.editWhen")}
            ref={editOnMount}
            onClick={(event) => event.stopPropagation()}
            onBlur={() => store.cancelEdit()}
            onKeyDown={(event) => {
              event.stopPropagation();
              if (!plain(event)) return;
              if (event.key === "Enter") {
                event.preventDefault();
                void store.commitWhen(binding, event.currentTarget.value);
              } else if (event.key === "Escape") {
                event.preventDefault();
                store.cancelEdit();
              }
            }}
          />
        ) : (
          <button
            type="button"
            className="keys-when"
            aria-label={`${t("keybindings.page.editWhen")}${binding.when ? `: ${binding.when}` : ""}`}
            disabled={isReadOnly(binding)}
            onClick={(event) => {
              event.stopPropagation();
              store.editWhen(binding);
            }}
          >
            {binding.when ?? ""}
          </button>
        )}
      </td>
      <td className="keys-col-source">{t(SourceLabel[binding.removed ? "removed" : binding.source])}</td>
      <td className="keys-col-actions">
        <span className="keys-actions">
          {!isReadOnly(binding) && (
            <button
              type="button"
              className="keys-icon-button keys-change"
              aria-label={t("keybindings.page.change")}
              title={t("keybindings.page.change")}
              aria-pressed={recording}
              onClick={(event) => {
                event.stopPropagation();
                if (recording) store.stopRecording();
                else void store.changeKeybinding(binding);
              }}
            >
              <Icon name="change" />
            </button>
          )}
          {!isReadOnly(binding) && (
            <button
              type="button"
              className="keys-icon-button keys-remove"
              aria-label={t("keybindings.page.remove")}
              title={t("keybindings.page.remove")}
              onClick={(event) => {
                event.stopPropagation();
                void store.remove(binding);
              }}
            >
              <Icon name="remove" />
            </button>
          )}
          {resettable && (
            <button
              type="button"
              className="keys-icon-button keys-reset"
              aria-label={t("keybindings.page.reset")}
              title={t("keybindings.page.reset")}
              onClick={(event) => {
                event.stopPropagation();
                void store.reset(binding);
              }}
            >
              <Icon name="reset" />
            </button>
          )}
        </span>
      </td>
    </tr>
  );
}
