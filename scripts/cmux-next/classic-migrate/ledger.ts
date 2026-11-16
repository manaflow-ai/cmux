import { appendFileSync, existsSync, readFileSync } from "node:fs"

// The ledger: append-only JSONL, one line per step event. It is the only record of what apply made in NEXT,
// so rollback reads nothing else. A line is written with one append before the next request goes out; a kill
// can at worst leave a torn last line, which the reader drops (that step then reads as in flight or not
// started, and both re-send the same idempotent request).

// One step per classic VM: the platform route makes the VM API import, the snapshot row and the machine.
// `vm_api_import` is the earlier CLI's first step (it called the VM API itself, then the platform with the snapshot
// id). New runs never write it; ledgers written by that CLI are still read, shown and rolled back. Any other step
// name is kept out of the state (listed in `ignored`) so an unknown line never breaks status or rollback.
export type Step = "platform_import" | "vm_api_import"
export const STEPS: readonly Step[] = ["platform_import"]
const KNOWN_STEPS: readonly string[] = ["platform_import", "vm_api_import"]

export type LedgerEvent = "started" | "done" | "failed" | "rollback_started" | "rolled_back" | "rollback_failed"

export interface LedgerLine {
  at: string
  migration_id: string
  classic_vm_id: string
  step: Step
  event: LedgerEvent
  request?: unknown
  result?: unknown
  error?: string
  http_status?: number
  note?: string
}

export type StepStatus =
  | "pending"
  | "in_flight"
  | "failed"
  | "done"
  | "rolling_back"
  | "rollback_failed"
  | "rolled_back"

export interface StepState {
  status: StepStatus
  request?: unknown
  result?: unknown
  error?: string
  http_status?: number
}

export interface VmState {
  classic_vm_id: string
  /** Index of the VM's first ledger line: rollback undoes VMs in reverse of this order. */
  first: number
  steps: { platform_import: StepState; vm_api_import?: StepState }
  /** Step names in the ledger this CLI does not know; their lines are not applied. */
  ignored?: string[]
}

export class Ledger {
  constructor(
    readonly path: string,
    private readonly now: () => string = () => new Date().toISOString(),
  ) {}

  read(): LedgerLine[] {
    if (!existsSync(this.path)) return []
    const lines = readFileSync(this.path, "utf8").split("\n")
    const out: LedgerLine[] = []
    lines.forEach((line, i) => {
      if (line.trim() === "") return
      try {
        out.push(JSON.parse(line) as LedgerLine)
      } catch (e) {
        // Only the last line can be torn (a kill mid-append); anything else is a damaged ledger.
        if (i < lines.length - 1 && lines.slice(i + 1).some((l) => l.trim() !== ""))
          throw new Error(`${this.path}:${i + 1}: unreadable ledger line: ${String(e)}`)
      }
    })
    return out
  }

  append(line: Omit<LedgerLine, "at">) {
    const full: LedgerLine = { at: this.now(), ...line }
    // A torn tail from a killed run would glue onto this line; start on a fresh line instead.
    const tail = existsSync(this.path) ? readFileSync(this.path, "utf8") : ""
    const prefix = tail !== "" && !tail.endsWith("\n") ? "\n" : ""
    appendFileSync(this.path, `${prefix}${JSON.stringify(full)}\n`)
  }

  /** Checks the ledger belongs to `migrationId` (one ledger per migration; its attempts are `<id>.rN`). */
  assertMigration(migrationId: string) {
    const other = this.read().find((l) => baseMigrationId(l.migration_id) !== migrationId)
    if (other)
      throw new Error(`${this.path} belongs to migration ${other.migration_id}, not ${migrationId}; use another ledger`)
  }

  /** Every attempt id in the ledger, oldest first. */
  attempts(): string[] {
    return [...new Set(this.read().map((l) => l.migration_id))]
  }

  /** Per classic VM, what the ledger shows of one attempt (default: the current one, the last line's). */
  state(attempt = this.migrationId()): Map<string, VmState> {
    const vms = new Map<string, VmState>()
    this.read().forEach((l, i) => {
      if (l === null || typeof l !== "object" || l.migration_id !== attempt || typeof l.classic_vm_id !== "string") return
      let vm = vms.get(l.classic_vm_id)
      if (!vm) {
        vm = {
          classic_vm_id: l.classic_vm_id,
          first: i,
          steps: { platform_import: { status: "pending" } },
        }
        vms.set(l.classic_vm_id, vm)
      }
      if (!KNOWN_STEPS.includes(l.step)) {
        const name = String(l.step)
        vm.ignored ??= []
        if (!vm.ignored.includes(name)) vm.ignored.push(name)
        return
      }
      const s = l.step === "vm_api_import" ? (vm.steps.vm_api_import ??= { status: "pending" }) : vm.steps.platform_import
      switch (l.event) {
        case "started":
          s.status = "in_flight"
          s.request = l.request
          delete s.error
          delete s.http_status
          break
        case "done":
          s.status = "done"
          s.result = l.result
          break
        case "failed":
          s.status = "failed"
          if (l.error !== undefined) s.error = l.error
          if (l.http_status !== undefined) s.http_status = l.http_status
          break
        case "rollback_started":
          s.status = "rolling_back"
          break
        case "rollback_failed":
          s.status = "rollback_failed"
          if (l.error !== undefined) s.error = l.error
          break
        case "rolled_back":
          s.status = "rolled_back"
          break
      }
    })
    return vms
  }

  /** The current attempt: the migration id the last line was written under. */
  migrationId(): string | undefined {
    return this.read().at(-1)?.migration_id
  }
}

// Re-migration after a rollback (`apply --fresh`) is a new attempt inside the same ledger: the plan's migration id
// with `.rN` (N >= 2), so the platform sees a new provenance and none of the rolled-back rows or idempotency keys.
const ATTEMPT = /^(.*)\.r([0-9]+)$/

export const baseMigrationId = (id: string) => ATTEMPT.exec(id)?.[1] ?? id
export const attemptNumber = (id: string) => Number(ATTEMPT.exec(id)?.[2] ?? 1)
export const attemptId = (base: string, n: number) => (n <= 1 ? base : `${base}.r${n}`)
