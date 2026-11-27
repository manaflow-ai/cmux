// Terminals that run a command now, for "Keep awake while a command runs".
// Read on mount and when the user asks (Refresh); there is no stream for a
// terminal's foreground process yet (README gap 6), so the list can be old.

import { busyLabel } from "./busy.ts"

export type BusyTerminal = { terminal: string; label: string }
export type TerminalsState = "idle" | "loading" | "ready" | "denied" | "unavailable"

const [busy, setBusy] = signal<BusyTerminal[]>([])
const [terminalsState, setTerminalsState] = signal<TerminalsState>("idle")
export { busy, terminalsState }

let inFlight: Promise<void> | null = null

export function loadTerminals(): Promise<void> {
  if (inFlight) return inFlight
  setTerminalsState("loading")
  inFlight = read().finally(() => {
    inFlight = null
  })
  return inFlight
}

async function read(): Promise<void> {
  let list: Array<{ id: string; title: string; running: boolean }>
  try {
    list = (await cmux.call("terminal.list", {})) as typeof list
  } catch (err) {
    const code = (err as { code?: string })?.code
    setBusy([])
    setTerminalsState(code === "scope.missing" ? "denied" : "unavailable")
    return
  }
  const live = (Array.isArray(list) ? list : []).filter((x) => x && typeof x.id === "string" && x.running !== false)
  const rows = await Promise.all(
    live.map(async (term) => {
      try {
        const p = (await cmux.call("terminal.process.get", { terminal: term.id })) as { foreground_executable?: string | null }
        const label = busyLabel(p?.foreground_executable, String(term.title ?? ""))
        return label ? { terminal: term.id, label } : null
      } catch {
        return null
      }
    })
  )
  setBusy(rows.filter((r): r is BusyTerminal => r !== null))
  setTerminalsState("ready")
}

/** Once per VM: the first surface that shows terminals reads them. */
let loadedOnce = false
export function ensureTerminals(): void {
  if (loadedOnce) return
  loadedOnce = true
  void loadTerminals()
}
