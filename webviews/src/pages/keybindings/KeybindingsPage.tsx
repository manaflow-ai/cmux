// The Keyboard Shortcuts page (plans/cmux-next/keybindings.md 8). State lives in
// `KeybindingsStore`; this file only renders it and turns plain keys and clicks into store
// intents. Cmd/Ctrl chords never reach page handlers; recording goes through the app's dispatcher.
import { useState, useSyncExternalStore, type KeyboardEvent, type ReactNode } from "react";
import { Popover, type UiAnchor, type UiVirtualAnchor } from "../../ui/Popover";
import type { Strings } from "../shared/i18n";
import {
  canEditWhen,
  displayStrokes,
  identity,
  isReadOnly,
  keyMatches,
  moveSelection,
  sourceLabel,
  strokeCaps,
} from "./model";
import type { KeybindingsStore, Recording } from "./store";
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
  // Let an IME keep composition Enter and candidate-navigation arrows. WebKit can report only
  // keyCode 229 for the composition commit, so checking isComposing alone is insufficient.
  return !event.metaKey && !event.ctrlKey && !event.altKey && !event.nativeEvent.isComposing && event.keyCode !== 229;
}

/** IME candidate navigation and commit must stay with the composing text field. */
function composing(event: KeyboardEvent): boolean {
  return event.nativeEvent.isComposing || event.keyCode === 229;
}

const ICONS = {
  // A keyboard: the body, two rows of keys and the space bar.
  keyboard:
    "M2.25 4.25h11.5v7.5H2.25ZM4.5 6.5h.01M6.75 6.5h.01M9 6.5h.01M11.25 6.5h.01M4.5 8.5h.01M11.25 8.5h.01M6.25 9.5h3.5",
  // Minus in a circle.
  remove: "M8 1.75a6.25 6.25 0 1 0 0 12.5 6.25 6.25 0 0 0 0-12.5ZM5.25 8h5.5",
  // Counter-clockwise arrow.
  reset: "M3 3.25v3.5h3.5M3.4 6.6A5.25 5.25 0 1 1 3.75 10.5",
  // Cross.
  close: "M4.5 4.5l7 7M11.5 4.5l-7 7",
  // "i" in a circle.
  info: "M8 1.75a6.25 6.25 0 1 0 0 12.5 6.25 6.25 0 0 0 0-12.5ZM8 7.25v3.75M8 5v.01",
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
  // The recording row's keys, read each time the recorder is placed.
  const [recordingKeys] = useState<UiVirtualAnchor>(() => ({
    getBoundingClientRect: () =>
      (document.querySelector(".keys-row.recording .keys-key-button") ?? document.body).getBoundingClientRect(),
  }));

  const tableKeys = (event: KeyboardEvent) => {
    if (!plain(event) || composing(event) || snap.editing) return;
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
    if (!plain(event) || composing(event)) return;
    if (event.key === "Escape" && (snap.text || snap.keyFilter || snap.conflictsOnly)) {
      store.resetQuery();
      event.preventDefault();
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      store.select(moveSelection(snap.rows, snap.selection, event.key === "ArrowDown" ? 1 : -1));
      event.preventDefault();
    } else if (event.key === "Enter" && selected && !isReadOnly(selected)) {
      void store.changeKeybinding(selected);
      event.preventDefault();
    }
  };

  return (
    <div className="keys-page">
      <header className="keys-header">
        <h1 className="keys-title">{t("keybindings.page.title")}</h1>
        <div className="keys-search-row">
          <div className={searchRecording ? "keys-search-field recording" : "keys-search-field"}>
            <input
              className="keys-search"
              type="search"
              // Search by keys records in the field itself: its placeholder says so, and how to stop.
              placeholder={t(searchRecording ? "keybindings.page.recordingPlaceholder" : "keybindings.page.search")}
              aria-label={t(searchRecording ? "keybindings.page.recordingKeys" : "keybindings.page.search")}
              value={snap.text}
              disabled={disconnected}
              // While it records the app takes every key, and the field takes no text of its own; it
              // stays editable so its clear button (the native one) clears the recorded keys.
              onBeforeInput={searchRecording ? (event) => event.preventDefault() : undefined}
              ref={focusOnMount}
              onChange={(event) => store.setText(event.target.value)}
              onKeyDown={searchKeys}
              aria-controls="keys-table"
            />
            {searchRecording && (
              // The mode, inside the field; how to leave it on hover.
              <span className="keys-search-badge" title={t("keybindings.page.recordingExit")} aria-hidden="true">
                {t("keybindings.page.recordingKeys")}
              </span>
            )}
          </div>
          <button
            type="button"
            className={`keys-icon-button keys-record${searchRecording ? " on" : ""}`}
            aria-pressed={searchRecording}
            aria-label={t("keybindings.page.record")}
            title={t("keybindings.page.record")}
            disabled={disconnected}
            onClick={() => void store.toggleSearchRecording()}
          >
            <Icon name="keyboard" />
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
            onClick={() => store.dismissNotice()}
          >
            <Icon name="close" />
          </button>
        </output>
      )}
      {snap.recording?.target === "row" && (
        // One recorder for the page, over the recording row's keys: a save gives the row a new
        // identity (a new row element), and the recorder stays open across it.
        <Recorder
          anchor={recordingKeys}
          binding={snap.recording.binding}
          bindings={snap.bindings}
          recording={snap.recording}
          strings={strings}
          store={store}
        />
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
                    recording={
                      snap.recording?.target === "row" && snap.recording.row === row ? snap.recording : undefined
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

type RowRecording = Extract<Recording, { target: "row" }>;

/** A press in the recorder keeps focus where it was (the search field): its controls unmount
 *  with it, and focus on one would end on nothing. */
const keepFocus = (event: { preventDefault(): void }) => event.preventDefault();

/** A string with `parts` in its `%@` / `%N$@` places ("Already used by <strong>Close Tab</strong>"). */
function fill(text: string, parts: readonly ReactNode[]): ReactNode[] {
  let next = 0;
  const out: ReactNode[] = [];
  let last = 0;
  for (const match of text.matchAll(/%(?:(\d+)\$)?@/g)) {
    out.push(text.slice(last, match.index));
    out.push(parts[match[1] ? Number(match[1]) - 1 : next++] ?? "");
    last = match.index + match[0].length;
  }
  out.push(text.slice(last));
  return out;
}

/** A string with keycaps in its `%@` / `%N$@` places ("Press ⌫ to delete"). */
function withKeys(text: string, keys: readonly string[]) {
  let next = 0;
  const parts: Array<string | { cap: string }> = [];
  let last = 0;
  for (const match of text.matchAll(/%(?:(\d+)\$)?@/g)) {
    parts.push(text.slice(last, match.index));
    parts.push({ cap: keys[match[1] ? Number(match[1]) - 1 : next++] ?? "" });
    last = match.index + match[0].length;
  }
  parts.push(text.slice(last));
  return parts.map((part, index) =>
    typeof part === "string" ? (
      part
    ) : (
      // oxlint-disable-next-line react/no-array-index-key
      <kbd key={index} className="keys-recorder-hint-cap">
        {part.cap}
      </kbd>
    ),
  );
}

/** The recorder over a row's keys while it records: "Press ⌫ to delete" (a row with keys), the
 *  keys as large caps (its own until a key comes, then each key as it goes down, modifiers
 *  included) that start over on a click, a warning when another action has them, and a footer
 *  with the action and Close (Escape drops new keys, Return saves them). The app's recorder
 *  answers the keys; the controls are the same intents. Focus stays. */
function Recorder({
  anchor,
  binding,
  bindings,
  recording,
  strings,
  store,
}: {
  anchor: UiAnchor;
  binding: Binding;
  bindings: readonly Binding[];
  recording: RowRecording;
  strings: Strings;
  store: KeybindingsStore;
}) {
  const { t } = strings;
  // Its own keys until a key comes; then the strokes so far and the modifiers held now.
  const live = Boolean(recording.display || recording.held);
  const strokesShown = displayStrokes(live ? recording.display : binding.display);
  const held = strokeCaps(recording.held);
  const groups = [
    ...strokesShown.map((stroke) => ({ caps: strokeCaps(stroke), held: false })),
    ...(held.length ? [{ caps: held, held: true }] : []),
  ];
  // Conflicts show only for keys this recorder saved, while it shows them: not on open (the keys
  // the row had), and not while new keys go down; the next save shows its own.
  const showsSaved =
    recording.confirmed > 0 &&
    !recording.held &&
    (!recording.key || keyMatches(recording.key, { key: binding.key, exact: true }));
  // The app's conflicts of the saved row (`conflicts`: one of the two never runs).
  const saved = showsSaved
    ? binding.conflicts.flatMap((id) => bindings.filter((other) => other.id === id && !other.removed))
    : [];
  const prompt = recording.prompt;
  // Taken: the actions the new keys would take; the title names them.
  const owners = prompt ? [...new Set(prompt.conflicts.map((other) => other.title))].join(", ") : "";
  // Every owner runs in more places than the new keys: Overwrite takes the keys where they run
  // and leaves the owners theirs everywhere else; the hint says so.
  const scoped = Boolean(prompt?.conflicts.length) && prompt!.conflicts.every((other) => other.takesAll === false);
  // After a save: the saved keys' conflicts.
  const titles = prompt ? [] : [...new Set(saved.map((other) => other.title))];
  const taken = Boolean(prompt || recording.refusal);
  return (
    <Popover
      open
      anchor={anchor}
      label={t("keybindings.page.change")}
      className="keys-recorder"
      initialFocus={false}
      finalFocus={false}
      // A press anywhere else closes it as Close does (new keys are saved); Escape drops them.
      // While it asks, a press elsewhere saves nothing (closeRecording drops the question).
      onOpenChange={(open, details) => {
        if (open) return;
        if (details?.escape) store.stopRecording();
        else store.closeRecording();
      }}
    >
      {recording.confirmed > 0 && (
        // The confirm light: a green glow along the glass's top edge, once per save. It stays
        // mounted (hidden while keys are taken), so a question dropped never plays it again.
        <span
          key={recording.confirmed}
          className={taken ? "keys-recorder-light off" : "keys-recorder-light"}
          aria-hidden="true"
        />
      )}
      {recording.warned > 0 && taken && (
        // The taken light: red, shining down through the glass as the keys turn red.
        <span key={`warned-${recording.warned}`} className="keys-recorder-light danger" aria-hidden="true" />
      )}
      {prompt ? (
        // Taken: "Already used by <action>", the keys in red, "Overwrite it or record a new shortcut".
        <output className="keys-recorder-refusal">
          {fill(t("keybindings.page.recorder.alreadyUsedBy"), [
            <strong key="owner" className="keys-recorder-owner">
              {owners}
            </strong>,
          ])}
        </output>
      ) : recording.refusal && recording.refusalOwner ? (
        // Held by an action the app never takes keys from (one that always runs): "Already used
        // by" it, the app's reason under the keys.
        <output className="keys-recorder-refusal">
          {fill(t("keybindings.page.recorder.alreadyUsedBy"), [
            <strong key="owner" className="keys-recorder-owner">
              {recording.refusalOwner}
            </strong>,
          ])}
        </output>
      ) : recording.refusal ? (
        // Not saved, and no action holds the keys (macOS keeps them): the app's reason.
        <output className="keys-recorder-refusal">{recording.refusal}</output>
      ) : (
        !binding.unset &&
        !prompt && (
          <div className="keys-recorder-hint keys-recorder-delete">
            {withKeys(t("keybindings.page.recorder.delete"), ["⌫"])}
          </div>
        )
      )}
      <button
        type="button"
        className={`keys-recorder-keys${live ? " recorded" : ""}${taken ? " refused" : ""}`}
        aria-label={t("keybindings.page.recorder.edit")}
        aria-live="polite"
        onMouseDown={keepFocus}
        onClick={() => void store.restartRecording()}
      >
        {groups.length ? (
          // One group per stroke, the held modifiers last: a cap keeps its element when the stroke
          // lands, so only the new key pops in.
          groups.map((group, index) => (
            // oxlint-disable-next-line react/no-array-index-key
            <span key={index} className={`keys-recorder-stroke${group.held ? " held" : ""}`}>
              {group.caps.map((cap) => (
                <kbd key={cap} className="keys-recorder-cap">
                  {cap}
                </kbd>
              ))}
            </span>
          ))
        ) : (
          <span className="keys-placeholder">{t("keybindings.page.pressKeys")}</span>
        )}
      </button>
      {prompt && scoped ? (
        <div className="keys-recorder-hint">
          {fill(t("keybindings.page.recorder.keepsBoth"), [recording.binding.title, owners])}
        </div>
      ) : prompt ? (
        <div className="keys-recorder-hint">{t("keybindings.page.recorder.overwriteOrRecord")}</div>
      ) : recording.refusal && recording.refusalOwner ? (
        <div className="keys-recorder-hint">{recording.refusal}</div>
      ) : (
        !recording.refusal && <div className="keys-recorder-hint">{t("keybindings.page.recorder.edit")}</div>
      )}
      {titles.length > 0 && (
        <output className="keys-recorder-conflict">
          <span className="keys-recorder-conflict-label">
            <Icon name="info" />
            {t("keybindings.page.recorder.conflictsWith")}
          </span>
          <span className="keys-recorder-conflict-list">{titles.join(", ")}</span>
        </output>
      )}
      <div className="keys-recorder-actions">
        <span className="keys-recorder-command" title={binding.title}>
          {binding.title}
        </span>
        {prompt ? (
          // The app's recorder answers Escape (Close) and Return (Overwrite); a new shortcut
          // drops the question.
          <span className="keys-recorder-choices">
            <button
              type="button"
              className="keys-recorder-button"
              aria-keyshortcuts="Escape"
              onMouseDown={keepFocus}
              onClick={() => void store.resolveConflict("close")}
            >
              {withKeys(t("keybindings.page.recorder.closeOnly"), ["Esc"])}
            </button>
            <button
              type="button"
              className="keys-recorder-button keys-recorder-overwrite"
              aria-keyshortcuts="Enter"
              onMouseDown={keepFocus}
              onClick={() => void store.resolveConflict("overwrite")}
            >
              {withKeys(t("keybindings.page.recorder.overwrite"), ["↩"])}
            </button>
          </span>
        ) : (
          <button
            type="button"
            className="keys-recorder-button"
            aria-keyshortcuts="Escape Enter"
            onMouseDown={keepFocus}
            onClick={() => store.closeRecording()}
          >
            {withKeys(t("keybindings.page.recorder.close"), ["Esc", "↩"])}
          </button>
        )}
      </div>
    </Popover>
  );
}

interface RowProps {
  binding: Binding;
  strings: Strings;
  selected: boolean;
  editing: boolean;
  /** Set while this row records its new keys. */
  recording?: RowRecording;
  resettable: boolean;
  store: KeybindingsStore;
}

function BindingRow({ binding, strings, selected, editing, recording: rowRecording, resettable, store }: RowProps) {
  const { t } = strings;
  const recording = rowRecording !== undefined;
  // The row shows the table's keys only (what the app holds): the recorder's own keys (still
  // going down, taken, refused) stay in the recorder; a save reaches the row with its green light.
  const shown = binding;
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
        {isReadOnly(binding) ? (
          <Keycaps display={binding.display} />
        ) : (
          // The keys are the control: a click records new ones (Return on the row does too).
          <button
            type="button"
            className="keys-key-button"
            aria-label={
              binding.display ? `${t("keybindings.page.change")}: ${binding.display}` : t("keybindings.page.change")
            }
            title={t("keybindings.page.change")}
            aria-pressed={recording}
            onClick={(event) => {
              event.stopPropagation();
              // While recording, a press here is a press outside the recorder: it already closed
              // it (and saves its keys); ending the recording now would drop them.
              if (!recording) void store.changeKeybinding(binding);
            }}
          >
            {shown.unset ? (
              <span className="keys-placeholder">{t("keybindings.page.notSet")}</span>
            ) : (
              <Keycaps display={shown.display} />
            )}
          </button>
        )}
        {binding.conflicts.length > 0 && !binding.removed && (
          <button
            type="button"
            className="keys-conflict"
            aria-label={strings.format("keybindings.page.conflicts", String(binding.conflicts.length))}
            // tooltip-allow: an icon and a count; the tooltip says what it counts
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
        {binding.heldElsewhere && (
          // GlobalHotKeyService could not take this system-wide key: another app holds it.
          <span className="keys-held-elsewhere" role="note" title={t("keybindings.page.heldElsewhere")}>
            <Icon name="conflict" />
          </span>
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
              if (!plain(event) || composing(event)) return;
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
            disabled={!canEditWhen(binding)}
            onClick={(event) => {
              event.stopPropagation();
              store.editWhen(binding);
            }}
          >
            {binding.when ?? ""}
          </button>
        )}
      </td>
      <td className="keys-col-source">{t(sourceLabel(binding))}</td>
      <td className="keys-col-actions">
        <span className="keys-actions">
          {!isReadOnly(binding) && !binding.unset && (
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
