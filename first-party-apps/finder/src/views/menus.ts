// Context menu of a row and the inline rename / new folder state.

import { copySelection, openEntry, sendToAgent, sendToTerminal, trash } from "../actions.ts"
import type { Browser } from "../browser.ts"
import { t } from "../l10n.ts"
import { locationKey } from "../model/handles.ts"
import { gesture } from "../runtime.ts"

/** The row being renamed (location key + name) or the folder getting a new subfolder (name ""). */
const [editing, setEditing] = signal<{ key: string; name: string } | null>(null)
export { editing }

export const isEditing = (b: Browser, name: string) => {
  const e = editing()
  const l = b.location()
  return !!e && !!l && e.key === locationKey(l) && e.name === name
}

export function startEdit(b: Browser, name: string) {
  const l = b.location()
  if (l) setEditing({ key: locationKey(l), name })
}

export const stopEdit = () => setEditing(null)

export function entryMenu(b: Browser, name: string): CmuxView[] {
  const ensure = () => {
    if (!b.selection().includes(name)) b.select(name)
  }
  const writable = b.root()?.rights === "read_write"
  return [
    Button(t("menu.open", "Open"), () => {
      const g = gesture()
      ensure()
      void openEntry(b, name, g)
    }),
    Divider(),
    Button(t("menu.copy", "Copy"), () => {
      ensure()
      copySelection(b, "copy")
    }),
    Button(t("menu.cut", "Cut"), () => {
      ensure()
      copySelection(b, "move")
    }).disabled(!writable),
    Button(t("menu.rename", "Rename"), () => startEdit(b, name)).disabled(!writable),
    Divider(),
    Button(t("menu.insertPath", "Insert Path in Terminal"), () => {
      const g = gesture()
      ensure()
      void sendToTerminal(b, g)
    }),
    Button(t("menu.attachAgent", "Attach to Agent"), () => {
      const g = gesture()
      ensure()
      void sendToAgent(b, g)
    }),
    Divider(),
    Button(t("menu.trash", "Move to Trash"), () => {
      const g = gesture()
      ensure()
      void trash(b, g)
    })
      .destructive()
      .disabled(!writable)
  ]
}
