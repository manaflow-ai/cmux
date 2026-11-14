#!/usr/bin/env bun
// The staging proof of the classic → NEXT migration (.github/workflows/classic-migration-staging.yml). Leo,
// 2026-11-10: "are they a hassle to set up? Are they a hassle to redo? Are they a hassle to clean up?"
//
//   SETUP     classic staging, through its existing API only: a throwaway smoke user (cmuxVmPlan pro) with one
//             personal VM; a team (the user plus a second throwaway member, cmuxVmPlan team) with one VM; a marker
//             file holding a random nonce written on each VM through classic's exec route.
//   DRY RUN   `plan --user` and `plan --team` against classic staging Postgres (read only, host allowlist): each
//             classic VM is `copy`, nothing is `needs-decision`.
//   MIGRATE   `apply`, `verify`; the nonce read back on each NEXT machine through NEXT's exec route as the smoke
//             user (password sign-in); `apply` again sends nothing.
//   ROLLBACK  `rollback`, `verify` shows none, a second rollback sends nothing; each classic VM still answers exec
//             with its nonce.
//   TEARDOWN  always: rollback again if MIGRATE or ROLLBACK did not finish, delete the classic VMs, the team and the
//             users. `--teardown-only --state FILE` repeats it from the state file (the workflow's always() step).
//
// Without INTERNAL_TOKEN, MIGRATE and ROLLBACK are reported not-run and the proof still passes, so the dry-run half
// is proven before the operator steps land. Smoke users carry the classic sweep's prefix
// (`cmux-<label>-smoke+gh-<run>-<attempt>-…@manaflow.dev`), so a run killed before TEARDOWN is swept later.
import { randomBytes } from "node:crypto"
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { parseArgs } from "node:util"
import type { Plan } from "./plan.ts"

// ------------------------------------------------------------------------------------------------------------
// The proof's shape: pure, unit-tested with fakes (staging-proof.test.ts).

export type Result = "pass" | "fail" | "not-run"
export interface StepRecord {
  step: "setup" | "dry_run" | "migrate" | "rollback" | "teardown"
  seconds: number
  result: Result
  detail: string
}

export interface ProofOps {
  setup(): Promise<string>
  dryRun(): Promise<string>
  migrate(): Promise<string>
  rollback(): Promise<string>
  /** Rolls NEXT back when MIGRATE started and ROLLBACK did not pass. */
  rescueRollback(): Promise<string>
  teardown(): Promise<string>
}

export interface ProofOptions {
  /** Why MIGRATE and ROLLBACK do not run (no INTERNAL_TOKEN), or null to run them. */
  migrateSkip: string | null
  now?: () => number
}

const message = (e: unknown) => (e instanceof Error ? e.message : String(e))

/**
 * Runs the steps in order. A failed step stops the steps after it (reported not-run), except TEARDOWN, which always
 * runs, and first rolls NEXT back if MIGRATE started and ROLLBACK did not pass. The proof passes when no step failed.
 */
export const runProof = async (ops: ProofOps, opts: ProofOptions): Promise<{ ok: boolean; steps: StepRecord[] }> => {
  const now = opts.now ?? (() => performance.now())
  const steps: StepRecord[] = []
  let stopped = false
  const seconds = (t0: number) => Math.round((now() - t0) / 100) / 10
  const step = async (name: StepRecord["step"], fn: () => Promise<string>) => {
    if (stopped) {
      steps.push({ step: name, seconds: 0, result: "not-run", detail: "an earlier step failed" })
      return
    }
    const t0 = now()
    try {
      steps.push({ step: name, seconds: 0, result: "pass", detail: await fn() })
    } catch (e) {
      steps.push({ step: name, seconds: 0, result: "fail", detail: message(e) })
      stopped = true
    }
    steps.at(-1)!.seconds = seconds(t0)
  }

  await step("setup", ops.setup)
  await step("dry_run", ops.dryRun)
  let migrateStarted = false
  if (opts.migrateSkip === null) {
    await step("migrate", () => {
      migrateStarted = true
      return ops.migrate()
    })
    await step("rollback", ops.rollback)
  } else
    for (const name of ["migrate", "rollback"] as const)
      steps.push({ step: name, seconds: 0, result: "not-run", detail: opts.migrateSkip })

  const t0 = now()
  const notes: string[] = []
  let teardownFailed = false
  if (migrateStarted && steps.find((s) => s.step === "rollback")?.result !== "pass") {
    try {
      notes.push(`rescue rollback: ${await ops.rescueRollback()}`)
    } catch (e) {
      notes.push(`rescue rollback FAILED: ${message(e)}`)
      teardownFailed = true
    }
  }
  try {
    notes.push(await ops.teardown())
  } catch (e) {
    notes.push(`FAILED: ${message(e)}`)
    teardownFailed = true
  }
  steps.push({ step: "teardown", seconds: seconds(t0), result: teardownFailed ? "fail" : "pass", detail: notes.join("; ") })
  return { ok: steps.every((s) => s.result !== "fail"), steps }
}

export const summaryMarkdown = (ok: boolean, steps: StepRecord[], meta: Record<string, string> = {}): string => {
  const cell = (s: string) => s.replaceAll("|", "\\|").replaceAll("\n", " ").slice(0, 600)
  return [
    `### Classic → NEXT migration staging proof: ${ok ? "PASS" : "FAIL"}`,
    "",
    ...Object.entries(meta).map(([k, v]) => `- ${k}: ${v}`),
    "",
    "| step | seconds | result | detail |",
    "| --- | ---: | --- | --- |",
    ...steps.map((s) => `| ${s.step} | ${s.seconds} | ${s.result === "fail" ? "**fail**" : s.result} | ${cell(s.detail)} |`),
    "",
  ].join("\n")
}

/**
 * DRY RUN's check: every classic VM the setup made (by classic's API id, the provider VM id) is `copy` in its
 * subject's plan, and nothing needs a decision.
 */
export const checkDryRun = (plan: Plan, providerVmIds: string[]): string[] => {
  const problems: string[] = []
  for (const id of providerVmIds) {
    const e = plan.entries.find((x) => x.kind === "cloud_vm" && x.upstream_vm_id === id)
    if (!e) problems.push(`classic VM ${id} is not in the ${plan.subject.kind} plan`)
    else if (e.action !== "copy") problems.push(`classic VM ${id} is ${e.action} (${e.reason ?? ""}), not copy`)
  }
  if (plan.counts["needs-decision"] > 0) problems.push(`${plan.counts["needs-decision"]} object(s) need a decision`)
  return problems
}

// ------------------------------------------------------------------------------------------------------------
// The resources a run made, written after each creation so a later process can tear them down. No secrets.

export interface ProofState {
  tag: string
  users: { id: string; email: string; role: "owner" | "member"; gone?: true }[]
  /** The shared Stack team (two members, team plan). */
  team: { id: string; gone?: true } | null
  /**
   * The owner's personal Stack team: the personal VM's account scope. `created` when the proof made it (the user had
   * no team), so teardown deletes it; one Stack made on its own is left to the user's deletion.
   */
  personalTeam?: { id: string; created: boolean; gone?: true } | null
  /** `scope`: the X-Cmux-Team-Id classic bills and owns the VM under; every request for the VM sends it. */
  vms: { id: string; kind: "personal" | "team"; nonce: string; scope?: string; gone?: true }[]
  /**
   * Each classic create, written before its request: classic can answer 503 vm_operation_in_progress while the
   * create goes on, so teardown finds what an unanswered create made (by its display name, then by replaying the
   * same Idempotency-Key) before it deletes the owner. `resolved`: the VM id, or `none: <why>`.
   */
  creates?: CreateIntent[]
  ledgers: string[]
}

export interface CreateIntent {
  kind: "personal" | "team"
  key: string
  scope: string
  body: { provider: string; displayName: string }
  resolved?: string
}

/** The header classic reads a request's account scope from (web services/vms/routeHelpers.ts). */
export const SCOPE_HEADER = "x-cmux-team-id"

export type Http = (
  method: string,
  url: string,
  body?: unknown,
  headers?: Record<string, string>,
  timeoutMs?: number,
) => Promise<{ status: number; body: any }>

export interface Endpoints {
  stackApi: string
  classic: string
}
export interface StackKeys {
  project: string
  clientKey: string
  serverKey: string
}

const stackServerHeaders = (k: StackKeys) => ({
  "x-stack-access-type": "server",
  "x-stack-project-id": k.project,
  "x-stack-secret-server-key": k.serverKey,
  ...(k.clientKey ? { "x-stack-publishable-client-key": k.clientKey } : {}),
})

/** A short server-made session for a smoke user (the dogfood's createSession), as classic's session headers. */
export const classicSession = async (http: Http, ep: Endpoints, keys: StackKeys, userId: string) => {
  const r = await http(
    "POST",
    `${ep.stackApi}/api/v1/auth/sessions`,
    { user_id: userId, expires_in_millis: 30 * 60_000, is_impersonation: true },
    stackServerHeaders(keys),
  )
  if (r.status !== 200 || typeof r.body?.access_token !== "string")
    throw new Error(`session for ${userId}: HTTP ${r.status} ${String(r.body?.code ?? "")}`)
  return {
    authorization: `Bearer ${r.body.access_token}`,
    "x-stack-refresh-token": String(r.body.refresh_token ?? ""),
    "x-cmux-client": "cmux-classic-migration-proof",
  }
}

const scoped = (headers: Record<string, string>, scope: string | undefined) =>
  scope ? { ...headers, [SCOPE_HEADER]: scope } : headers

/**
 * Finds what an unanswered classic create made: a VM with its display name in its scope's list, else the answer to
 * the same request replayed with the same Idempotency-Key (classic reuses the key: the VM it made, 409/503 while it
 * runs, 500 vm_create_failed when it failed). Returns the VM id, `none: <why>` when nothing was made, or null when
 * the outcome is still unknown.
 */
export const resolveCreate = async (
  c: CreateIntent,
  deps: { http: Http; ep: Endpoints; headers: Record<string, string>; waitMs: number; sleep?: (ms: number) => Promise<void> },
): Promise<string | null> => {
  const { http, ep, waitMs } = deps
  const headers = scoped(deps.headers, c.scope)
  const pause = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)))
  const failed = (e: unknown) => ({ status: 0, body: { error: message(e) } as any })
  const t0 = Date.now()
  for (;;) {
    const l = await http("GET", `${ep.classic}/api/vm`, undefined, headers, 60_000).catch(failed)
    const found = l.status === 200 && Array.isArray(l.body?.vms)
      ? (l.body.vms as { id?: unknown; displayName?: unknown }[]).find((v) => v.displayName === c.body.displayName)
      : undefined
    if (found && typeof found.id === "string") return found.id
    const r = await http("POST", `${ep.classic}/api/vm`, c.body, { ...headers, "idempotency-key": c.key }, 180_000).catch(failed)
    if (r.status === 200 && typeof r.body?.id === "string") return r.body.id as string
    if (r.status === 500 && r.body?.error === "vm_create_failed") return "none: classic recorded the create as failed"
    if (r.status === 400 || r.status === 422) return `none: classic refused the create (HTTP ${r.status})`
    if (Date.now() - t0 >= waitMs) return null
    await pause(10_000)
  }
}

/**
 * Deletes what `state` records, idempotently: first it resolves every unanswered classic create into a VM (or
 * none), then deletes the classic VMs (as their owner, each under its own account scope), then each team once no
 * VM of its scope is left, then the users. A 404 counts as gone only under the VM's own scope: under another one
 * classic filters the VM out. When a VM cannot be deleted or a create stays unresolved, its owner and its team are
 * kept for a retry or the classic sweep, and this throws.
 */
export const teardownState = async (
  state: ProofState,
  deps: { http: Http; ep: Endpoints; keys: StackKeys; save: (s: ProofState) => void; createWaitMs?: number; sleep?: (ms: number) => Promise<void> },
): Promise<string> => {
  const { http, ep, keys, save } = deps
  const left: string[] = []
  const owner = state.users.find((u) => u.role === "owner")
  const pending = () => (state.creates ?? []).filter((c) => c.resolved === undefined)
  if ((pending().length > 0 || state.vms.some((v) => !v.gone)) && owner) {
    let headers: Record<string, string> | null = null
    try {
      headers = await classicSession(http, ep, keys, owner.id)
    } catch (e) {
      left.push(`classic session: ${message(e)}`)
    }
    for (const c of pending()) {
      if (!headers) break
      const got = await resolveCreate(c, { http, ep, headers, waitMs: deps.createWaitMs ?? 6 * 60_000, ...(deps.sleep ? { sleep: deps.sleep } : {}) })
      if (got === null) continue
      c.resolved = got
      if (!got.startsWith("none:") && !state.vms.some((v) => v.id === got))
        state.vms.push({ id: got, kind: c.kind, nonce: "", scope: c.scope })
      save(state)
    }
    for (const c of pending()) left.push(`classic create ${c.kind} (Idempotency-Key ${c.key}) unresolved`)
    for (const vm of state.vms.filter((v) => !v.gone)) {
      if (!headers) {
        left.push(`classic VM ${vm.id}`)
        continue
      }
      const r = await http("DELETE", `${ep.classic}/api/vm/${encodeURIComponent(vm.id)}`, undefined, scoped(headers, vm.scope), 60_000).catch(
        (e: unknown) => ({ status: 0, body: { error: message(e) } }),
      )
      if (r.status === 200 || (r.status === 404 && vm.scope)) vm.gone = true
      else if (r.status === 404) left.push(`classic VM ${vm.id} (HTTP 404 with no recorded scope: not confirmed gone)`)
      else left.push(`classic VM ${vm.id} (HTTP ${r.status})`)
      save(state)
    }
  }
  // A VM with no recorded scope may be under any team, and an unresolved create under its own: keep those teams.
  const unscopedLeft = state.vms.some((v) => !v.gone && !v.scope)
  const scopeBusy = (team: string) =>
    unscopedLeft || state.vms.some((v) => !v.gone && v.scope === team) || pending().some((c) => c.scope === team)
  const teams = [
    ...(state.team ? [{ t: state.team, what: "team" }] : []),
    ...(state.personalTeam?.created ? [{ t: state.personalTeam, what: "personal team" }] : []),
  ]
  for (const { t, what } of teams) {
    if (t.gone) continue
    if (scopeBusy(t.id)) {
      left.push(`${what} ${t.id} kept (a classic VM under it is not confirmed gone)`)
      continue
    }
    const r = await http("DELETE", `${ep.stackApi}/api/v1/teams/${t.id}`, undefined, stackServerHeaders(keys))
    if (r.status === 200 || r.status === 404) t.gone = true
    else left.push(`${what} ${t.id} (HTTP ${r.status})`)
    save(state)
  }
  const vmLeft = state.vms.some((v) => !v.gone) || pending().length > 0
  for (const u of state.users) {
    if (u.gone) continue
    if (u.role === "owner" && vmLeft) {
      left.push(`user ${u.email} kept for the classic sweep (it still owns a VM)`)
      continue
    }
    const r = await http("DELETE", `${ep.stackApi}/api/v1/users/${u.id}`, undefined, stackServerHeaders(keys))
    if (r.status === 200 || r.status === 404) u.gone = true
    else left.push(`user ${u.email} (HTTP ${r.status})`)
    save(state)
  }
  if (left.length > 0) throw new Error(`left behind: ${left.join(", ")}`)
  return `deleted ${state.vms.length} classic VM(s), ${teams.length} team(s), ${state.users.length} user(s)`
}

/**
 * `--teardown-only`: the rescue rollback of NEXT (when asked), then the classic teardown, always both; the failures
 * of both are reported together.
 */
export const teardownOnly = async (ops: Pick<ProofOps, "rescueRollback" | "teardown">, rescue: boolean) => {
  const notes: string[] = []
  const failures: string[] = []
  if (rescue)
    try {
      notes.push(`rescue rollback: ${await ops.rescueRollback()}`)
    } catch (e) {
      failures.push(`rescue rollback: ${message(e)}`)
    }
  try {
    notes.push(await ops.teardown())
  } catch (e) {
    failures.push(`teardown: ${message(e)}`)
  }
  return { ok: failures.length === 0, notes, failures }
}

// ------------------------------------------------------------------------------------------------------------
// The staging run (network; not unit-tested).

const http: Http = async (method, url, body, headers = {}, timeoutMs = 60_000) => {
  const res = await fetch(url, {
    method,
    headers: { ...(body === undefined ? {} : { "content-type": "application/json" }), ...headers },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(timeoutMs),
  })
  const text = await res.text()
  let parsed: any
  try {
    parsed = text ? JSON.parse(text) : {}
  } catch {
    parsed = { raw: text.slice(0, 300) }
  }
  return { status: res.status, body: parsed }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const short = (v: unknown) => JSON.stringify(v ?? null).slice(0, 300)

/** Retries `fn` until it returns a value or `budgetMs` runs out (a test harness wait, never product code). */
const until = async <T>(what: string, budgetMs: number, everyMs: number, fn: () => Promise<T | null>): Promise<T> => {
  const t0 = Date.now()
  let last = ""
  for (;;) {
    try {
      const v = await fn()
      if (v !== null) return v
    } catch (e) {
      last = message(e)
    }
    if (Date.now() - t0 > budgetMs) throw new Error(`${what}: not within ${Math.round(budgetMs / 1000)} s${last ? ` (last: ${last})` : ""}`)
    await sleep(everyMs)
  }
}

const MAIN = join(import.meta.dirname, "main.ts")
const MARKER = "/var/tmp/cmux-classic-migration-proof"

interface Config {
  out: string
  keys: StackKeys
  ep: Endpoints
  databaseUrl: string
  hostAllow: string
  platform: string
  internalToken: string | null
  nextApi: string
  label: string
  runTag: string
}

const cli = async (cfg: Config, args: string[], extraEnv: Record<string, string> = {}) => {
  const p = Bun.spawn(["bun", MAIN, ...args], {
    env: {
      PATH: process.env["PATH"] ?? "",
      HOME: process.env["HOME"] ?? "",
      CLASSIC_DATABASE_URL: cfg.databaseUrl,
      CLASSIC_DB_HOST_ALLOW: cfg.hostAllow,
      CMUX_PLATFORM_ORIGIN: cfg.platform,
      ...(cfg.internalToken ? { INTERNAL_TOKEN: cfg.internalToken } : {}),
      ...extraEnv,
    },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  })
  const [stdout, stderr, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited])
  return { code, stdout, stderr }
}

const cliOk = async (cfg: Config, args: string[]) => {
  const r = await cli(cfg, args)
  if (r.code !== 0) throw new Error(`classic-migrate ${args[0]} exited ${r.code}: ${(r.stderr || r.stdout).slice(-600)}`)
  return r.stdout
}

const stagingOps = (cfg: Config, state: ProofState, save: (s: ProofState) => void): ProofOps => {
  const password = randomBytes(24).toString("base64url")
  const stackServer = (method: string, path: string, body?: unknown) =>
    http(method, `${cfg.ep.stackApi}/api/v1${path}`, body, stackServerHeaders(cfg.keys))
  const owner = () => state.users.find((u) => u.role === "owner")!
  const vm = (kind: "personal" | "team") => state.vms.find((v) => v.kind === kind)!
  const plans: Record<"user" | "team", Plan | null> = { user: null, team: null }
  const ledgerOf = (kind: "user" | "team") => join(cfg.out, kind, "ledger.jsonl")

  const makeUser = async (role: "owner" | "member", plan: string | null) => {
    const email = `cmux-${cfg.label}-smoke+${cfg.runTag}classicmig-${role}-${Date.now()}-${randomBytes(3).toString("hex")}@manaflow.dev`
    const r = await stackServer("POST", "/users", {
      primary_email: email,
      primary_email_verified: true,
      primary_email_auth_enabled: true,
      password,
      display_name: `cmux ${cfg.label} classic migration ${role}`,
      ...(plan ? { client_read_only_metadata: { cmuxVmPlan: plan } } : {}),
    })
    if ((r.status !== 200 && r.status !== 201) || typeof r.body?.id !== "string")
      throw new Error(`create ${role} user: HTTP ${r.status} ${short(r.body?.code ?? r.body)}`)
    state.users.push({ id: r.body.id, email, role })
    save(state)
    return r.body.id as string
  }

  // Every classic request names its VM's account scope: once the paid shared team exists, classic's default billing
  // team resolution could pick it for a personal-VM request, and then filters the personal VM out (exec fails, DELETE
  // answers 404 while the VM lives).
  const classicHeaders = async (scope: string) => ({
    ...(await classicSession(http, cfg.ep, cfg.keys, owner().id)),
    [SCOPE_HEADER]: scope,
  })

  const classicExec = async (v: { id: string; scope?: string }, command: string) => {
    if (!v.scope) throw new Error(`classic VM ${v.id} has no recorded scope`)
    const r = await http(
      "POST",
      `${cfg.ep.classic}/api/vm/${encodeURIComponent(v.id)}/exec`,
      { command, timeoutMs: 60_000 },
      await classicHeaders(v.scope),
      120_000,
    )
    if (r.status !== 200) throw new Error(`classic exec on ${v.id}: HTTP ${r.status} ${short(r.body)}`)
    return { stdout: String(r.body?.stdout ?? ""), exitCode: Number(r.body?.exitCode ?? r.body?.exit_code ?? -1) }
  }

  const makeVm = async (kind: "personal" | "team", scope: string) => {
    // The intent first: an answer lost to a timeout or a 503 vm_operation_in_progress leaves a create teardown resolves.
    const intent: CreateIntent = {
      kind,
      key: `classicmig-${cfg.runTag}${kind}-${state.tag}`,
      scope,
      body: { provider: "freestyle", displayName: `classicmig-${state.tag}-${kind}` },
    }
    state.creates = [...(state.creates ?? []), intent]
    save(state)
    const r = await http(
      "POST",
      `${cfg.ep.classic}/api/vm`,
      intent.body,
      { ...(await classicHeaders(scope)), "idempotency-key": intent.key },
      180_000,
    )
    if (r.status !== 200 || typeof r.body?.id !== "string") throw new Error(`classic create ${kind} VM: HTTP ${r.status} ${short(r.body)}`)
    const nonce = randomBytes(12).toString("hex")
    state.vms.push({ id: r.body.id, kind, nonce, scope })
    intent.resolved = r.body.id
    save(state)
    const made = state.vms.at(-1)!
    await until(`classic ${kind} VM ${r.body.id} running`, 6 * 60_000, 5000, async () => {
      const g = await http("GET", `${cfg.ep.classic}/api/vm/${encodeURIComponent(r.body.id)}`, undefined, await classicHeaders(scope))
      if (g.status !== 200) throw new Error(`GET HTTP ${g.status}`)
      if (g.body?.status === "failed") throw new Error(`classic VM failed: ${short(g.body)}`)
      return g.body?.status === "running" ? true : null
    })
    const w = await classicExec(made, `umask 022; printf %s ${nonce} > ${MARKER} && sync && cat ${MARKER}`)
    if (w.stdout.trim() !== nonce) throw new Error(`marker on classic ${kind} VM: read back ${short(w.stdout)}`)
    return r.body.id as string
  }

  const nextSession = async () => {
    const r = await http(
      "POST",
      `${cfg.ep.stackApi}/api/v1/auth/password/sign-in`,
      { email: owner().email, password },
      {
        "x-stack-access-type": "client",
        "x-stack-project-id": cfg.keys.project,
        ...(cfg.keys.clientKey ? { "x-stack-publishable-client-key": cfg.keys.clientKey } : {}),
      },
    )
    if (r.status !== 200 || typeof r.body?.access_token !== "string") throw new Error(`NEXT sign-in: HTTP ${r.status} ${short(r.body?.code)}`)
    return String(r.body.access_token)
  }

  const nextReadsNonce = async (machine: string, team: string, nonce: string) =>
    until(`NEXT machine ${machine} answers with the marker`, 8 * 60_000, 10_000, async () => {
      const r = await http(
        "POST",
        `${cfg.nextApi}/v1/cloud/machines/${encodeURIComponent(machine)}/exec`,
        { command: `cat ${MARKER}`, timeoutMs: 30_000 },
        { authorization: `Bearer ${await nextSession()}`, "x-cmux-team": team },
        90_000,
      )
      const v = r.body?.value ?? r.body
      if (r.status < 200 || r.status >= 300 || v?.ok === false) throw new Error(`exec HTTP ${r.status} ${short(v?.error ?? v)}`)
      const out = String(v?.stdout ?? "").trim()
      if (out !== nonce) throw new Error(`marker read back ${short(out)}, want the classic nonce`)
      return true
    })

  const ledgerBytes = (kind: "user" | "team") => (existsSync(ledgerOf(kind)) ? readFileSync(ledgerOf(kind), "utf8").length : 0)
  const machineIds = async (kind: "user" | "team") =>
    (JSON.parse(await cliOk(cfg, ["status", "--ledger", ledgerOf(kind), "--json"])) as { machine?: string; overall: string }[]).map(
      (r) => {
        if (r.overall !== "done" || !r.machine) throw new Error(`${kind} ledger shows ${r.overall}`)
        return r.machine
      },
    )

  return {
    setup: async () => {
      const ownerId = await makeUser("owner", "pro")
      const memberId = await makeUser("member", null)
      // The personal VM's scope: the owner's personal Stack team (Stack may make one at sign-up), or one made here,
      // marked personal, that teardown deletes.
      const own = await stackServer("GET", `/teams?user_id=${encodeURIComponent(ownerId)}`)
      if (own.status !== 200 || !Array.isArray(own.body?.items)) throw new Error(`list owner teams: HTTP ${own.status} ${short(own.body)}`)
      if (own.body.items.length > 1) throw new Error(`the new owner already has ${own.body.items.length} teams`)
      if (own.body.items.length === 1) state.personalTeam = { id: String(own.body.items[0].id), created: false }
      else {
        const pt = await stackServer("POST", "/teams", {
          display_name: `cmux classic migration personal ${state.tag}`,
          creator_user_id: ownerId,
          server_metadata: { isPersonal: true },
        })
        if ((pt.status !== 200 && pt.status !== 201) || typeof pt.body?.id !== "string")
          throw new Error(`create personal team: HTTP ${pt.status} ${short(pt.body)}`)
        state.personalTeam = { id: pt.body.id, created: true }
      }
      save(state)
      await makeVm("personal", state.personalTeam.id)
      const t = await stackServer("POST", "/teams", { display_name: `cmux classic migration ${state.tag}`, creator_user_id: ownerId })
      if ((t.status !== 200 && t.status !== 201) || typeof t.body?.id !== "string") throw new Error(`create team: HTTP ${t.status} ${short(t.body)}`)
      state.team = { id: t.body.id }
      save(state)
      const m = await stackServer("POST", `/team-memberships/${t.body.id}/${memberId}`, {})
      if (m.status !== 200 && m.status !== 201) throw new Error(`add member: HTTP ${m.status} ${short(m.body)}`)
      const p = await stackServer("PATCH", `/teams/${t.body.id}`, { client_read_only_metadata: { cmuxVmPlan: "team" } })
      if (p.status !== 200) throw new Error(`team plan: HTTP ${p.status} ${short(p.body)}`)
      await makeVm("team", t.body.id)
      return `user ${ownerId} with VM ${vm("personal").id}; team ${t.body.id} (2 members) with VM ${vm("team").id}; markers written`
    },

    dryRun: async () => {
      const out: string[] = []
      for (const [kind, subject, vmId] of [
        ["user", owner().id, vm("personal").id],
        ["team", state.team!.id, vm("team").id],
      ] as const) {
        const dir = join(cfg.out, kind)
        // Classic mirrors Stack users and teams by webhook: re-plan until the new rows are there.
        const plan = await until(`plan --${kind} shows ${vmId} as copy`, 4 * 60_000, 15_000, async () => {
          await cliOk(cfg, ["plan", `--${kind}`, subject, "--source", "postgres", "--stack-project", cfg.keys.project, "--out", dir])
          const p = JSON.parse(readFileSync(join(dir, "plan.json"), "utf8")) as Plan
          const problems = checkDryRun(p, [vmId])
          if (problems.length > 0) throw new Error(problems.join("; "))
          return p
        })
        plans[kind] = plan
        const c = plan.counts
        out.push(`${kind}: copy ${c.copy}, carried ${c.carried}, link ${c.link}, not-migrated ${c["not-migrated"]}, needs-decision ${c["needs-decision"]}`)
      }
      return out.join("; ")
    },

    migrate: async () => {
      // NEXT materializes the smoke user at its first signed-in call (user.ensure), as the app does.
      const token = await nextSession()
      const ensure = await http("POST", `${cfg.nextApi}/v1/ops`, { op: "user.ensure", params: {}, idempotency_key: `classicmig-${state.tag}-ensure` }, { authorization: `Bearer ${token}` })
      if (ensure.status !== 200 || ensure.body?.ok !== true) throw new Error(`NEXT user.ensure: HTTP ${ensure.status} ${short(ensure.body?.error ?? ensure.body)}`)
      const out: string[] = []
      for (const kind of ["user", "team"] as const) {
        const plan = plans[kind]!
        const planFile = join(cfg.out, kind, "plan.json")
        if (!state.ledgers.includes(ledgerOf(kind))) state.ledgers.push(ledgerOf(kind))
        save(state)
        await cliOk(cfg, ["apply", "--plan", planFile, "--ledger", ledgerOf(kind)])
        const v = JSON.parse(await cliOk(cfg, ["verify", "--ledger", ledgerOf(kind), "--json"])) as { ok: boolean }
        if (!v.ok) throw new Error(`verify after apply (${kind}) failed`)
        const [machine] = await machineIds(kind)
        await nextReadsNonce(machine!, plan.subject.next_team_id, vm(kind === "user" ? "personal" : "team").nonce)
        const before = ledgerBytes(kind)
        const again = JSON.parse(await cliOk(cfg, ["apply", "--plan", planFile, "--ledger", ledgerOf(kind), "--json"])) as { sent: number }
        if (again.sent !== 0 || ledgerBytes(kind) !== before) throw new Error(`re-apply (${kind}) sent ${again.sent} request(s)`)
        out.push(`${kind}: machine ${machine} in ${plan.subject.next_team_id} reads the nonce; re-apply sent 0`)
      }
      return out.join("; ")
    },

    rollback: async () => {
      const out: string[] = []
      for (const kind of ["user", "team"] as const) {
        await cliOk(cfg, ["rollback", "--ledger", ledgerOf(kind)])
        const v = JSON.parse(await cliOk(cfg, ["verify", "--ledger", ledgerOf(kind), "--json"])) as {
          ok: boolean
          rows: { expect: string; found: string | null }[]
        }
        if (!v.ok || v.rows.some((r) => r.expect !== "absent")) throw new Error(`verify after rollback (${kind}): ${short(v.rows)}`)
        const before = ledgerBytes(kind)
        const second = JSON.parse(await cliOk(cfg, ["rollback", "--ledger", ledgerOf(kind), "--json"])) as { sent: number }
        if (second.sent !== 0 || ledgerBytes(kind) !== before) throw new Error(`second rollback (${kind}) sent ${second.sent}`)
        out.push(`${kind}: rolled back, verify none, second rollback sent 0`)
      }
      for (const v of state.vms) {
        const r = await classicExec(v, `cat ${MARKER}`)
        if (r.stdout.trim() !== v.nonce) throw new Error(`classic ${v.kind} VM ${v.id} no longer reads its nonce: ${short(r.stdout)}`)
      }
      out.push(`classic: ${state.vms.length} VM(s) still answer with their nonce`)
      return out.join("; ")
    },

    rescueRollback: async () => {
      const out: string[] = []
      for (const ledger of state.ledgers) {
        const r = await cli(cfg, ["rollback", "--ledger", ledger, "--json"])
        if (r.code !== 0) throw new Error(`rollback ${ledger}: ${(r.stderr || r.stdout).slice(-300)}`)
        out.push(`${ledger}: ${(JSON.parse(r.stdout) as { sent: number }).sent} sent`)
      }
      return out.join(", ") || "no ledger"
    },

    teardown: () => teardownState(state, { http, ep: cfg.ep, keys: cfg.keys, save }),
  }
}

const config = (out: string, env: NodeJS.ProcessEnv, values: Record<string, string | boolean | undefined>): Config => {
  const need = (k: string) => {
    const v = env[k]?.trim()
    if (!v) throw new Error(`missing ${k}`)
    return v
  }
  const runId = env["GITHUB_RUN_ID"]?.trim()
  return {
    out,
    keys: {
      project: need("NEXT_PUBLIC_STACK_PROJECT_ID"),
      clientKey: env["NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY"]?.trim() ?? "",
      serverKey: need("STACK_SECRET_SERVER_KEY"),
    },
    ep: {
      stackApi: (env["STACK_API_URL"]?.trim() || "https://api.stack-auth.com").replace(/\/+$/, ""),
      classic: String(values["classic-url"] ?? "https://cmux-staging.vercel.app").replace(/\/+$/, ""),
    },
    databaseUrl: env["DATABASE_URL"]?.trim() ?? "",
    hostAllow: env["CLASSIC_DB_HOST_ALLOW"]?.trim() ?? "",
    platform: String(values["platform"] ?? "https://cmux-platform-staging.debussy.workers.dev").replace(/\/+$/, ""),
    internalToken: env["INTERNAL_TOKEN"]?.trim() || null,
    nextApi: String(values["next-api"] ?? "https://cloud-api-staging.cmux.dev").replace(/\/+$/, ""),
    label: String(values["label"] ?? "staging"),
    runTag: runId && /^\d+$/.test(runId) ? `gh-${runId}-${env["GITHUB_RUN_ATTEMPT"]?.trim() || "1"}-` : "",
  }
}

const dbHost = (url: string) => {
  try {
    return new URL(url).hostname
  } catch {
    return ""
  }
}

const main = async (argv: string[], env: NodeJS.ProcessEnv): Promise<number> => {
  const { values } = parseArgs({
    args: argv,
    options: {
      out: { type: "string" },
      "classic-url": { type: "string" },
      platform: { type: "string" },
      "next-api": { type: "string" },
      label: { type: "string" },
      "teardown-only": { type: "boolean" },
    },
  })
  const out = values.out ?? "classic-migration-proof"
  mkdirSync(out, { recursive: true })
  const statePath = join(out, "state.json")
  const save = (s: ProofState) => writeFileSync(statePath, `${JSON.stringify(s, null, 2)}\n`)
  const cfg = config(out, env, values)

  if (values["teardown-only"]) {
    if (!existsSync(statePath)) {
      console.log("no state file: nothing to tear down")
      return 0
    }
    const state = JSON.parse(readFileSync(statePath, "utf8")) as ProofState
    const ops = stagingOps(cfg, state, save)
    const r = await teardownOnly(ops, cfg.internalToken !== null && state.ledgers.length > 0)
    for (const n of r.notes) console.log(n)
    for (const f of r.failures) console.error(`FAILED ${f}`)
    return r.ok ? 0 : 1
  }

  const state: ProofState = { tag: randomBytes(4).toString("hex"), users: [], team: null, vms: [], ledgers: [] }
  save(state)
  const ops = stagingOps(cfg, state, save)
  const guarded: ProofOps = {
    ...ops,
    dryRun: async () => {
      if (!cfg.databaseUrl) throw new Error("missing DATABASE_URL (classic staging Postgres)")
      if (!cfg.hostAllow) throw new Error("missing CLASSIC_DB_HOST_ALLOW (input classic_db_host_allow or variable)")
      return ops.dryRun()
    },
  }
  const migrateSkip = cfg.internalToken
    ? null
    : "PLATFORM_STAGING_INTERNAL_TOKEN is not set in the environment yet (cmuxterm-hq#8793)"
  if (migrateSkip) console.log(`::notice title=classic migration proof::MIGRATE and ROLLBACK not run: ${migrateSkip}`)
  const { ok, steps } = await runProof(guarded, { migrateSkip })
  // Details carry CLI and HTTP errors: keep the database URL, its host and the keys out of the summary and artifact.
  const hidden = [cfg.databaseUrl, dbHost(cfg.databaseUrl), cfg.internalToken ?? "", cfg.keys.serverKey].filter((x) => x.length >= 6)
  for (const s of steps) for (const h of hidden) s.detail = s.detail.split(h).join("[hidden]")
  const meta = {
    classic: cfg.ep.classic,
    platform: cfg.platform,
    "NEXT API": cfg.nextApi,
    "Stack project": cfg.keys.project.slice(0, 8),
  }
  writeFileSync(join(out, "proof.json"), `${JSON.stringify({ ok, meta, steps, state }, null, 2)}\n`)
  const md = summaryMarkdown(ok, steps, meta)
  process.stdout.write(md)
  if (env["GITHUB_STEP_SUMMARY"]) appendFileSync(env["GITHUB_STEP_SUMMARY"], md)
  return ok ? 0 : 1
}

if (import.meta.main) {
  main(process.argv.slice(2), process.env).then(
    (code) => process.exit(code),
    (e: unknown) => {
      process.stderr.write(`staging-proof: ${message(e)}\n`)
      process.exit(1)
    },
  )
}
