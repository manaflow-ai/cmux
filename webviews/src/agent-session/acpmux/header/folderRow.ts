// The chat menu's Folder ▸ row: the chat folder's Open in Editor, Open In ▸, Reveal in Finder, Open
// Terminal Here and Copy Path (folderActions.ts), then Edit CLAUDE.md and Add Files to Project
// (instructionsRow.ts), the two rows it took the place of. The ··· menu is full height (design/menus.md):
// one row where there were two, so the menu does not grow and Archive stays in view.
import { type Translate, translate } from "../i18n";
import { folderMenuChildren, type FolderAction } from "../folderActions";
import type { ChatMenuChild, ChatMenuItem } from "./chatHeaderToolsModel";

type Row = Exclude<ChatMenuItem, "separator">;

/// A top-level row as a submenu row.
const asChild = (row: Row): ChatMenuChild => ({
  key: row.key,
  label: row.label,
  disabled: row.disabled,
  shortcutAction: row.shortcutAction,
  onSelect: () => row.onSelect?.(),
});

/// Folder ▸ with `actions` (none for a chat whose folder is not on this Mac), then the `project`
/// rows under a line; undefined when there is neither.
export function folderRow(
  actions: readonly FolderAction[] | undefined,
  project: readonly (Row | undefined)[],
  t: Translate = translate,
): Row | undefined {
  const own = actions ? folderMenuChildren(actions) : [];
  const rest = project.filter((row): row is Row => row !== undefined).map(asChild);
  if (own.length + rest.length === 0) return undefined;
  const children = [
    ...own,
    ...rest.map((row, index) => (index === 0 && own.length ? { ...row, separatorBefore: true } : row)),
  ];
  return { key: "folder", label: t("folderMenu.folder"), icon: "folder", children };
}
