import { appendFileSync, existsSync, readFileSync } from "node:fs"

// The ledger: append-only JSONL, one line per step event. It is the only record of what apply made in NEXT,
// so rollback reads nothing else. A line is written with one append before the next request goes out; a kill
// can at worst leave a torn last line, which the reader drops (that step then reads as in flight or not
// started, and both re-send the same idempotent request).

export type Step = "vm_api_import" | "platform_import"
export const STEPS: readonly Step[] = ["vm_api_import", "platform_import"]

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
  steps: Record<Step, StepState>
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

  /** Checks the ledger belongs to `migrationId` (one ledger per migration). */
  assertMigration(migrationId: string) {
    const other = this.read().find((l) => l.migration_id !== migrationId)
    if (other)
      throw new Error(`${this.path} belongs to migration ${other.migration_id}, not ${migrationId}; use another ledger`)
  }

  state(): Map<string, VmState> {
    const vms = new Map<string, VmState>()
    this.read().forEach((l, i) => {
      let vm = vms.get(l.classic_vm_id)
      if (!vm) {
        vm = {
          classic_vm_id: l.classic_vm_id,
          first: i,
          steps: { vm_api_import: { status: "pending" }, platform_import: { status: "pending" } },
        }
        vms.set(l.classic_vm_id, vm)
      }
      const s = vm.steps[l.step]
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

  migrationId(): string | undefined {
    return this.read()[0]?.migration_id
  }
}
