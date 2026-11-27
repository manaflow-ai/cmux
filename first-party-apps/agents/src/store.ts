// App-wide state shared by the section and every pane in this VM: machines,
// the CLIs on each, and proposed host-run jobs. Cache invalidations re-read
// admitted owners; they carry no observations or job completion authority.

import { sanitizeMachine, type CliEntry, type Machine, withMissing } from "./model/entries.ts"
import { busy, type Job, type JobEvent, type JobKind, jobKey, reduceJob } from "./model/jobs.ts"
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
let invalidated = false
let invalidationTask: Promise<void> | null = null

export function start(): void {
  if (started) return
  started = true
  cmux.events.on("agent_cli.changed", () => invalidate())
  void load(false)
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
  // A refresh, route removal or invalidation re-read retires this particular read.
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

/** Capture one request before sending an operation, shared by every action surface. */
export function requestJob(machine: string, cli: string, kind: JobKind): Job | null {
  if (!machineById(machine) || busy(jobOf(machine, cli))) return null
  dispatchJob(machine, cli, { type: "request", kind })
  return jobOf(machine, cli)
}

/** Removal or a newer request retires the original request, even after re-admission. */
export function isCurrentJob(machine: string, cli: string, request: Job): boolean {
  return machineById(machine) !== null && jobOf(machine, cli) === request
}

/** Invalidations never supply rows, selectors or job results. */
function invalidate(): void {
  invalidated = true
  if (invalidationTask) return
  invalidationTask = drainInvalidations()
}

/** At most one invalidation batch runs; changes during it retain one follow-up. */
async function drainInvalidations(): Promise<void> {
  try {
    while (invalidated) {
      invalidated = false
      await load(false)
    }
  } finally {
    invalidationTask = null
    // A notification between the loop's last check and promise settlement
    // must not be lost. This is event-driven, with no timers or idle work.
    if (invalidated) invalidate()
  }
}
