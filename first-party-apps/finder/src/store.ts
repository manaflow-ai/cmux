// App-wide state shared by the sidebar section and every browser pane in this
// app VM: connections, roots, recent places, file jobs, and navigation requests.
// No polling: hosts and jobs update from the `host.watch` and `fs.job` streams.

import { type Conn, type JobSnapshot, ops, type OpError, type Root } from "./data/ops.ts"
import { type Location, sameLocation } from "./model/handles.ts"
import { type Job, type JobAction, type JobEvent, type JobPhase, newJob, reduceJob } from "./model/jobs.ts"

export type Recent = Location & { label: string }

const [conns, setConns] = signal<Conn[]>([])
const [roots, setRoots] = signal<Root[]>([])
const [recent, setRecent] = signal<Recent[]>([])
const [jobs, setJobs] = signal<Record<string, Job>>({})
const [sidebarError, setSidebarError] = signal<OpError | null>(null)
const [loaded, setLoaded] = signal(false)
const [request, setRequest] = signal<{ location: Location; seq: number } | null>(null)
const [notice, setNotice] = signal<string | null>(null)

export { conns, roots, recent, jobs, sidebarError, loaded, request, notice }

export const connById = (id: string) => conns().find((c) => c.conn === id) ?? null
export const rootById = (id: string) => roots().find((r) => r.root === id) ?? null

let started = false
let seq = 0

/** Loads hosts, roots, recents and jobs once per VM, then follows the streams. */
export function start(): void {
  if (started) return
  started = true
  void refreshSidebar()
  cmux.events.on("host.watch", (p) => {
    const c = (p as { conn?: Conn } | null)?.conn
    if (c && typeof c.conn === "string") upsertConn(c)
  })
  cmux.events.on("fs.roots.watch", () => void refreshRoots())
  cmux.events.on("fs.job", (p) => {
    const m = p as { job?: string; event?: JobEvent } | null
    if (m?.job && m.event) dispatchJob(m.job, { type: "event", event: m.event, at: Date.now() })
  })
}

export async function refreshSidebar(): Promise<void> {
  const [h, r, j] = await Promise.all([ops.hosts(), ops.roots(), ops.jobs()])
  if (h.ok) setConns(h.value.conns ?? [])
  if (r.ok) setRoots(r.value.roots ?? [])
  if (j.ok) setJobs(Object.fromEntries((j.value.jobs ?? []).map((s) => [s.job, fromSnapshot(s)])))
  setSidebarError(!h.ok ? h.error : !r.ok ? r.error : null)
  try {
    const stored = await cmux.storage.get<Recent[]>("recent")
    if (Array.isArray(stored)) setRecent(stored.slice(0, 8))
  } catch {
    // storage is optional for this app
  }
  setLoaded(true)
}

async function refreshRoots() {
  const r = await ops.roots()
  if (r.ok) setRoots(r.value.roots ?? [])
}

export function upsertConn(c: Conn): void {
  setConns((list) => (list.some((x) => x.conn === c.conn) ? list.map((x) => (x.conn === c.conn ? c : x)) : [...list, c]))
}

export function addRoot(r: Root): void {
  setRoots((list) => (list.some((x) => x.root === r.root) ? list : [...list, r]))
}

/** Ask every browser pane in this VM to show `location` (the sidebar's rows use this). */
export function navigate(location: Location): void {
  setRequest({ location, seq: ++seq })
}

export function remember(location: Location, label: string): void {
  const next = [{ ...location, label }, ...recent().filter((r) => !sameLocation(r, location))].slice(0, 8)
  setRecent(next)
  void cmux.storage.set("recent", next).catch(() => undefined)
}

export function flash(message: string | null): void {
  setNotice(message)
}

function fromSnapshot(s: JobSnapshot): Job {
  const j = newJob({ id: s.job, op: s.op, subject: s.subject, destination: s.destination, crossHost: s.cross_host, at: s.started_at })
  return {
    ...j,
    phase: s.phase as JobPhase,
    seq: s.seq,
    bytes: { done: s.bytes_done, total: s.bytes_total },
    items: { done: s.items_done, total: s.items_total },
    current: s.current,
    eta: s.eta_s ?? null,
    conflict: s.conflict,
    undo: s.undo
  }
}

export function trackJob(job: Job): void {
  setJobs((all) => (all[job.id] ? all : { ...all, [job.id]: job }))
}

export function dispatchJob(id: string, action: JobAction): void {
  setJobs((all) => (all[id] ? { ...all, [id]: reduceJob(all[id]!, action) } : all))
}

export function dismissJob(id: string): void {
  setJobs((all) => {
    const { [id]: _gone, ...rest } = all
    return rest
  })
}

export const jobList = () => Object.values(jobs()).sort((a, b) => a.startedAt - b.startedAt)
