// Sidebar section "Memory": the current project's memory files and this
// machine's user memory, one native row each. Tap opens the pane at the file.

import { openPane } from "../actions.ts"
import { t } from "../l10n.ts"
import { allFiles, loaded, roots, rootsError, select } from "../store.ts"
import { displayPath, errorState, fileSubtitle, fileSymbol } from "./parts.ts"

const MAX_ROWS = 8

export function memorySection() {
  return VStack({ spacing: 0 }, [
    () => {
      if (!loaded()) return Text(t("loading", "Looking for agent memory…")).font("caption").secondary().padding(8)
      const err = rootsError()
      if (err) return errorState(err, t("error.roots", "Cannot find agent memory"))
      // This machine only: the first machine's roots (the owner lists the current machine first).
      const machine = roots()[0]?.machine
      const list = allFiles().filter((f) => roots().find((r) => r.root === f.root)?.machine === machine)
      if (!list.length) return EmptyState({ title: t("empty.title", "No agent memory files"), symbol: "brain" })
      return VStack({ spacing: 0 }, [
        ...list.slice(0, MAX_ROWS).map((f) =>
          Row({ title: displayPath(f), subtitle: fileSubtitle(f), symbol: fileSymbol(f.c.kind) }).onTap(() => {
            void select(f.root, f.path)
            void openPane()
          })
        ),
        list.length > MAX_ROWS ? Text(t("section.more", "{n} more", { n: list.length - MAX_ROWS })).font("caption").secondary().padding({ top: 4, leading: 10, bottom: 4, trailing: 10 }).onTap(() => void openPane()) : null
      ])
    }
  ])
}
