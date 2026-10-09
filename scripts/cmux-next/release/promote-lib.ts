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
  /** The per-channel copy a promotion bake made (cmuxnp-stg-vmimg-..., cmuxnp-prod-vmimg-...), with its own id. */
  readonly names?: Partial<Record<Channel, { readonly snapshot: string; readonly snapshot_id: string }>>
  /** Fresh-clone smokes promote ran, per channel copy. */
  readonly promotion_smokes?: ReadonlyArray<{ channel: Channel; snapshot_id: string; result: string; at: string; clones: ReadonlyArray<string> }>
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
  /** Runs the image smoke on fresh clones of exactly this snapshot id. */
  readonly smoke: (snapshotId: string, tag: string) => Promise<SmokeOutcome>
  /** The id a snapshot name (slug) resolves to now, or undefined. Read-only; promote makes no other provider call. */
  readonly resolve: (name: string) => Promise<string | undefined>
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

/** The snapshot a channel boots for a history entry: the entry itself for dev, its recorded per-channel copy otherwise. */
const pointerFor = (entry: HistoryEntry, channel: Channel): Pointer | undefined =>
  channel === "dev" ? { snapshot: entry.snapshot, snapshot_id: entry.snapshot_id } : entry.names?.[channel]

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
    ? { snapshot: serving, snapshot_id: typeof section.snapshot_id === "string" && section.snapshot === serving ? section.snapshot_id : (history.map((h) => pointerFor(h, channel)).find((p) => p?.snapshot === serving)?.snapshot_id ?? null) }
    : undefined

  let next: Pointer
  let smokeRecord: Json | undefined
  /** The name must resolve to the recorded id right now (a re-baked slug would boot something else). */
  const resolves = async (p: Pointer): Promise<boolean> => {
    if (!p.snapshot_id) return true
    const id = await deps.resolve(p.snapshot)
    if (id === p.snapshot_id) return true
    deps.error(`${p.snapshot} resolves to ${id ?? "nothing"}, not the recorded ${p.snapshot_id}; refusing`)
    return false
  }
  if (rollback) {
    const previous = section.previous as Pointer | null | undefined
    if (!previous || typeof previous !== "object" || typeof previous.snapshot !== "string") {
      deps.error(`channels/${channel}.json has no previous ${v} to roll back to`)
      return 1
    }
    if (!(await resolves(previous))) return 1
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
    const pointer = pointerFor(entry, channel)
    if (!pointer) {
      deps.error(`${snapshotId} has no ${channel} copy recorded (names.${channel} with its snapshot and snapshot_id); the ${env} Worker boots only ${CHANNEL_PREFIX[channel]}* Cloud snapshots: bake it for ${channel} first`)
      return 1
    }
    if (v === "CLOUD_FREESTYLE_SNAPSHOT" && !pointer.snapshot.startsWith(CHANNEL_PREFIX[channel])) {
      deps.error(`${snapshotId} is named ${pointer.snapshot}; the ${env} Worker boots only ${CHANNEL_PREFIX[channel]}* Cloud snapshots (bake it for ${channel} and record names.${channel})`)
      return 1
    }
    if (channel === "production") {
      // cmux-old shares the Freestyle production account: production needs the compat receipts (compat.ts).
      const { compatProblems } = await import("./compat.ts")
      const compat = compatProblems(receiptsDir(deps.env), `image:${v}:${entry.snapshot_id}`, "production", deps.now().getTime())
      if (compat.length) {
        for (const c of compat) deps.error(c)
        return 1
      }
    }
    if (current?.snapshot === pointer.snapshot) {
      deps.log(`${env} ${v} is already ${pointer.snapshot}; nothing to do`)
      return 0
    }
    if (!(await resolves(pointer))) return 1
    const tag = `promote${deps.now().toISOString().replace(/[-:T]/g, "").slice(0, 12)}`
    deps.log(`smoke ${pointer.snapshot_id} (${pointer.snapshot}) on fresh cmuxnp-dev clones (tag ${tag})`)
    const outcome = await deps.smoke(pointer.snapshot_id!, tag)
    const foreign = outcome.created.filter((c) => !c.name.startsWith("cmuxnp-dev-"))
    if (foreign.length) deps.error(`smoke created clones outside the cmuxnp-dev- prefix: ${foreign.map((c) => `${c.id} ${c.name}`).join(", ")}`)
    if (outcome.live.length) deps.error(`smoke left clones running: ${outcome.live.map((c) => `${c.id} ${c.name}`).join(", ")}; delete them by exact id`)
    if (!outcome.passed) deps.error(`smoke FAILED for ${pointer.snapshot_id}: ${outcome.detail}`)
    const ok = outcome.passed && !outcome.live.length && !foreign.length
    // The fresh-clone result goes into the bake history, pass or fail.
    const devPath = channelPath(deps.root, "dev")
    const dev = readJson(devPath)
    dev.history = (dev.history as Array<HistoryEntry>).map((h) =>
      h.snapshot_id === entry.snapshot_id ? { ...h, promotion_smokes: [...(h.promotion_smokes ?? []), { channel, snapshot_id: pointer.snapshot_id!, result: ok ? "PASSED" : "FAILED", at: deps.now().toISOString(), clones: outcome.created.map((c) => c.id) }] } : h,
    )
    writeJson(devPath, dev)
    if (!ok) return 1
    next = pointer
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
  const latest = existsSync(file) ? readJson(file) : doc // dev.json may have gained a promotion_smokes entry
  writeJson(file, SECTION[v] ? { ...latest, [SECTION[v]!]: written } : { ...latest, ...written })
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

/**
 * The id a Freestyle snapshot slug resolves to (`GET /v5/snapshots/{slug}`), or undefined on 404.
 * Key from FREESTYLE_API_KEY or FREESTYLE_API_KEY_FILE (read here, never printed).
 */
export const freestyleResolve = async (name: string, env: Record<string, string | undefined> = process.env): Promise<string | undefined> => {
  const key = env.FREESTYLE_API_KEY || (env.FREESTYLE_API_KEY_FILE ? readFileSync(env.FREESTYLE_API_KEY_FILE, "utf8").trim() : "")
  if (!key) throw new Error("set FREESTYLE_API_KEY or FREESTYLE_API_KEY_FILE to resolve snapshot names")
  const base = env.FREESTYLE_API_URL?.trim() || "https://api.freestyle.sh"
  const response = await fetch(`${base}/v5/snapshots/${encodeURIComponent(name)}`, { headers: { authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(20_000) })
  if (response.status === 404) return undefined
  if (!response.ok) throw new Error(`Freestyle GET /v5/snapshots/${name}: HTTP ${response.status}`)
  return ((await response.json()) as { id?: string }).id
}

/** The outcome of a smoke run from its out dir: a run without a ledger never passes (its clones are unknown). */
export const readSmokeOutcome = (out: string, status: number | null, tag: string): SmokeOutcome => {
  const ledgerFile = join(out, "resources.tsv")
  if (!existsSync(ledgerFile)) return { passed: false, created: [], live: [], detail: `exit ${status}; no ledger at ${ledgerFile}: the smoke's clones are unknown, look for cmuxnp-dev-vmimg-${tag}-smoke-* by hand` }
  const ledger = ledgerClones(readFileSync(ledgerFile, "utf8"))
  const reportFile = join(out, `smoke-${tag}.json`)
  const report = existsSync(reportFile) ? (JSON.parse(readFileSync(reportFile, "utf8")) as { passed?: boolean; error?: string }) : undefined
  return { passed: status === 0 && report?.passed === true, ...ledger, detail: `exit ${status}; report ${reportFile}${report?.error ? `; ${report.error}` : ""}` }
}

/** The real smoke: `bun ../images/cmux-vm/smoke.ts` from web/ (Freestyle key from FREESTYLE_API_KEY or FREESTYLE_API_KEY_FILE). */
export const runImageSmoke = async (snapshotId: string, tag: string): Promise<SmokeOutcome> => {
  const out = mkdtempSync(join(tmpdir(), `cmux-promote-${tag}-`))
  const run = spawnSync("bun", ["../images/cmux-vm/smoke.ts", "--snapshot", snapshotId, "--tag", tag, "--clones", "2", "--out-dir", out], {
    cwd: join(REPO_ROOT, "web"),
    stdio: ["ignore", "inherit", "inherit"],
    env: process.env,
  })
  return readSmokeOutcome(out, run.status, tag)
}
