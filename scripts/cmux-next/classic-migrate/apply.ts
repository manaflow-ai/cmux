import {
  CLASSIC_REF,
  HttpError,
  type LegacyVmApi,
  type PlatformImportRequest,
  type PlatformImports,
} from "./clients.ts"
import { attemptId, attemptNumber, baseMigrationId, Ledger, type StepState, type VmState } from "./ledger.ts"
import { copiesOf, type Plan } from "./plan.ts"

// apply, rollback, status and verify. Per classic VM there is one step: cmux-platform's internal route imports the
// classic VM's provider VM through the VM API (under the team's own tenant), records a ready snapshot row in the
// team's CloudDO and creates a machine from it. The step writes `started` (with its exact request) before the
// request and `done`/`failed` after. A re-run skips `done` and re-sends the recorded request of a step that never
// finished, so a kill costs at most one repeated (idempotent) request. Classic is never called.

export interface Deps {
  platform: PlatformImports
  /** Only for ledgers of the earlier CLI: deletes the VM API imports it made itself (`vm_api_import`). */
  legacyVmApi?: LegacyVmApi
  log?: (line: string) => void
}

export interface ApplyOptions {
  only?: string
  dryRun?: boolean
  /** Start a new attempt (`<migration id>.rN`) after the current one was rolled back. */
  fresh?: boolean
}

export interface ApplyReport {
  migration_id: string
  done: string[]
  skipped: { classic_vm_id: string; why: string }[]
  failed: { classic_vm_id: string; error: string }[]
  /** Requests sent (a re-run of a finished apply sends none). */
  sent: number
  /** --dry-run: what each VM would get. */
  would: { classic_vm_id: string; action: "skip (done)" | "re-send (in flight)" | "send" }[]
}

const blankVm = (id: string): VmState => ({
  classic_vm_id: id,
  first: Number.MAX_SAFE_INTEGER,
  steps: { platform_import: { status: "pending" } },
})

const ROLLED = ["rolling_back", "rollback_failed", "rolled_back"]
const rolledBack = (vm: VmState) =>
  ROLLED.includes(vm.steps.platform_import.status) || ROLLED.includes(vm.steps.vm_api_import?.status ?? "pending")
/** Something this attempt sent may exist in NEXT. */
const touched = (s: StepState | undefined) =>
  s !== undefined && s.status !== "pending" && s.status !== "rolled_back" && s.request !== undefined
/** Any step of the VM that may have left something in NEXT. */
const vmTouched = (vm: VmState) => touched(vm.steps.platform_import) || touched(vm.steps.vm_api_import)
/**
 * Written by the earlier two-step CLI: a `vm_api_import` step, or a platform request carrying its snapshot id. Such a
 * VM is shown and rolled back, but never re-sent: the recorded request is the old route shape.
 */
const legacy = (vm: VmState) =>
  vm.steps.vm_api_import !== undefined ||
  (vm.steps.platform_import.request as { vm_api_snapshot_id?: unknown } | undefined)?.vm_api_snapshot_id !== undefined
/** The machine id of a platform result: a string now, `{id}` in the earlier CLI's ledgers. */
const machineOf = (result: unknown): string | null => {
  const m = (result as { machine?: unknown } | undefined)?.machine
  if (typeof m === "string") return m
  return m !== null && typeof m === "object" && typeof (m as { id?: unknown }).id === "string" ? (m as { id: string }).id : null
}

const errText = (e: unknown) => (e instanceof Error ? e.message : String(e))
const httpStatus = (e: unknown) => (e instanceof HttpError ? { http_status: e.status } : {})

/** The attempt apply writes under: the ledger's current one, or with --fresh the next one. */
export const attemptFor = (plan: Plan, ledger: Ledger, fresh: boolean): string => {
  const current = ledger.migrationId()
  if (!fresh) return current ?? plan.migration_id
  if (current === undefined) return plan.migration_id
  const live = [...ledger.state(current).values()].filter(vmTouched)
  if (live.length > 0)
    throw new Error(
      `--fresh: attempt ${current} still has ${live.length} VM(s) not rolled back (${live.map((v) => v.classic_vm_id).join(", ")}); run rollback first`,
    )
  const next = attemptId(plan.migration_id, attemptNumber(current) + 1)
  if (!CLASSIC_REF.test(next)) throw new Error(`--fresh: attempt id ${next} is not a valid migration id`)
  return next
}

export const apply = async (plan: Plan, ledger: Ledger, deps: Deps, opts: ApplyOptions = {}): Promise<ApplyReport> => {
  const log = deps.log ?? (() => {})
  ledger.assertMigration(plan.migration_id)
  const copies = copiesOf(plan).filter((c) => opts.only === undefined || c.classic_vm_id === opts.only)
  if (opts.only !== undefined && copies.length === 0)
    throw new Error(`--only ${opts.only}: no copy of that classic VM in the plan`)
  const mig = attemptFor(plan, ledger, opts.fresh ?? false)
  const report: ApplyReport = { migration_id: mig, done: [], skipped: [], failed: [], sent: 0, would: [] }
  const states = ledger.state(mig)

  for (const c of copies) {
    const vm = states.get(c.classic_vm_id) ?? blankVm(c.classic_vm_id)
    if (rolledBack(vm)) {
      const why = "rolled back in this attempt; pass --fresh to copy it again as a new attempt"
      report.skipped.push({ classic_vm_id: c.classic_vm_id, why })
      log(`skip ${c.classic_vm_id}: ${why}`)
      continue
    }
    const s = vm.steps.platform_import
    if (legacy(vm) && s.status !== "done") {
      const why = "written by the earlier two-step CLI (vm_api_import) and not finished; run rollback, then apply --fresh"
      report.skipped.push({ classic_vm_id: c.classic_vm_id, why })
      log(`skip ${c.classic_vm_id}: ${why}`)
      continue
    }
    if (opts.dryRun) {
      report.would.push({
        classic_vm_id: c.classic_vm_id,
        action: s.status === "done" ? "skip (done)" : s.status === "in_flight" || s.status === "failed" ? "re-send (in flight)" : "send",
      })
      continue
    }
    if (s.status === "done") {
      log(`skip ${c.classic_vm_id}: done`)
      report.done.push(c.classic_vm_id)
      continue
    }
    if (!CLASSIC_REF.test(c.classic_vm_id) || !CLASSIC_REF.test(mig)) {
      const error = `classic_vm_id ${c.classic_vm_id} or migration_id ${mig} is not 1-63 of [A-Za-z0-9._:/@-]; not sent`
      report.failed.push({ classic_vm_id: c.classic_vm_id, error })
      log(`failed ${c.classic_vm_id}: ${error}`)
      continue
    }
    const req: PlatformImportRequest = (s.request as PlatformImportRequest | undefined) ?? {
      team: c.next_team_id,
      creator_user: c.creator_user_id,
      migration_id: mig,
      classic_vm_id: c.classic_vm_id,
      upstream_vm_id: c.upstream_vm_id,
      ...(c.name.trim() !== "" ? { name: c.name.trim() } : {}),
      size: c.size,
    }
    log(`${s.request ? "re-send" : "send"} ${c.classic_vm_id}`)
    const line = { migration_id: mig, classic_vm_id: c.classic_vm_id, step: "platform_import" as const }
    ledger.append({ ...line, event: "started", request: req })
    report.sent++
    try {
      const res = await deps.platform.importMachine(req)
      ledger.append({ ...line, event: "done", result: res })
      report.done.push(c.classic_vm_id)
      log(`done ${c.classic_vm_id} machine ${res.machine} (${res.status})`)
    } catch (e) {
      ledger.append({ ...line, event: "failed", error: errText(e), ...httpStatus(e) })
      report.failed.push({ classic_vm_id: c.classic_vm_id, error: errText(e) })
      log(`failed ${c.classic_vm_id}: ${errText(e)}`)
    }
  }
  return report
}

export interface RollbackReport {
  rolled_back: { classic_vm_id: string; status: string }[]
  failed: { classic_vm_id: string; error: string }[]
  /** Earlier-CLI VM API imports this run could not delete itself (no VM API client, or the id is unknown). */
  manual_cleanup: { classic_vm_id: string; migration_id: string; vm_api_snapshot_id: string | null; why: string }[]
  /** Requests sent (a second rollback sends none). */
  sent: number
}

/**
 * Undoes, newest VM first, everything the current attempt sent: one DELETE per classic VM, which removes the
 * machine, its CloudDO snapshot row and every VM API import of (migration_id, classic_vm_id), including an import a
 * cut-off run never recorded. The route answers `absent` when nothing is there, so a refused or unanswered import is
 * rolled back the same way. Each undo is recorded, so a second rollback sends nothing.
 */
export const rollback = async (ledger: Ledger, deps: Deps): Promise<RollbackReport> => {
  const log = deps.log ?? (() => {})
  const mig = ledger.migrationId()
  const report: RollbackReport = { rolled_back: [], failed: [], manual_cleanup: [], sent: 0 }
  if (mig === undefined) return report
  const vms = [...ledger.state(mig).values()].sort((a, b) => b.first - a.first)
  for (const vm of vms) {
    const id = vm.classic_vm_id
    const s = vm.steps.platform_import
    if (touched(s)) {
      const req = s.request as PlatformImportRequest
      const line = { migration_id: mig, classic_vm_id: id, step: "platform_import" as const }
      ledger.append({ ...line, event: "rollback_started" })
      report.sent++
      try {
        const status = await deps.platform.deleteMachine({ team: req.team, migration_id: req.migration_id, classic_vm_id: id })
        ledger.append({ ...line, event: "rolled_back", note: status })
        report.rolled_back.push({ classic_vm_id: id, status })
        log(`rolled back ${id} (${status})`)
      } catch (e) {
        ledger.append({ ...line, event: "rollback_failed", error: errText(e) })
        report.failed.push({ classic_vm_id: id, error: errText(e) })
        log(`rollback failed ${id}: ${errText(e)}`)
        // Keep an earlier-CLI VM API snapshot: the machine may still be made from it.
        continue
      }
    }
    await rollbackLegacyImport(ledger, mig, vm, deps, report)
  }
  return report
}

/**
 * The earlier CLI's own VM API import (`vm_api_import`), after its machine is gone: deleted through the VM API
 * client when there is one; otherwise, or when the import never answered with its id, recorded as rollback_failed
 * and listed for manual cleanup with what identifies it. A refused import made nothing.
 */
const rollbackLegacyImport = async (ledger: Ledger, mig: string, vm: VmState, deps: Deps, report: RollbackReport) => {
  const log = deps.log ?? (() => {})
  const v = vm.steps.vm_api_import
  if (!touched(v)) return
  const id = vm.classic_vm_id
  const line = { migration_id: mig, classic_vm_id: id, step: "vm_api_import" as const }
  const snapId = (v!.result as { id?: unknown } | undefined)?.id
  if (typeof snapId !== "string") {
    if (v!.status === "failed" && v!.http_status !== undefined && new HttpError(v!.http_status, "", "").permanent) {
      ledger.append({ ...line, event: "rolled_back", note: `import was refused (HTTP ${v!.http_status}); nothing was created` })
      report.rolled_back.push({ classic_vm_id: id, status: "absent" })
      return
    }
    const why = "the VM API import never answered with its id; find it in the VM API by (migration_id, classic_vm_id) and delete it"
    ledger.append({ ...line, event: "rollback_failed", error: `needs manual cleanup: ${why}` })
    report.manual_cleanup.push({ classic_vm_id: id, migration_id: mig, vm_api_snapshot_id: null, why })
    log(`manual cleanup ${id}: ${why}`)
    return
  }
  if (!deps.legacyVmApi) {
    const why = "no VM API client (set CMUX_VM_API_ORIGIN and CMUX_VM_IMPORT_KEY to delete it here)"
    ledger.append({ ...line, event: "rollback_failed", error: `needs manual cleanup: VM API snapshot ${snapId}: ${why}` })
    report.manual_cleanup.push({ classic_vm_id: id, migration_id: mig, vm_api_snapshot_id: snapId, why })
    log(`manual cleanup ${id}: VM API snapshot ${snapId}: ${why}`)
    return
  }
  ledger.append({ ...line, event: "rollback_started" })
  report.sent++
  try {
    await deps.legacyVmApi.deleteSnapshot(snapId)
    ledger.append({ ...line, event: "rolled_back", note: snapId })
    report.rolled_back.push({ classic_vm_id: id, status: `deleted VM API snapshot ${snapId}` })
    log(`rolled back ${id} VM API snapshot ${snapId}`)
  } catch (e) {
    ledger.append({ ...line, event: "rollback_failed", error: errText(e) })
    report.failed.push({ classic_vm_id: id, error: errText(e) })
    log(`rollback failed ${id} VM API snapshot ${snapId}: ${errText(e)}`)
  }
}

export interface StatusRow {
  classic_vm_id: string
  attempt: string
  platform_import: string
  /** Only for ledgers of the earlier CLI. */
  vm_api_import?: string
  snapshot?: string
  machine?: string
  ignored_steps?: string[]
  overall: "done" | "pending" | "in_flight" | "failed" | "rolled_back" | "rollback_incomplete"
}

/** What the ledger shows per VM in the current attempt; with a plan, VMs it never touched read as pending. */
export const status = (ledger: Ledger, plan?: Plan): StatusRow[] => {
  const attempt = ledger.migrationId() ?? plan?.migration_id ?? ""
  const states = ledger.state(attempt)
  const ids = new Set([...states.keys(), ...(plan ? copiesOf(plan).map((c) => c.classic_vm_id) : [])])
  return [...ids].sort().map((id) => {
    const vm = states.get(id) ?? blankVm(id)
    const s = vm.steps.platform_import
    const v = vm.steps.vm_api_import
    const all = v ? [v.status, s.status] : [s.status]
    const overall: StatusRow["overall"] = all.some((x) => x === "rolling_back" || x === "rollback_failed")
      ? "rollback_incomplete"
      : all.includes("rolled_back")
        ? all.every((x) => x === "rolled_back" || x === "pending")
          ? "rolled_back"
          : "rollback_incomplete"
        : all.every((x) => x === "done")
          ? "done"
          : all.includes("failed")
            ? "failed"
            : all.includes("in_flight")
              ? "in_flight"
              : "pending"
    const machine = machineOf(s.result)
    const snapshot = (v?.result as { id?: unknown } | undefined)?.id
    return {
      classic_vm_id: id,
      attempt,
      platform_import: s.status,
      ...(v ? { vm_api_import: v.status } : {}),
      ...(typeof snapshot === "string" ? { snapshot } : {}),
      ...(machine ? { machine } : {}),
      ...(vm.ignored ? { ignored_steps: vm.ignored } : {}),
      overall,
    }
  })
}

export interface VerifyRow {
  attempt: string
  classic_vm_id: string
  /** present: the ledger shows it done, NEXT must have its machine; absent: rolled back or never made. */
  expect: "present" | "absent"
  found: string | null
  ok: boolean
  note: string
}
export interface VerifyReport {
  ok: boolean
  team: string | null
  rows: VerifyRow[]
}

/** A machine that is not on its way out. `deleting` is a rollback the platform's alarm is still finishing. */
const live = (m: { status: string } | null) => m !== null && m.status !== "deleting"

/**
 * Compares the platform's list with the ledger, attempt by attempt: every VM done in the current attempt has its
 * machine (the one the ledger recorded) live in NEXT; every rolled-back VM, and every VM of an earlier attempt, has
 * none; and NEXT holds no live machine of this migration the ledger does not know.
 */
export const verify = async (ledger: Ledger, deps: Deps): Promise<VerifyReport> => {
  const current = ledger.migrationId()
  if (current === undefined) return { ok: true, team: null, rows: [] }
  const team = [...ledger.read()]
    .map((l) => (l.request as PlatformImportRequest | undefined)?.team)
    .find((t) => typeof t === "string")
  if (team === undefined) return { ok: true, team: null, rows: [] }
  const rows: VerifyRow[] = []
  for (const attempt of ledger.attempts()) {
    if (baseMigrationId(attempt) !== baseMigrationId(current)) continue
    const items = await deps.platform.list(team, attempt)
    const byVm = new Map(items.map((i) => [i.classic_vm_id, i]))
    const states = ledger.state(attempt)
    for (const vm of states.values()) {
      const s = vm.steps.platform_import
      const item = byVm.get(vm.classic_vm_id)
      byVm.delete(vm.classic_vm_id)
      const found = item?.machine && live(item.machine) ? item.machine.id : null
      if (attempt === current && s.status === "done") {
        const want = machineOf(s.result)
        const ok = found !== null && (want === null || found === want)
        rows.push({
          attempt,
          classic_vm_id: vm.classic_vm_id,
          expect: "present",
          found,
          ok,
          note: ok ? "machine live" : found === null ? "no live machine in NEXT" : `NEXT has ${found}, the ledger ${want}`,
        })
      } else if (attempt !== current || s.status === "rolled_back") {
        const deleting = item?.machine?.status === "deleting"
        rows.push({
          attempt,
          classic_vm_id: vm.classic_vm_id,
          expect: "absent",
          found,
          ok: found === null,
          note: found !== null ? "a live machine is still in NEXT" : deleting ? "machine deleting (provider delete running)" : "none",
        })
      }
      // pending, in flight, failed or rollback in progress in the current attempt: apply or rollback still owes it.
    }
    for (const extra of byVm.values())
      if (live(extra.machine))
        rows.push({
          attempt,
          classic_vm_id: extra.classic_vm_id,
          expect: "absent",
          found: extra.machine!.id,
          ok: false,
          note: "NEXT has a machine of this migration the ledger does not know",
        })
  }
  rows.sort(
    (a, b) =>
      attemptNumber(a.attempt) - attemptNumber(b.attempt) ||
      (a.classic_vm_id < b.classic_vm_id ? -1 : a.classic_vm_id > b.classic_vm_id ? 1 : 0),
  )
  return { ok: rows.every((r) => r.ok), team, rows }
}
