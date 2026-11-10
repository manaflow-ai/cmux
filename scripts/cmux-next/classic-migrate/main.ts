#!/usr/bin/env bun
// classic → NEXT Cloud migration CLI. Reads classic only (READ ONLY Postgres or a fixture), copies VMs into NEXT
// through cmux-platform's idempotent internal migration route, and records every step in an append-only ledger.
// See README.md.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { parseArgs } from "node:util"
import { apply, rollback, status, verify } from "./apply.ts"
import { httpLegacyVmApi, httpPlatform, type PlatformImports } from "./clients.ts"
import { Ledger } from "./ledger.ts"
import { buildPlan, renderPlanMarkdown, renderPlanText, type Plan } from "./plan.ts"
import {
  bunPostgresConnect,
  checkClassicHost,
  fixtureSource,
  postgresSource,
  readFixture,
  type ClassicSource,
  type Subject,
} from "./source.ts"

const USAGE = `usage: bun scripts/cmux-next/classic-migrate/main.ts <command> [options]

  plan      --user STACK_USER_ID | --team STACK_TEAM_ID
            [--source postgres | --source fixture FILE] [--stack-project ID] [--out DIR]
            [--allow-production-read]
  apply     --plan plan.json --ledger FILE [--only CLASSIC_VM_ID] [--dry-run] [--fresh]
            [--platform ORIGIN] [--json]
  rollback  --ledger FILE [--platform ORIGIN] [--vm-api ORIGIN] [--json]
  verify    --ledger FILE [--platform ORIGIN] [--json]
  status    --ledger FILE [--plan plan.json] [--json]

env: CLASSIC_DATABASE_URL, CLASSIC_DB_HOST_ALLOW (plan --source postgres);
     CMUX_PLATFORM_ORIGIN, INTERNAL_TOKEN (apply, rollback, verify);
     CMUX_VM_API_ORIGIN, CMUX_VM_IMPORT_KEY (rollback of a ledger the earlier CLI wrote, optional)
`

class UsageError extends Error {}

const need = (v: string | undefined, what: string) => {
  if (v === undefined || v === "") throw new UsageError(`missing ${what}`)
  return v
}

export const main = async (argv: string[], env: NodeJS.ProcessEnv = process.env): Promise<number> => {
  const [cmd, ...rest] = argv
  const { values, positionals } = parseArgs({
    args: rest,
    allowPositionals: true,
    options: {
      user: { type: "string" },
      team: { type: "string" },
      source: { type: "string" },
      fixture: { type: "string" },
      "stack-project": { type: "string" },
      out: { type: "string" },
      "allow-production-read": { type: "boolean" },
      plan: { type: "string" },
      ledger: { type: "string" },
      only: { type: "string" },
      "dry-run": { type: "boolean" },
      fresh: { type: "boolean" },
      platform: { type: "string" },
      "vm-api": { type: "string" },
      json: { type: "boolean" },
      help: { type: "boolean", short: "h" },
    },
  })
  if (values.help || cmd === undefined || cmd === "help") {
    process.stdout.write(USAGE)
    return cmd === undefined ? 2 : 0
  }
  const log = (line: string) => process.stderr.write(`${line}\n`)
  const clients = () => ({
    platform: httpPlatform(
      need(values.platform ?? env["CMUX_PLATFORM_ORIGIN"], "--platform or CMUX_PLATFORM_ORIGIN"),
      need(env["INTERNAL_TOKEN"], "INTERNAL_TOKEN"),
    ),
  })
  // Only an earlier-CLI ledger needs it (its own VM API imports); without it those are listed for manual cleanup.
  const legacyVmApi = () => {
    const origin = values["vm-api"] ?? env["CMUX_VM_API_ORIGIN"]
    const key = env["CMUX_VM_IMPORT_KEY"]
    return origin && key ? { legacyVmApi: httpLegacyVmApi(origin, key) } : {}
  }
  const printJson = (v: unknown) => process.stdout.write(`${JSON.stringify(v, null, 2)}\n`)

  switch (cmd) {
    case "plan": {
      if ((values.user === undefined) === (values.team === undefined))
        throw new UsageError("pass exactly one of --user or --team")
      const subject: Subject =
        values.user !== undefined ? { kind: "user", id: values.user } : { kind: "team", id: values.team! }
      const sourceKind = values.source ?? (values.fixture ? "fixture" : "postgres")
      let source: ClassicSource
      let project = values["stack-project"]
      if (sourceKind === "fixture") {
        const file = need(values.fixture ?? positionals[0], "fixture FILE (--source fixture FILE)")
        const fixture = readFixture(file)
        project ??= fixture.stack_project_id
        source = fixtureSource(fixture, `fixture ${file}`)
      } else if (sourceKind === "postgres") {
        const url = need(env["CLASSIC_DATABASE_URL"], "CLASSIC_DATABASE_URL")
        const { host, via } = checkClassicHost(url, env["CLASSIC_DB_HOST_ALLOW"], values["allow-production-read"] ?? false)
        if (via === "allow-production-read") log(`reading classic at ${host} under --allow-production-read (READ ONLY)`)
        source = postgresSource(bunPostgresConnect(url), `postgres ${host} (read only)`)
      } else throw new UsageError(`unknown --source ${sourceKind}`)
      project ??= env["STACK_PROJECT_ID"]
      const plan = buildPlan(
        await source.read(subject),
        need(project, "--stack-project (or STACK_PROJECT_ID)"),
        source.label,
      )
      const out = values.out ?? "."
      mkdirSync(out, { recursive: true })
      writeFileSync(join(out, "plan.json"), `${JSON.stringify(plan, null, 2)}\n`)
      writeFileSync(join(out, "plan.md"), renderPlanMarkdown(plan))
      process.stdout.write(renderPlanText(plan))
      log(`wrote ${join(out, "plan.json")} and ${join(out, "plan.md")}`)
      return 0
    }
    case "apply": {
      const plan = JSON.parse(readFileSync(need(values.plan, "--plan"), "utf8")) as Plan
      const dryRun = values["dry-run"] ?? false
      const ledger = new Ledger(dryRun && !values.ledger ? "/dev/null" : need(values.ledger, "--ledger"))
      const offline: PlatformImports = {
        importMachine: () => Promise.reject(new Error("dry run")),
        deleteMachine: () => Promise.reject(new Error("dry run")),
        list: () => Promise.reject(new Error("dry run")),
      }
      const report = await apply(
        plan,
        ledger,
        { ...(dryRun ? { platform: offline } : clients()), log },
        { ...(values.only !== undefined ? { only: values.only } : {}), dryRun, fresh: values.fresh ?? false },
      )
      if (values.json) printJson(report)
      else {
        if (dryRun) {
          process.stdout.write(renderPlanText(plan))
          for (const w of report.would) process.stdout.write(`would ${w.action}: ${w.classic_vm_id}\n`)
        }
        process.stdout.write(`attempt ${report.migration_id}: ${report.sent} request(s) sent\n`)
        for (const s of report.skipped) process.stdout.write(`skipped ${s.classic_vm_id}: ${s.why}\n`)
        for (const d of report.done) process.stdout.write(`done ${d}\n`)
        for (const f of report.failed) process.stdout.write(`failed ${f.classic_vm_id}: ${f.error}\n`)
      }
      return report.failed.length > 0 ? 1 : 0
    }
    case "rollback": {
      const report = await rollback(new Ledger(need(values.ledger, "--ledger")), { ...clients(), ...legacyVmApi(), log })
      if (values.json) printJson(report)
      else {
        for (const r of report.rolled_back) process.stdout.write(`rolled back ${r.classic_vm_id} (${r.status})\n`)
        for (const f of report.failed) process.stdout.write(`failed ${f.classic_vm_id}: ${f.error}\n`)
        for (const m of report.manual_cleanup)
          process.stdout.write(
            `MANUAL CLEANUP ${m.classic_vm_id} (${m.migration_id}) VM API snapshot ${m.vm_api_snapshot_id ?? "(id unknown)"}: ${m.why}\n`,
          )
        if (report.sent === 0 && report.manual_cleanup.length === 0) process.stdout.write("nothing to roll back\n")
      }
      return report.failed.length > 0 || report.manual_cleanup.length > 0 ? 1 : 0
    }
    case "verify": {
      const report = await verify(new Ledger(need(values.ledger, "--ledger")), { ...clients(), log })
      if (values.json) printJson(report)
      else {
        for (const r of report.rows)
          process.stdout.write(
            `${r.ok ? "ok  " : "FAIL"} ${r.attempt} ${r.classic_vm_id} expect ${r.expect}${r.found ? ` found ${r.found}` : ""}: ${r.note}\n`,
          )
        process.stdout.write(`${report.ok ? "verified" : "MISMATCH"}: ${report.rows.length} VM(s) in team ${report.team ?? "(none)"}\n`)
      }
      return report.ok ? 0 : 1
    }
    case "status": {
      const plan = values.plan ? (JSON.parse(readFileSync(values.plan, "utf8")) as Plan) : undefined
      const rows = status(new Ledger(need(values.ledger, "--ledger")), plan)
      if (values.json) process.stdout.write(`${JSON.stringify(rows, null, 2)}\n`)
      else {
        for (const r of rows)
          process.stdout.write(
            `${r.overall.padEnd(20)} ${r.classic_vm_id}  ${r.attempt}${r.vm_api_import ? ` vm_api_import=${r.vm_api_import}${r.snapshot ? ` ${r.snapshot}` : ""}` : ""} platform_import=${r.platform_import}${r.machine ? ` ${r.machine}` : ""}${r.ignored_steps ? ` (ignored unknown steps: ${r.ignored_steps.join(", ")})` : ""}\n`,
          )
        const by = new Map<string, number>()
        for (const r of rows) by.set(r.overall, (by.get(r.overall) ?? 0) + 1)
        process.stdout.write(`${[...by].map(([k, n]) => `${k} ${n}`).join(", ") || "empty ledger"}\n`)
      }
      return 0
    }
    default:
      throw new UsageError(`unknown command ${cmd}`)
  }
}

if (import.meta.main) {
  main(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (e: unknown) => {
      process.stderr.write(`classic-migrate: ${e instanceof Error ? e.message : String(e)}\n`)
      if (e instanceof UsageError) process.stderr.write(USAGE)
      process.exit(e instanceof UsageError ? 2 : 1)
    },
  )
}
