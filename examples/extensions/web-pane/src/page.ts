// The pane's script: built only on cmux-extension-sdk/web. `bun run build` bundles it to
// web/page.js; `cmux ext dev` reloads the open pane on every save.
import { CmuxCallError, call, storage } from "cmux-extension-sdk/web"

type Workspace = { id: string; name?: string; title?: string }

const byId = <T extends HTMLElement>(id: string) => document.getElementById(id) as T

async function showWorkspaces() {
  const list = byId<HTMLUListElement>("workspaces")
  try {
    const value = await call<Workspace[] | { workspaces?: Workspace[] }>("workspace.list")
    const workspaces = Array.isArray(value) ? value : (value.workspaces ?? [])
    list.replaceChildren(
      ...workspaces.map((w) => Object.assign(document.createElement("li"), { textContent: w.name ?? w.title ?? w.id })),
    )
    if (workspaces.length === 0) list.replaceChildren(Object.assign(document.createElement("li"), { textContent: "No workspaces", className: "muted" }))
  } catch (error) {
    list.replaceChildren(Object.assign(document.createElement("li"), { textContent: String(error), className: "muted" }))
  }
}

async function keepNote() {
  const note = byId<HTMLTextAreaElement>("note")
  note.value = (await storage.get<string>("note").catch(() => null)) ?? ""
  let pending: ReturnType<typeof setTimeout> | undefined
  note.addEventListener("input", () => {
    clearTimeout(pending)
    pending = setTimeout(() => void storage.set("note", note.value), 300)
  })
}

// The extension did not ask for workspace:write, so cmux refuses this call: the page shows why.
byId<HTMLButtonElement>("rename").addEventListener("click", async () => {
  const out = byId<HTMLParagraphElement>("refusal")
  try {
    await call("workspace.rename", { workspace: "current", name: "Renamed by a web pane" })
    out.textContent = "Renamed (this should not happen)"
  } catch (error) {
    out.textContent = error instanceof CmuxCallError ? `Refused: ${error.code}` : String(error)
  }
})

void showWorkspaces()
void keepNote()
