import { useId } from "react";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { useSettingsState, useStore } from "../context";
import { Editor } from "../editors/Editor";
import { Icon } from "../icons";
import { revealRow } from "../keyboard";
import type { SchemaRow } from "../schema";
import { managedOf, managedText, valueOf } from "../store";
import { t, text } from "../strings";
import { Highlight } from "./Highlight";
import { ResetButton } from "./ResetButton";
import { RowNotice } from "./RowNotice";

/** One setting: title and one-line help on the left, its editor on the right. */
export function SettingRow({
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
  const state = useSettingsState();
  const store = useStore();
  const labelId = useId();
  const managed = managedOf(state, row.key);
  const customized = state.rows.get(row.key)?.customized ?? false;
  const disabled = !state.connected || !state.readable || managed !== null;
  const diagnostics = state.diagnostics.get(row.key);
  const error = state.errors.get(row.key);
  // Right-click on the setting's title or help: copy its cmux.json key, or reset it (the row's
  // Reset control's path).
  const menu: ContextMenuItem[] = [
    { id: "copyKey", label: t("settingsPage.copySettingKey"), onSelect: () => void store.copy(row.key) },
    {
      id: "reset",
      label: t("settingsPage.resetToDefault"),
      separatorBefore: true,
      disabled: !customized || managed !== null || !state.connected || !state.readable,
      onSelect: () => void store.reset(row.key),
    },
  ];
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
          {row.help && (
            <div className="row-help">
              <Highlight text={text(row.help)} query={query} />
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
            <div className="row-error" role="alert" title={error.detail}>
              {row.key === "agents.chats.roots" && error.detail ? error.detail : error.message}
            </div>
          )}
        </ContextMenu>
        <div className="row-control">
          <Editor row={row} value={valueOf(state, row.key)} disabled={disabled} labelId={labelId} />
          <ResetButton
            settingKey={row.key}
            shown={customized && !managed}
            disabled={!state.connected || !state.readable}
            label={row.kind === "color" ? t("settingsPage.useThemeColor") : undefined}
          />
        </div>
      </div>
    </div>
  );
}
