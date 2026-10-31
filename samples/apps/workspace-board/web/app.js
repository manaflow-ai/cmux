// Workspace Board: a custom pane (plans/cmux-next/custom-panes-DESIGN.md).
// `cmux.call(op, params)` is the page's only way out; the app supervisor decides
// every call under the app's grant and answers `{value}` or rejects with `error.code`.

const board = document.getElementById("board")
const status = document.getElementById("status")

function say(text, isError = false) {
  status.textContent = text
  status.classList.toggle("error", isError)
}

function el(tag, className, text) {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (text !== undefined) node.textContent = text
  return node
}

async function send(workspace, terminal, input) {
  const text = input.value
  if (!text) return
  try {
    await cmux.call("terminal.input.write", { workspace, terminal, text: text + "\n" })
    input.value = ""
    say(`Sent to ${terminal}.`)
  } catch (error) {
    if (error.code === "scope.missing") {
      say("Allow “Send the line you type to a terminal” for Workspace Board in the App Store → Installed.", true)
    } else {
      say(`${error.code}: ${error.message}`, true)
    }
  }
}

function terminalRow(workspace, terminal, forms, inputs) {
  const row = el("div", "terminal")
  row.append(el("div", "title", terminal.title || terminal.id))
  if (terminal.cwd) row.append(el("div", "cwd", terminal.cwd))
  const key = JSON.stringify([workspace, terminal.id])
  // Keep the form itself: an in-flight send must still own the visible input after Refresh.
  const form = forms.get(key) ?? el("form")
  let input = form.querySelectorAll("input")[0]
  if (!input) {
    input = el("input")
    input.dataset.draftKey = key
    form.dataset.draftKey = key
    form.append(input, el("button", null, "Send"))
    form.addEventListener("submit", (event) => {
      event.preventDefault()
      send(workspace, terminal.id, input)
    })
  }
  inputs.set(key, input)
  input.placeholder = "Send a line"
  input.setAttribute("aria-label", `Send a line to ${terminal.title || terminal.id}`)
  row.append(form)
  return row
}

async function load() {
  try {
    const workspaces = (await cmux.call("workspace.list", {})).value ?? []
    const rows = await Promise.all(
      workspaces.map(async (workspace) => {
        const terminals = (await cmux.call("terminal.list", { workspace: workspace.id })).value ?? []
        return { workspace, terminals }
      }),
    )
    // Reuse current forms after reads settle, including edits and sends made while refreshing.
    const forms = new Map([...board.querySelectorAll("form")].map((form) => [form.dataset.draftKey, form]))
    const active = document.activeElement
    const activeKey = active?.dataset.draftKey
    const selection = activeKey ? [active.selectionStart, active.selectionEnd, active.selectionDirection] : null
    const inputs = new Map()
    const cards = rows.map(({ workspace, terminals }) => {
      const card = el("section", workspace.focused ? "card focused" : "card")
      card.append(el("h2", null, workspace.name || workspace.id))
      if (terminals.length === 0) card.append(el("div", "empty", "No terminals"))
      for (const terminal of terminals) card.append(terminalRow(workspace.id, terminal, forms, inputs))
      return card
    })
    board.replaceChildren(...cards)
    const replacement = activeKey ? inputs.get(activeKey) : null
    if (replacement && selection) {
      replacement.focus({ preventScroll: true })
      replacement.setSelectionRange(...selection)
    }
    say(`${workspaces.length} workspaces`)
  } catch (error) {
    say(`${error.code ?? "error"}: ${error.message}`, true)
    console.error("load failed", error)
  }
}

document.getElementById("refresh").addEventListener("click", load)
load()
