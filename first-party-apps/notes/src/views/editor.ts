/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// "editor": rows only; a click opens the note in the native editor pane next
// to the terminal, where the text is edited. The section stays a list.

import { listHeader, notesList } from "./list.ts"
import { openInEditor } from "./common.ts"
import type { ViewState } from "./state.ts"

export function renderEditorList(vs: ViewState) {
  return VStack({ spacing: 6 }, [
    listHeader(vs),
    notesList(vs, {
      inlineDetail: false,
      showWorkspace: true,
      onTap: (n) => {
        vs.select(n.id)
        return openInEditor(n)
      }
    })
  ])
}
