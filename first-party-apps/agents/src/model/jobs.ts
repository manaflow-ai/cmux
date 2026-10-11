// A host-run job (update, install, sign-in) for one CLI on one machine.
// The app asks; the owner opens a visible terminal and runs the command with
// origin user; the agent_cli.watch stream reports the job's end. States:
//   idle -> requested (op sent) -> running (terminal open) -> succeeded | failed
//   requested -> refused (op error, e.g. scope.missing) ; failed/refused -> requested (retry)
// A finished job is cleared when the next list for that CLI arrives.

export type JobKind = "update" | "install" | "sign_in"
export type JobPhase = "requested" | "running" | "succeeded" | "failed" | "refused"
export type Job = { kind: JobKind; phase: JobPhase; job: string | null; terminal: string | null; error: string | null; exitCode: number | null }

export type JobEvent =
  | { type: "request"; kind: JobKind }
  | { type: "started"; job: string; terminal: string | null }
  | { type: "refused"; error: string }
  | { type: "finished"; job: string; ok: boolean; exitCode?: number | null; error?: string | null }
  | { type: "clear" }

export const jobKey = (machine: string, cli: string) => `${machine}/${cli}`

export const busy = (j: Job | null | undefined) => !!j && (j.phase === "requested" || j.phase === "running")

export function reduceJob(j: Job | null, ev: JobEvent): Job | null {
  switch (ev.type) {
    case "request":
      // One job per CLI and machine at a time: a second tap while busy is ignored.
      if (busy(j)) return j
      return { kind: ev.kind, phase: "requested", job: null, terminal: null, error: null, exitCode: null }
    case "started":
      if (!j || j.phase !== "requested") return j
      return { ...j, phase: "running", job: ev.job, terminal: ev.terminal }
    case "refused":
      if (!j || j.phase !== "requested") return j
      return { ...j, phase: "refused", error: ev.error }
    case "finished":
      // Only the job this row started; a stale event from an older job is ignored.
      if (!j || j.job !== ev.job || j.phase !== "running") return j
      return { ...j, phase: ev.ok ? "succeeded" : "failed", exitCode: ev.exitCode ?? null, error: ev.error ?? null }
    case "clear":
      return busy(j) ? j : null
  }
}
