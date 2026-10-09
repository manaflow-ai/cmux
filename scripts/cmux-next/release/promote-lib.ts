/**
 * cmux VM image promotion (images/cmux-vm/promote.ts; plans/cmux-next/release-rails.md).
 *
 *   bun images/cmux-vm/promote.ts --channel dev|staging|production --snapshot <sh-id> [--var CLOUD_FREESTYLE_SNAPSHOT|TEAM_VM_SNAPSHOT] [--worker-version <id>]
 *   bun images/cmux-vm/promote.ts --channel dev|staging|production --rollback [--var ...]
 *
 * The cmux API Worker (backend/apps/api/wrangler.jsonc) boots NEW Cloud
 * machines from vars.CLOUD_FREESTYLE_SNAPSHOT and new team VMs from
 * vars.TEAM_VM_SNAPSHOT, per env (development, staging, production; channel
 * dev = env development). Promote refuses unless channels/dev.json `history`
 * records that exact snapshot id with smoke PASSED, and (CLOUD_FREESTYLE_SNAPSHOT)
 * unless its name carries the env's image prefix: the Worker boots only
 * cmuxnp-<env>-vmimg- snapshots, so a foreign name would make every create
 * "provider unavailable". Then it re-runs images/cmux-vm/smoke.ts on fresh
 * cmuxnp-dev clones of that id and refuses unless the smoke passed and every
 * clone it created is recorded deleted. Only then it sets the var in
 * wrangler.jsonc and writes channels/<channel>.json (the old value becomes
 * `previous`), and writes a receipt. The next deploy of that env ships it
 * (staging: a push to feat-cmux-next; production: the manual deploy). Nothing
 * here touches a running VM: the image only decides what NEW machines boot.
 *
 * --rollback restores `previous` in both files (no smoke: it was serving).
 * After a deploy, `wrangler rollback <version>` undoes it at once; the receipt
 * names that version when --worker-version (the serving version before the
 * deploy, printed by worker-release.ts previous) is passed.
 */
import { spawnSync } from "node:child_process"
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { receiptsDir, runIdOf, summaryLine, writeReceipt } from "./receipts.ts"
import { REPO_ROOT } from "./trees.ts"

export type Channel = "dev" | "staging" | "production"
export type SnapshotVar = "CLOUD_FREESTYLE_SNAPSHOT" | "TEAM_VM_SNAPSHOT"
export const ENV_OF: Readonly<Record<Channel, "development" | "staging" | "production">> = { dev: "development", staging: "staging", production: "production" }
export const WORKER_OF: Readonly<Record<Channel, string>> = { dev: "cmux-api-development", staging: "cmux-api-staging", production: "cmux-api" }
/** backend/apps/api/src/cloud-driver.ts ENV_IMAGE_PREFIX (enforced for CLOUD_FREESTYLE_SNAPSHOT only, as the Worker does). */
export const CHANNEL_PREFIX: Readonly<Record<Channel, string>> = { dev: "cmuxnp-dev-vmimg-", staging: "cmuxnp-stg-vmimg-", production: "cmuxnp-prod-vmimg-" }
/** Where each var's pointer lives in a channel file: CLOUD at the top level (dev-e2e.ts reads it), TEAM_VM under team_vm. */
const SECTION: Readonly<Record<SnapshotVar, string | undefined>> = { CLOUD_FREESTYLE_SNAPSHOT: undefined, TEAM_VM_SNAPSHOT: "team_vm" }
export const WRANGLER = "backend/apps/api/wrangler.jsonc"

export interface HistoryEntry {
  readonly snapshot: string
  readonly snapshot_id: string
  readonly source_sha?: string
  readonly baked_at?: string
  readonly smoke?: { readonly result: string; readonly at?: string; readonly detail?: string }
  /** Per-channel snapshot names when a promotion bake copied the image (cmuxnp-stg-vmimg-..., cmuxnp-prod-vmimg-...). */
  readonly names?: Partial<Record<Channel, string>>
}

export interface Pointer {
  readonly snapshot: string
  readonly snapshot_id: string | null
}

export interface SmokeOutcome {
  readonly passed: boolean
  readonly created: ReadonlyArray<{ readonly id: string; readonly name: string }>
  readonly live: ReadonlyArray<{ readonly id: string; readonly name: string }>
  readonly detail: string
}

export interface PromoteDeps {
  readonly root: string
  readonly now: () => Date
  /** Runs the image smoke on fresh clones of exactly this snapshot id. The only provider call promote makes. */
  readonly smoke: (snapshotId: string, tag: string) => Promise<SmokeOutcome>
  readonly log: (line: string) => void
  readonly error: (line: string) => void
  readonly by: string
  readonly env: Record<string, string | undefined>
}

type Json = Record<string, unknown>
const channelPath = (root: string, channel: Channel) => join(root, "images/cmux-vm/channels", `${channel}.json`)
const readJson = (path: string): Json => JSON.parse(readFileSync(path, "utf8")) as Json
const writeJson = (path: string, value: Json) => writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`)

export const historyOf = (root: string): Array<HistoryEntry> => {
  const dev = readJson(channelPath(root, "dev"))
  return Array.isArray(dev.history) ? (dev.history as Array<HistoryEntry>) : []
}

const passed = (entry: HistoryEntry | undefined) => entry?.smoke?.result === "PASSED"

const varsLine = (lines: Array<string>, env: string): number => {
  const hits = lines.flatMap((l, i) => (l.includes(`"vars": { "ENVIRONMENT": "${env}"`) ? [i] : []))
  if (hits.length !== 1) throw new Error(`${WRANGLER}: expected one vars line for env ${env}, found ${hits.length}; set it by hand`)
  return hits[0]!
}

/** The value of vars.<name> in env <env> of wrangler.jsonc (each env keeps its vars on one line). */
export const readVar = (text: string, env: string, name: SnapshotVar): string | undefined => {
  const lines = text.split("\n")
  return lines[varsLine(lines, env)]!.match(new RegExp(`"${name}": "([^"]*)"`))?.[1]
}

/** Sets vars.<name> in env <env> (inserted after ENVIRONMENT when absent); verifies the result. */
export const setVar = (text: string, env: string, name: SnapshotVar, value: string): string => {
  if (!/^[a-z0-9-]+$/.test(value)) throw new Error(`refusing snapshot name ${JSON.stringify(value)}`)
  const lines = text.split("\n")
  const i = varsLine(lines, env)
  const line = lines[i]!
  const pattern = new RegExp(`"${name}": "[^"]*"`)
  lines[i] = pattern.test(line) ? line.replace(pattern, `"${name}": "${value}"`) : line.replace(`"ENVIRONMENT": "${env}", `, `"ENVIRONMENT": "${env}", "${name}": "${value}", `)
  const out = lines.join("\n")
  if (readVar(out, env, name) !== value) throw new Error(`${WRANGLER}: could not set ${name} for ${env}`)
  return out
}

const nameFor = (entry: HistoryEntry, channel: Channel) => entry.names?.[channel] ?? entry.snapshot

const getSection = (doc: Json, v: SnapshotVar): Json => (SECTION[v] ? ((doc[SECTION[v]!] as Json | undefined) ?? {}) : doc)

export const promote = async (argv: ReadonlyArray<string>, deps: PromoteDeps): Promise<number> => {
  const value = (flag: string) => (argv.includes(flag) ? argv[argv.indexOf(flag) + 1] : undefined)
  const channel = value("--channel")
  if (channel !== "dev" && channel !== "staging" && channel !== "production") {
    deps.error("--channel dev|staging|production is required")
    return 2
  }
  const v = (value("--var") ?? "CLOUD_FREESTYLE_SNAPSHOT") as SnapshotVar
  if (v !== "CLOUD_FREESTYLE_SNAPSHOT" && v !== "TEAM_VM_SNAPSHOT") {
    deps.error("--var must be CLOUD_FREESTYLE_SNAPSHOT or TEAM_VM_SNAPSHOT")
    return 2
  }
  const rollback = argv.includes("--rollback")
  const snapshotId = value("--snapshot")
  if (!rollback && !snapshotId?.startsWith("sh-")) {
    deps.error("--snapshot <sh-id> (or --rollback) is required")
    return 2
  }
  const env = ENV_OF[channel]
  const wranglerPath = join(deps.root, WRANGLER)
  const wranglerText = readFileSync(wranglerPath, "utf8")
  const serving = readVar(wranglerText, env, v)
  const history = historyOf(deps.root)
  const file = channelPath(deps.root, channel)
  const doc: Json = existsSync(file) ? readJson(file) : { schema: 1, env: channel }
  const section = getSection(doc, v)
  const current: Pointer | undefined = serving
    ? { snapshot: serving, snapshot_id: typeof section.snapshot_id === "string" && section.snapshot === serving ? section.snapshot_id : (history.find((h) => nameFor(h, channel) === serving)?.snapshot_id ?? null) }
    : undefined

  let next: Pointer
  let smokeRecord: Json | undefined
  if (rollback) {
    const previous = section.previous as Pointer | null | undefined
    if (!previous || typeof previous !== "object" || typeof previous.snapshot !== "string") {
      deps.error(`channels/${channel}.json has no previous ${v} to roll back to`)
      return 1
    }
    next = previous
  } else {
    const entry = history.find((h) => h.snapshot_id === snapshotId)
    if (!entry) {
      deps.error(`${snapshotId} is not in channels/dev.json history; only baked, recorded snapshots are promoted`)
      return 1
    }
    if (!passed(entry)) {
      deps.error(`${snapshotId} smoke is ${entry.smoke?.result ?? "not recorded"} in channels/dev.json history; promotion needs PASSED`)
      return 1
    }
    const name = nameFor(entry, channel)
    if (v === "CLOUD_FREESTYLE_SNAPSHOT" && !name.startsWith(CHANNEL_PREFIX[channel])) {
      deps.error(`${snapshotId} is named ${name}; the ${env} Worker boots only ${CHANNEL_PREFIX[channel]}* Cloud snapshots (bake it for ${channel} and record names.${channel})`)
      return 1
    }
    if (current?.snapshot === name) {
      deps.log(`${env} ${v} is already ${name}; nothing to do`)
      return 0
    }
    const tag = `promote${deps.now().toISOString().replace(/[-:T]/g, "").slice(0, 12)}`
    deps.log(`smoke ${snapshotId} on fresh cmuxnp-dev clones (tag ${tag})`)
    const outcome = await deps.smoke(snapshotId!, tag)
    const foreign = outcome.created.filter((c) => !c.name.startsWith("cmuxnp-dev-"))
    if (foreign.length) deps.error(`smoke created clones outside the cmuxnp-dev- prefix: ${foreign.map((c) => `${c.id} ${c.name}`).join(", ")}`)
    if (outcome.live.length) deps.error(`smoke left clones running: ${outcome.live.map((c) => `${c.id} ${c.name}`).join(", ")}; delete them by exact id`)
    if (!outcome.passed) deps.error(`smoke FAILED for ${snapshotId}: ${outcome.detail}`)
    if (!outcome.passed || outcome.live.length || foreign.length) return 1
    next = { snapshot: name, snapshot_id: entry.snapshot_id }
    smokeRecord = { result: "PASSED", at: deps.now().toISOString(), clones: outcome.created.map((c) => c.id), detail: outcome.detail }
  }

  writeFileSync(wranglerPath, setVar(wranglerText, env, v, next.snapshot))
  const written: Json = { ...section }
  if (typeof section.previous === "string") written.previous_notes = section.previous
  Object.assign(written, {
    var: v,
    snapshot: next.snapshot,
    snapshot_id: next.snapshot_id,
    previous: current ?? null,
    promoted_at: deps.now().toISOString(),
    promoted_by: deps.by,
    promotion: rollback ? { rollback: true } : { smoke: smokeRecord },
  })
  writeJson(file, SECTION[v] ? { ...doc, [SECTION[v]!]: written } : { ...doc, ...written })
  const worker = WORKER_OF[channel]
  const version = value("--worker-version")
  const undo = [
    `bun images/cmux-vm/promote.ts --channel ${channel} --var ${v} --rollback (restores ${current?.snapshot ?? "no value"}), then deploy ${env}`,
    `after the deploy, at once: wrangler rollback ${version ?? "<serving version before the deploy, printed by worker-release.ts previous>"} --name ${worker}`,
  ]
  const receipt = {
    action: "promote" as const,
    what: `${rollback ? "roll back" : "promote"} ${env} ${v} ${current?.snapshot ?? "(unset)"} -> ${next.snapshot} (${next.snapshot_id ?? "id unknown"}); new VMs only, after the next ${env} deploy`,
    tree: "images",
    target: env,
    result: "pass" as const,
    at: deps.now().toISOString(),
    before: current ? [`${current.snapshot} ${current.snapshot_id ?? ""}`.trim()] : [],
    after: [`${next.snapshot} ${next.snapshot_id ?? ""}`.trim()],
    rollback: undo,
    runId: runIdOf(deps.env),
    by: deps.by,
  }
  const receiptFile = writeReceipt(receiptsDir(deps.env), receipt)
  deps.log(`${WRANGLER}: env.${env} ${v} = ${next.snapshot}; channels/${channel}.json updated`)
  deps.log(`bd-summary: ${summaryLine(receipt, receiptFile)}`)
  for (const step of undo) deps.log(`rollback: ${step}`)
  return 0
}

/** Reads the smoke's ledger (id, kind, name, time, status): created clones and those never recorded deleted. */
export const ledgerClones = (tsv: string) => {
  const state = new Map<string, { id: string; name: string; status: string }>()
  for (const line of tsv.split("\n")) {
    const [id, kind, name, , status] = line.split("\t")
    if (!id || kind !== "vm" || !name) continue
    state.set(id, { id, name, status: status ?? "" })
  }
  const created = [...state.values()].map(({ id, name }) => ({ id, name }))
  const live = [...state.values()].filter((r) => r.status !== "deleted").map(({ id, name }) => ({ id, name }))
  return { created, live }
}

/** The real smoke: `bun ../images/cmux-vm/smoke.ts` from web/ (Freestyle key from FREESTYLE_API_KEY or FREESTYLE_API_KEY_FILE). */
export const runImageSmoke = async (snapshotId: string, tag: string): Promise<SmokeOutcome> => {
  const out = mkdtempSync(join(tmpdir(), `cmux-promote-${tag}-`))
  const run = spawnSync("bun", ["../images/cmux-vm/smoke.ts", "--snapshot", snapshotId, "--tag", tag, "--clones", "2", "--out-dir", out], {
    cwd: join(REPO_ROOT, "web"),
    stdio: ["ignore", "inherit", "inherit"],
    env: process.env,
  })
  const ledger = existsSync(join(out, "resources.tsv")) ? ledgerClones(readFileSync(join(out, "resources.tsv"), "utf8")) : { created: [], live: [] }
  const reportFile = join(out, `smoke-${tag}.json`)
  const report = existsSync(reportFile) ? (JSON.parse(readFileSync(reportFile, "utf8")) as { passed?: boolean; error?: string }) : undefined
  return { passed: run.status === 0 && report?.passed === true, ...ledger, detail: `exit ${run.status}; report ${reportFile}${report?.error ? `; ${report.error}` : ""}` }
}
