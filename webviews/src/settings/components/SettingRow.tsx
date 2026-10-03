import { useId } from "react";
import { useSettingsState } from "../context";
import { Editor } from "../editors/Editor";
import { Icon } from "../icons";
import { revealRow } from "../keyboard";
import type { SchemaRow } from "../schema";
import { managedOf, valueOf } from "../store";
import { t, text } from "../strings";
import { Highlight } from "./Highlight";
import { ResetButton } from "./ResetButton";
import { RowNotice } from "./RowNotice";

/** One setting: title and one-line help on the left, its editor on the right. */
export function SettingRow({
  row,
  query = "",
  focused = false,
}: {
  row: SchemaRow;
  query?: string;
  focused?: boolean;
}) {
  const state = useSettingsState();
  const labelId = useId();
  const managed = managedOf(state, row.key);
  const customized = state.rows.get(row.key)?.customized ?? false;
  const disabled = !state.connected || managed !== null;
  const diagnostics = state.diagnostics.get(row.key);
  const error = state.errors.get(row.key);
  return (
    <div
      className="row"
      data-row-key={row.key}
      data-kind={row.kind}
      data-managed={managed ? "" : undefined}
      tabIndex={-1}
      ref={focused ? revealRow : undefined}
    >
      {diagnostics && <RowNotice settingKey={row.key} messages={diagnostics} disabled={disabled} />}
      <div className="row-main">
        <div className="row-label">
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
              {managed.reason || t("settingsPage.managed")}
            </div>
          )}
          {error && (
            <div className="row-error" role="alert">
              {error.message}
            </div>
          )}
        </div>
        <div className="row-control">
          <Editor row={row} value={valueOf(state, row.key)} disabled={disabled} labelId={labelId} />
          {customized && !managed && row.kind !== "color" && (
            <ResetButton settingKey={row.key} disabled={!state.connected} />
          )}
        </div>
      </div>
    </div>
  );
}
