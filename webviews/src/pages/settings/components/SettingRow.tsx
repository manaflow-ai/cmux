import { memo, useId } from "react";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { useRowState, useStore, type RowState } from "../context";
import { Editor } from "../editors/Editor";
import { Icon } from "../icons";
import { revealRow } from "../keyboard";
import type { SchemaRow } from "../schema";
import { managedText, type SettingsStore } from "../store";
import { t, text } from "../strings";
import { Highlight } from "./Highlight";
import { ResetButton } from "./ResetButton";
import { RowNotice } from "./RowNotice";

/**
 * The menu of a setting's title and summary (right-click): copy its cmux.json key, or reset it (the
 * row's Reset control's path). Every row that edits a setting uses it, including the Theme page's
 * own rows (cx-64hi).
 */
export function useRowMenu(key: string): ContextMenuItem[] {
  return rowMenu(key, useRowState(key), useStore());
}

function rowMenu(key: string, state: RowState, store: SettingsStore): ContextMenuItem[] {
  const { managed, customized } = state;
  return [
    { id: "copyKey", label: t("settingsPage.copySettingKey"), onSelect: () => void store.copy(key) },
    {
      id: "reset",
      label: t("settingsPage.resetToDefault"),
      separatorBefore: true,
      disabled: !customized || managed !== null || !state.connected || !state.readable,
      onSelect: () => void store.reset(key),
    },
  ];
}

/** Editable text, whose right-click keeps WebKit's Cut, Copy and Paste. */
const TEXT_FIELDS =
  'input:not([type="checkbox"]):not([type="radio"]):not([type="range"]), textarea, [contenteditable]:not([contenteditable="false"])';

/** One setting: title and its one short summary line on the left, its editor on the right. It
 * renders when its props or its own key's state change, never for another key's change. */
export const SettingRow = memo(function SettingRow({
  row,
  query = "",
  focused = false,
  filtered = false,
}: {
  row: SchemaRow;
  query?: string;
  focused?: boolean;
  /** Outside the search filter: collapsed in place, inert and hidden from assistive technology. */
  filtered?: boolean;
}) {
  const state = useRowState(row.key);
  const store = useStore();
  const labelId = useId();
  const { managed, customized, diagnostics, error } = state;
  const disabled = !state.connected || !state.readable || managed !== null;
  const menu = rowMenu(row.key, state, store);
  return (
    <div
      className="row"
      data-row-key={row.key}
      data-kind={row.kind}
      data-managed={managed ? "" : undefined}
      data-filtered={filtered ? "" : undefined}
      inert={filtered}
      aria-hidden={filtered ? true : undefined}
      tabIndex={-1}
      // Revealed once the owner's values arrive: before that every control is disabled.
      ref={focused && state.readable ? revealRow : undefined}
    >
      {diagnostics && <RowNotice settingKey={row.key} messages={diagnostics} disabled={disabled} />}
      <div className="row-main">
        <ContextMenu className="row-label" items={menu}>
          <div className="row-title" id={labelId}>
            <Highlight text={text(row.title)} query={query} />
          </div>
          {row.summary && (
            <div className="row-help">
              <Highlight text={text(row.summary)} query={query} />
            </div>
          )}
          {query && (
            <div className="row-key">
              <Highlight text={row.key} query={query} />
            </div>
          )}
          {managed && (
            <div className="row-managed" data-managed-reason="">
              <Icon name="lock" />
              {managedText(managed)}
            </div>
          )}
          {error && (
            <div
              className="row-error"
              role="alert"
              /* tooltip-allow: the failure's detail, shown nowhere else */ title={error.detail}
            >
              {row.key === "agents.chats.roots" && error.detail ? error.detail : error.message}
            </div>
          )}
        </ContextMenu>
        {/* The control has the row's menu too (cx-2lm4); a text field keeps its own Cut, Copy and Paste. */}
        <ContextMenu className="row-control-menu" items={menu} ignore={TEXT_FIELDS}>
          <div className="row-control">
            <Editor row={row} value={state.value} disabled={disabled} labelId={labelId} />
            <ResetButton
              settingKey={row.key}
              shown={customized && !managed}
              disabled={!state.connected || !state.readable}
              label={row.kind === "color" ? t("settingsPage.useThemeColor") : undefined}
            />
          </div>
        </ContextMenu>
      </div>
    </div>
  );
});
