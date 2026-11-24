import { useT } from "./i18n";
import { extraFolderName } from "./extraFolders";

/// The folders a new chat sees beside its project (extraFolders.ts), under the folder menu's list:
/// "Also sees", then one row each, named by the folder (its path in the tooltip), with × to remove
/// it. Leo, 2026-11-03: "being able to have chatgpt (and in this case, any harnesses) see whatever
/// folders/files would be cool".
export function ExtraFolderList({ folders, onRemove }: { folders: readonly string[]; onRemove(path: string): void }) {
  const t = useT();
  if (folders.length === 0) return null;
  return (
    <div className="acpmux-extra-folders" data-extra-folders={folders.length}>
      <div className="acpmux-extra-folders-heading">{t("composer.extraFolders")}</div>
      <ul className="acpmux-extra-folders-list">
        {folders.map((folder) => {
          const name = extraFolderName(folder);
          return (
            // tooltip-allow: the row shows the folder's name; the tooltip is its full path
            <li key={folder} className="acpmux-extra-folder" title={folder}>
              <FolderGlyph />
              <span className="acpmux-extra-folder-name">{name}</span>
              <button
                type="button"
                className="acpmux-extra-folder-remove ui-ghost ui-ghost-sm"
                aria-label={t("composer.removeFolder", { name })}
                // The search field keeps the keyboard; its blur would close the menu first.
                onMouseDown={(event) => event.preventDefault()}
                onClick={() => onRemove(folder)}
              >
                <RemoveGlyph />
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

function FolderGlyph() {
  return (
    <svg
      className="acpmux-icon acpmux-extra-folder-icon"
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      aria-hidden="true"
      focusable="false"
    >
      <path d="M2 4.5A1.5 1.5 0 0 1 3.5 3h2.6l1.4 1.5h5A1.5 1.5 0 0 1 14 6v5.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 11.5z" />
    </svg>
  );
}

function RemoveGlyph() {
  return (
    <svg
      className="acpmux-icon"
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="m4 4 8 8M12 4l-8 8" />
    </svg>
  );
}
