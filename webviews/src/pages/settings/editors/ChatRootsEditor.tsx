import { useSettingsState, useStore } from "../context";
import { Icon } from "../icons";
import { t } from "../strings";
import type { EditorProps } from "./types";

/** Managed roots are additive locked rows. Writes contain only the person's roots. Refusals
 * come from the native validator, which knows this device's home and symbolic links. */
export function ChatRootsEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const state = useSettingsState();
  const live = state.rows.get(row.key);
  const folders =
    live?.folders ??
    (Array.isArray(value) ? value.map(String).map((path) => ({ path, managed: false, reason: null })) : []);
  const userRoots = live?.user_roots ?? folders.filter((folder) => !folder.managed).map((folder) => folder.path);
  return (
    <span className="folder-list" aria-labelledby={labelId}>
      {folders.map((folder) => (
        <span
          key={folder.path}
          className="folder-item"
          data-folder={folder.path}
          data-locked={folder.managed || undefined}
        >
          <span className="folder-path selectable">
            {folder.path}
            {folder.reason && (
              <span className="row-error" role="status">
                {folder.reason}
              </span>
            )}
          </span>
          {folder.managed ? (
            <span className="row-managed" title={t("settingsWindow.managed.device")}>
              <Icon name="lock" />
            </span>
          ) : (
            <button
              type="button"
              className="button"
              disabled={disabled}
              aria-label={`${t("settingsPage.remove")} ${folder.path}`}
              onClick={() =>
                void store.set(
                  row.key,
                  userRoots.filter((path) => path !== folder.path),
                )
              }
            >
              {t("settingsPage.remove")}
            </button>
          )}
        </span>
      ))}
      <button
        type="button"
        className="button"
        data-add-folder=""
        disabled={disabled}
        onClick={() => void store.addFolders(row.key)}
      >
        {t("settingsPage.addFolder")}
      </button>
    </span>
  );
}
