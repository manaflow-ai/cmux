import {
  HttpError,
  type PersonalTenantResolver,
  type PlatformImportRequest,
  type PlatformImports,
  type VmApiImportRequest,
  type VmApiImports,
} from "./clients.ts"
import { Ledger, STEPS, type Step, type StepState, type VmState } from "./ledger.ts"
import { copiesOf, type CopySpec, type Plan } from "./plan.ts"

// apply, rollback and status. Per classic VM there are two steps: (1) the VM API registers a snapshot of the
// upstream VM under the NEXT tenant, (2) cmux-platform imports that snapshot into the team's CloudDO and creates
// a machine from it. Each step writes `started` (with its exact request) before the request and `done`/`failed`
// after. A re-run skips `done` steps and re-sends the recorded request of a step that never finished, so a kill
// costs at most one repeated (idempotent) request. Classic is never called.

export interface Deps {
  vmApi: VmApiImports
  platform: PlatformImports
  resolvePersonalTenant: PersonalTenantResolver
  log?: (line: string) => void
}

export interface ApplyOptions {
  only?: string
  dryRun?: boolean
}

export interface ApplyReport {
  done: string[]
  skipped: { classic_vm_id: string; why: string }[]
  failed: { classic_vm_id: string; step: Step; error: string }[]
  /** --dry-run: what each step would do. */
  would: { classic_vm_id: string; step: Step; action: "skip (done)" | "re-send (in flight)" | "send" }[]
}

const blankVm = (id: string): VmState => ({
  classic_vm_id: id,
  first: Number.MAX_SAFE_INTEGER,
  steps: { vm_api_import: { status: "pending" }, platform_import: { status: "pending" } },
})

const rolledBack = (vm: VmState) =>
  STEPS.some((s) => ["rolling_back", "rollback_failed", "rolled_back"].includes(vm.steps[s].status))

const errText = (e: unknown) => (e instanceof Error ? e.message : String(e))
const httpStatus = (e: unknown) => (e instanceof HttpError ? { http_status: e.status } : {})

export const apply = async (plan: Plan, ledger: Ledger, deps: Deps, opts: ApplyOptions = {}): Promise<ApplyReport> => {
  const log = deps.log ?? (() => {})
  ledger.assertMigration(plan.migration_id)
  const copies = copiesOf(plan).filter((c) => opts.only === undefined || c.classic_vm_id === opts.only)
  if (opts.only !== undefined && copies.length === 0)
    throw new Error(`--only ${opts.only}: no copy of that classic VM in the plan`)
  const report: ApplyReport = { done: [], skipped: [], failed: [], would: [] }
  const states = ledger.state()
  const mig = plan.migration_id

  for (const c of copies) {
    const vm = states.get(c.classic_vm_id) ?? blankVm(c.classic_vm_id)
    if (rolledBack(vm)) {
      report.skipped.push({ classic_vm_id: c.classic_vm_id, why: "rolled back in this ledger; not applied again" })
      log(`skip ${c.classic_vm_id}: rolled back in this ledger`)
      continue
    }
    if (opts.dryRun) {
      for (const step of STEPS) {
        const s = vm.steps[step].status
        report.would.push({
          classic_vm_id: c.classic_vm_id,
          step,
          action: s === "done" ? "skip (done)" : s === "in_flight" || s === "failed" ? "re-send (in flight)" : "send",
        })
      }
      continue
    }

    /** Runs one step: skip when done, else send the recorded request (or a new one) and record the outcome. */
    const run = async <Req, Res>(
      step: Step,
      build: () => Promise<Req>,
      send: (req: Req) => Promise<Res>,
    ): Promise<Res | undefined> => {
      const s: StepState = vm.steps[step]
      if (s.status === "done") {
        log(`skip ${c.classic_vm_id} ${step}: done`)
        return s.result as Res
      }
      const req = (s.request as Req | undefined) ?? (await build())
      log(`${s.request ? "re-send" : "send"} ${c.classic_vm_id} ${step}`)
      ledger.append({ migration_id: mig, classic_vm_id: c.classic_vm_id, step, event: "started", request: req })
      try {
        const res = await send(req)
        ledger.append({ migration_id: mig, classic_vm_id: c.classic_vm_id, step, event: "done", result: res })
        return res
      } catch (e) {
        ledger.append({
          migration_id: mig,
          classic_vm_id: c.classic_vm_id,
          step,
          event: "failed",
          error: errText(e),
          ...httpStatus(e),
        })
        report.failed.push({ classic_vm_id: c.classic_vm_id, step, error: errText(e) })
        log(`failed ${c.classic_vm_id} ${step}: ${errText(e)}`)
        return undefined
      }
    }

    const snap = await run<VmApiImportRequest, { id: string }>(
      "vm_api_import",
      async () => ({
        tenant_id: await tenantFor(c, deps.resolvePersonalTenant),
        created_by: c.creator_user_id,
        classic_vm_id: c.classic_vm_id,
        upstream_vm_id: c.upstream_vm_id,
        migration_id: mig,
      }),
      (req) => deps.vmApi.importSnapshot(req),
    ).catch((e: unknown) => {
      // The tenant resolver failed before anything was sent or recorded.
      report.failed.push({ classic_vm_id: c.classic_vm_id, step: "vm_api_import", error: errText(e) })
      log(`failed ${c.classic_vm_id} vm_api_import: ${errText(e)}`)
      return undefined
    })
    if (!snap) continue
    const machine = await run<PlatformImportRequest, unknown>(
      "platform_import",
      async () => ({
        team: c.next_team_id,
        creator_user: c.creator_user_id,
        migration_id: mig,
        classic_vm_id: c.classic_vm_id,
        vm_api_snapshot_id: snap.id,
        name: c.name,
        size: c.size,
      }),
      (req) => deps.platform.importMachine(req),
    )
    if (machine === undefined) continue
    report.done.push(c.classic_vm_id)
  }
  return report
}

const tenantFor = async (c: CopySpec, resolve: PersonalTenantResolver) =>
  c.tenant.kind === "team"
    ? c.tenant.tenant_id
    : resolve({ stack_user_id: c.tenant.stack_user_id, user_id: c.tenant.user_id })

export interface RollbackReport {
  rolled_back: { classic_vm_id: string; step: Step }[]
  failed: { classic_vm_id: string; step: Step; error: string }[]
}

/**
 * Undoes, newest VM first, exactly what the ledger shows apply sent: the machine (with its CloudDO snapshot row)
 * before the VM API snapshot it was made from. A step already rolled back is skipped, so a second run sends
 * nothing. Deletes treat "not found" as done.
 */
export const rollback = async (ledger: Ledger, deps: Omit<Deps, "resolvePersonalTenant">): Promise<RollbackReport> => {
  const log = deps.log ?? (() => {})
  const mig = ledger.migrationId()
  const report: RollbackReport = { rolled_back: [], failed: [] }
  if (mig === undefined) return report
  const vms = [...ledger.state().values()].sort((a, b) => b.first - a.first)
  const touched = (s: StepState) => s.status !== "pending" && s.status !== "rolled_back" && s.request !== undefined

  for (const vm of vms) {
    const id = vm.classic_vm_id
    const mark = (step: Step, event: "rollback_started" | "rolled_back", note?: string) =>
      ledger.append({ migration_id: mig, classic_vm_id: id, step, event, ...(note ? { note } : {}) })
    const fail = (step: Step, e: unknown) => {
      ledger.append({ migration_id: mig, classic_vm_id: id, step, event: "rollback_failed", error: errText(e) })
      report.failed.push({ classic_vm_id: id, step, error: errText(e) })
      log(`rollback failed ${id} ${step}: ${errText(e)}`)
    }

    const p = vm.steps.platform_import
    if (touched(p)) {
      const req = p.request as PlatformImportRequest
      mark("platform_import", "rollback_started")
      try {
        await deps.platform.deleteMachine({ team: req.team, migration_id: req.migration_id, classic_vm_id: id })
        mark("platform_import", "rolled_back")
        report.rolled_back.push({ classic_vm_id: id, step: "platform_import" })
        log(`rolled back ${id} platform_import`)
      } catch (e) {
        // Keep the VM API snapshot: the machine may still be made from it.
        fail("platform_import", e)
        continue
      }
    }

    const v = vm.steps.vm_api_import
    if (!touched(v)) continue
    mark("vm_api_import", "rollback_started")
    try {
      let snapId = (v.result as { id?: string } | undefined)?.id
      if (snapId === undefined) {
        if (v.status === "failed" && v.http_status !== undefined && new HttpError(v.http_status, "", "").permanent) {
          mark("vm_api_import", "rolled_back", `import was refused (HTTP ${v.http_status}); nothing was created`)
          report.rolled_back.push({ classic_vm_id: id, step: "vm_api_import" })
          continue
        }
        // The import never answered: ask again with the same idempotent request to learn the id, then delete it.
        try {
          snapId = (await deps.vmApi.importSnapshot(v.request as VmApiImportRequest)).id
        } catch (e) {
          if (e instanceof HttpError && e.permanent) {
            mark("vm_api_import", "rolled_back", `import refused on re-check (HTTP ${e.status}); nothing was created`)
            report.rolled_back.push({ classic_vm_id: id, step: "vm_api_import" })
            continue
          }
          throw e
        }
      }
      await deps.vmApi.deleteSnapshot(snapId)
      mark("vm_api_import", "rolled_back", snapId)
      report.rolled_back.push({ classic_vm_id: id, step: "vm_api_import" })
      log(`rolled back ${id} vm_api_import ${snapId}`)
    } catch (e) {
      fail("vm_api_import", e)
    }
  }
  return report
}

export interface StatusRow {
  classic_vm_id: string
  vm_api_import: string
  platform_import: string
  snapshot?: string
  overall: "done" | "pending" | "in_flight" | "failed" | "rolled_back" | "rollback_incomplete"
}

/** What the ledger shows per VM; with a plan, VMs it never touched read as pending. */
export const status = (ledger: Ledger, plan?: Plan): StatusRow[] => {
  const states = ledger.state()
  const ids = new Set([...states.keys(), ...(plan ? copiesOf(plan).map((c) => c.classic_vm_id) : [])])
  return [...ids].sort().map((id) => {
    const vm = states.get(id) ?? blankVm(id)
    const a = vm.steps.vm_api_import
    const b = vm.steps.platform_import
    const all = [a.status, b.status]
    const overall: StatusRow["overall"] = all.some((s) => s === "rolling_back" || s === "rollback_failed")
      ? "rollback_incomplete"
      : all.includes("rolled_back")
        ? all.every((s) => s === "rolled_back" || s === "pending")
          ? "rolled_back"
          : "rollback_incomplete"
        : all.every((s) => s === "done")
          ? "done"
          : all.includes("failed")
            ? "failed"
            : all.includes("in_flight")
              ? "in_flight"
              : "pending"
    const snap = (a.result as { id?: string } | undefined)?.id
    return {
      classic_vm_id: id,
      vm_api_import: a.status,
      platform_import: b.status,
      ...(snap ? { snapshot: snap } : {}),
      overall,
    }
  })
}
