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
  team: { id: string; gone?: true } | null
  vms: { id: string; kind: "personal" | "team"; nonce: string; gone?: true }[]
  ledgers: string[]
}

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

/**
 * Deletes what `state` records, idempotently: classic VMs (as their owner), then the team, then the users. A 404
 * counts as gone. When a VM cannot be deleted, its owner is kept for the classic sweep and this throws.
 */
export const teardownState = async (
  state: ProofState,
  deps: { http: Http; ep: Endpoints; keys: StackKeys; save: (s: ProofState) => void },
): Promise<string> => {
  const { http, ep, keys, save } = deps
  const left: string[] = []
  const owner = state.users.find((u) => u.role === "owner")
  const vms = state.vms.filter((v) => !v.gone)
  if (vms.length > 0 && owner) {
    let headers: Record<string, string> | null = null
    try {
      headers = await classicSession(http, ep, keys, owner.id)
    } catch (e) {
      left.push(`classic session: ${message(e)}`)
    }
    for (const vm of vms) {
      if (!headers) {
        left.push(`classic VM ${vm.id}`)
        continue
      }
      const r = await http("DELETE", `${ep.classic}/api/vm/${encodeURIComponent(vm.id)}`, undefined, headers, 60_000).catch(
        (e: unknown) => ({ status: 0, body: { error: message(e) } }),
      )
      if (r.status === 200 || r.status === 404) vm.gone = true
      else left.push(`classic VM ${vm.id} (HTTP ${r.status})`)
      save(state)
    }
  }
  if (state.team && !state.team.gone) {
    const r = await http("DELETE", `${ep.stackApi}/api/v1/teams/${state.team.id}`, undefined, stackServerHeaders(keys))
    if (r.status === 200 || r.status === 404) state.team.gone = true
    else left.push(`team ${state.team.id} (HTTP ${r.status})`)
    save(state)
  }
  const vmLeft = state.vms.some((v) => !v.gone)
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
  return `deleted ${state.vms.length} classic VM(s), ${state.team ? 1 : 0} team, ${state.users.length} user(s)`
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

  const classicHeaders = () => classicSession(http, cfg.ep, cfg.keys, owner().id)

  const classicExec = async (id: string, command: string) => {
    const r = await http(
      "POST",
      `${cfg.ep.classic}/api/vm/${encodeURIComponent(id)}/exec`,
      { command, timeoutMs: 60_000 },
      await classicHeaders(),
      120_000,
    )
    if (r.status !== 200) throw new Error(`classic exec on ${id}: HTTP ${r.status} ${short(r.body)}`)
    return { stdout: String(r.body?.stdout ?? ""), exitCode: Number(r.body?.exitCode ?? r.body?.exit_code ?? -1) }
  }

  const makeVm = async (kind: "personal" | "team", teamId?: string) => {
    const r = await http(
      "POST",
      `${cfg.ep.classic}/api/vm`,
      { provider: "freestyle", ...(teamId ? { teamId } : {}) },
      { ...(await classicHeaders()), "idempotency-key": `classicmig-${cfg.runTag}${kind}-${state.tag}` },
      180_000,
    )
    if (r.status !== 200 || typeof r.body?.id !== "string") throw new Error(`classic create ${kind} VM: HTTP ${r.status} ${short(r.body)}`)
    const nonce = randomBytes(12).toString("hex")
    state.vms.push({ id: r.body.id, kind, nonce })
    save(state)
    await until(`classic ${kind} VM ${r.body.id} running`, 6 * 60_000, 5000, async () => {
      const g = await http("GET", `${cfg.ep.classic}/api/vm/${encodeURIComponent(r.body.id)}`, undefined, await classicHeaders())
      if (g.status !== 200) throw new Error(`GET HTTP ${g.status}`)
      if (g.body?.status === "failed") throw new Error(`classic VM failed: ${short(g.body)}`)
      return g.body?.status === "running" ? true : null
    })
    const w = await classicExec(r.body.id, `umask 022; printf %s ${nonce} > ${MARKER} && sync && cat ${MARKER}`)
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
      // The personal VM first: with only its own team(s), classic bills and owns it personally.
      await makeVm("personal")
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
        const r = await classicExec(v.id, `cat ${MARKER}`)
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
    if (cfg.internalToken && state.ledgers.length > 0) console.log(`rescue rollback: ${await ops.rescueRollback()}`)
    console.log(await ops.teardown())
    return 0
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
