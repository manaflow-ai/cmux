// Browser toolbar (trailing side of the path bar) and the inline New Folder row.

import { clip, newFolder, paste, trash } from "../actions.ts"
import type { Browser } from "../browser.ts"
import { t } from "../l10n.ts"
import { isEditing, startEdit, stopEdit } from "./menus.ts"
import { gesture } from "../runtime.ts"

const iconButton = (symbol: string | (() => string), help: string, run: () => unknown) => Button(Icon(symbol).size(12), run).help(help)

export function toolbar(b: Browser, opts: { filter?: boolean } = {}): CmuxView[] {
  const writable = () => b.root()?.rights === "read_write"
  return [
    opts.filter === false
      ? null
      : TextField(() => b.state().filter.query, { placeholder: t("toolbar.filter", "Filter"), onEdit: (q) => b.setQuery(q), onCancel: () => b.setQuery("") }).frame({ width: 130 }),
    iconButton("folder.badge.plus", t("toolbar.newFolder", "New Folder"), () => startEdit(b, "")).disabled(() => !writable()),
    iconButton("doc.on.clipboard", t("toolbar.paste", "Paste"), () => void paste(b, gesture())).disabled(() => !clip() || !writable()),
    iconButton("trash", t("toolbar.trash", "Move to Trash"), () => void trash(b, gesture())).disabled(() => b.selection().length === 0 || !writable()),
    iconButton(() => (b.state().filter.hidden ? "eye" : "eye.slash"), t("toolbar.hidden", "Show Hidden Files"), () => b.toggleHidden())
  ].filter((v): v is CmuxView => !!v)
}

/** A TextField row at the top of the list while a new folder is being named. */
export function newFolderRow(b: Browser) {
  const shown = computed(() => isEditing(b, ""))
  return () =>
    shown()
      ? HStack({ spacing: 8 }, [
          Icon("folder.badge.plus").color("accent").frame({ width: 16 }),
          TextField("", {
            placeholder: t("toolbar.newFolderName", "Folder name"),
            autofocus: true,
            onSubmit: (name) => {
              const g = gesture()
              stopEdit()
              void newFolder(b, name, g)
            },
            onCancel: stopEdit
          }).frame({ maxWidth: "infinity" })
        ]).padding({ top: 3, leading: 10, bottom: 3, trailing: 10 })
      : null
}
