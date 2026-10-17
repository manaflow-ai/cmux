// App-wide state shared by the section and every pane in this VM: machines,
// the CLIs on each, and host-run jobs. No polling: the agent_cli.watch stream
// pushes changes; Refresh asks the owner to check latest versions again.

import { applyWatch, sanitizeMachine, type CliEntry, type Machine, type WatchEvent, withMissing } from "./model/entries.ts"
import { type Job, type JobEvent, jobKey, reduceJob } from "./model/jobs.ts"
import { call, type OpError } from "./ops.ts"
import { t } from "./l10n.ts"

export type MachineState = { entries: CliEntry[]; complete: boolean; error: OpError | null; loading: boolean }

const [machines, setMachines] = signal<Machine[]>([])
const [byMachine, setByMachine] = signal<Record<string, MachineState>>({})
const [machinesError, setMachinesError] = signal<OpError | null>(null)
const [jobs, setJobs] = signal<Record<string, Job>>({})
const [loaded, setLoaded] = signal(false)
const [selected, setSelected] = signal<{ machine: string; cli: string } | null>(null)

export { machines, byMachine, machinesError, jobs, loaded, selected, setSelected }

/** When the host has no machine.list, the app still works on the current machine. */
export const LOCAL: Machine = { id: "", name: "", origin: "local", status: "running" }

export const stateOf = (machine: string): MachineState => byMachine()[machine] ?? { entries: [], complete: false, error: null, loading: true }
/** An unreported CLI on a partial or unavailable owner is unknown, never an install suggestion. */
export function entryFor(machine: string, cli: string): CliEntry {
  const state = stateOf(machine)
  return state.entries.find((e) => e.cli === cli) ?? {
    cli, installed: state.complete ? false : null, version: null, latest: null,
    install_method: null, updatable: false, accounts: []
  }
}
export const inventoryComplete = () => machines().length > 0 && machines().every((m) => {
  const state = stateOf(m.id)
  return state.complete && !state.loading && !state.error
})
export const jobOf = (machine: string, cli: string): Job | null => jobs()[jobKey(machine, cli)] ?? null
export const machineById = (id: string) => machines().find((m) => m.id === id) ?? null
export const localMachine = () => machines().find((m) => m.origin === "local") ?? LOCAL

let started = false
let discovery = 0
const reads = new Map<string, object>()

export function start(): void {
  if (started) return
  started = true
  void load(false)
  cmux.events.on("agent_cli.watch", (p) => onWatch(p as WatchEvent & { job?: { job: string; ok: boolean; exit_code?: number | null; error?: string | null } }))
}

export async function load(checkLatest: boolean): Promise<void> {
  const generation = ++discovery
  reads.clear()
  const m = await call<Machine[]>("machine.list", { catalog: true })
  if (generation !== discovery) return
  if (m.ok) {
    // Only machines that can run CLIs: running or connectable ones.
    setMachines(m.value.filter((x) => x.status !== "stopped").map(sanitizeMachine))
    setMachinesError(null)
  } else {
    // Only a host without this operation has the legacy anonymous local route.
    // Permission and transport failures cannot establish any machine admission.
    const legacy = m.error.code === "operation.unsupported"
    setMachines(legacy ? [LOCAL] : [])
    setMachinesError(legacy ? null : m.error)
  }
  const admitted = new Set(machines().map((x) => x.id))
  setByMachine((all) => Object.fromEntries(Object.entries(all).filter(([id]) => admitted.has(id))))
  setJobs((all) => Object.fromEntries(Object.entries(all).filter(([key]) => admitted.has(key.split("/")[0]!))))
  if (selected() && !admitted.has(selected()!.machine)) setSelected(null)
  await Promise.all(machines().map((x) => loadMachine(x.id, checkLatest)))
  if (generation === discovery) setLoaded(true)
}

export async function loadMachine(machine: string, checkLatest: boolean): Promise<void> {
  const owner = machineById(machine)
  if (!owner) return
  const generation = discovery
  const token = {}
  reads.set(machine, token)
  setByMachine((all) => ({ ...all, [machine]: { ...(all[machine] ?? { entries: [], error: null }), complete: false, loading: true } }))
  const params: Record<string, unknown> = machine ? { machine } : {}
  if (checkLatest) params.check_latest = true
  const r = await call<{ machine?: string; clis: CliEntry[]; complete?: boolean }>("agent_cli.list", params)
  // A refresh, route removal or newer observation retires this particular read.
  if (generation !== discovery || owner !== machineById(machine) || reads.get(machine) !== token) return
  reads.delete(machine)
  // Never redirect an answer to another known machine. Legacy anonymous reads
  // have no selected public ID; an explicit selection requires an exact echo.
  const mismatch = r.ok && !!machine && r.value?.machine !== machine
  const error: OpError | null = mismatch ? {
    code: "machine.owner_mismatch", op: "agent_cli.list", missing: false,
    message: t("error.owner", "The inventory reply did not match the selected machine.")
  } : r.ok ? null : r.error
  setByMachine((all) => ({
    ...all,
    [machine]: r.ok && !error ? { entries: withMissing(r.value.clis ?? [], r.value.complete === true), complete: r.value.complete === true, error: null, loading: false }
      : { entries: [], complete: false, error, loading: false }
  }))
  if (r.ok && !error) for (const e of r.value.clis ?? []) dispatchJob(machine, e.cli, { type: "clear" })
}

export function dispatchJob(machine: string, cli: string, ev: JobEvent): void {
  const key = jobKey(machine, cli)
  setJobs((all) => {
    const next = reduceJob(all[key] ?? null, ev)
    if (next === (all[key] ?? null)) return all
    const copy = { ...all }
    if (next) copy[key] = next
    else delete copy[key]
    return copy
  })
}

function onWatch(ev: (WatchEvent & { job?: { job: string; ok: boolean; exit_code?: number | null; error?: string | null } }) | null): void {
  if (!ev || typeof ev.cli !== "string" || typeof ev.machine !== "string" || !machineById(ev.machine)) return
  if (ev.entry && ev.entry.cli !== ev.cli) return
  const machine = ev.machine
  if (ev.job) dispatchJob(machine, ev.cli, { type: "finished", job: ev.job.job, ok: ev.job.ok, exitCode: ev.job.exit_code, error: ev.job.error })
  if (ev.entry || ev.removed === true) {
    reads.delete(machine)
    setByMachine((all) => {
      const cur = all[machine] ?? { entries: [], complete: false, error: null, loading: false }
      return { ...all, [machine]: { ...cur, entries: applyWatch(cur.entries, ev, cur.complete), error: null, loading: false } }
    })
  }
}
