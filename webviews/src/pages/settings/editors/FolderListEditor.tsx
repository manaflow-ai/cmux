import { useStore } from "../context";
import { Icon } from "../icons";
import { t } from "../strings";
import type { EditorProps } from "./types";

/**
 * A folder list (picker.pinned, files.roots): one row per folder with move up, move down and
 * remove, and Add Folder…, which opens the cmux picker in the app. The person chooses there, so the
 * host writes the new folders itself (`cmux.settings.folders.add`); the page never types a path.
 */
export function FolderListEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const folders = Array.isArray(value) ? value.map(String) : [];
  const write = (next: string[]) => void store.set(row.key, next);
  const move = (index: number, by: number) => {
    const next = [...folders];
    const [item] = next.splice(index, 1);
    next.splice(index + by, 0, item!);
    write(next);
  };
  return (
    <span className="folder-list" aria-labelledby={labelId}>
      {folders.map((folder, index) => (
        <span key={folder} className="folder-item" data-folder={folder}>
          <span className="folder-path selectable">{folder}</span>
          <button
            type="button"
            className="icon-button"
            aria-label={`${t("settingsPage.moveUp")} ${folder}`}
            disabled={disabled || index === 0}
            onClick={() => move(index, -1)}
          >
            <Icon name="chevron" className="icon-up" />
          </button>
          <button
            type="button"
            className="icon-button"
            aria-label={`${t("settingsPage.moveDown")} ${folder}`}
            disabled={disabled || index === folders.length - 1}
            onClick={() => move(index, 1)}
          >
            <Icon name="chevron" />
          </button>
          <button
            type="button"
            className="icon-button"
            aria-label={`${t("settingsPage.remove")} ${folder}`}
            disabled={disabled}
            onClick={() => write(folders.filter((item) => item !== folder))}
          >
            <Icon name="xmark" />
          </button>
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
