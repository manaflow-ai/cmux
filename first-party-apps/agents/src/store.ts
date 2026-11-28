// App-wide state shared by the section and every pane in this VM: machines,
// the CLIs on each, and host-run jobs. No polling: the agent_cli.watch stream
// pushes changes; Refresh asks the owner to check latest versions again.

import { applyWatch, type CliEntry, type Machine, type WatchEvent, withMissing } from "./model/entries.ts"
import { type Job, type JobEvent, jobKey, reduceJob } from "./model/jobs.ts"
import { call, type OpError } from "./ops.ts"

export type MachineState = { entries: CliEntry[]; error: OpError | null; loading: boolean }

const [machines, setMachines] = signal<Machine[]>([])
const [byMachine, setByMachine] = signal<Record<string, MachineState>>({})
const [machinesError, setMachinesError] = signal<OpError | null>(null)
const [jobs, setJobs] = signal<Record<string, Job>>({})
const [loaded, setLoaded] = signal(false)
const [selected, setSelected] = signal<{ machine: string; cli: string } | null>(null)

export { machines, byMachine, machinesError, jobs, loaded, selected, setSelected }

/** When the host has no machine.list, the app still works on the current machine. */
export const LOCAL: Machine = { id: "", name: "", origin: "local", status: "running" }

export const stateOf = (machine: string): MachineState => byMachine()[machine] ?? { entries: [], error: null, loading: true }
export const jobOf = (machine: string, cli: string): Job | null => jobs()[jobKey(machine, cli)] ?? null
export const machineById = (id: string) => machines().find((m) => m.id === id) ?? null
export const localMachine = () => machines().find((m) => m.origin === "local") ?? machines()[0] ?? LOCAL

let started = false

export function start(): void {
  if (started) return
  started = true
  void load(false)
  cmux.events.on("agent_cli.watch", (p) => onWatch(p as WatchEvent & { job?: { job: string; ok: boolean; exit_code?: number | null; error?: string | null } }))
}

export async function load(checkLatest: boolean): Promise<void> {
  const m = await call<Machine[]>("machine.list")
  if (m.ok) {
    // Only machines that can run CLIs: running or connectable ones.
    setMachines(m.value.filter((x) => x.status !== "stopped"))
    setMachinesError(null)
  } else {
    setMachines([LOCAL])
    setMachinesError(m.error.missing ? null : m.error)
  }
  await Promise.all(machines().map((x) => loadMachine(x.id, checkLatest)))
  setLoaded(true)
}

export async function loadMachine(machine: string, checkLatest: boolean): Promise<void> {
  setByMachine((all) => ({ ...all, [machine]: { ...(all[machine] ?? { entries: [], error: null }), loading: true } }))
  const params: Record<string, unknown> = machine ? { machine } : {}
  if (checkLatest) params.check_latest = true
  const r = await call<{ machine?: string; clis: CliEntry[] }>("agent_cli.list", params)
  // The owner echoes the machine it answered for; file the answer under it
  // (answers can arrive in any order). The no-machine.list fallback keeps "".
  const key = machine && r.ok && typeof r.value.machine === "string" && machines().some((m) => m.id === r.value.machine) ? r.value.machine : machine
  setByMachine((all) => ({
    ...all,
    [key]: r.ok ? { entries: withMissing(r.value.clis ?? []), error: null, loading: false } : { entries: all[key]?.entries ?? [], error: r.error, loading: false }
  }))
  if (r.ok) for (const e of r.value.clis ?? []) dispatchJob(key, e.cli, { type: "clear" })
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
  if (!ev || typeof ev.cli !== "string") return
  const machine = typeof ev.machine === "string" ? ev.machine : ""
  if (ev.job) dispatchJob(machine, ev.cli, { type: "finished", job: ev.job.job, ok: ev.job.ok, exitCode: ev.job.exit_code, error: ev.job.error })
  if (ev.entry || ev.removed) {
    setByMachine((all) => {
      const cur = all[machine] ?? { entries: [], error: null, loading: false }
      return { ...all, [machine]: { ...cur, entries: applyWatch(cur.entries, ev) } }
    })
  }
}
