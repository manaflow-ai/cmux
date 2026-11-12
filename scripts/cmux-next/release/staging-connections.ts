/**
 * Live connections on cmux-prod/staging through PlanetScale (`pscale branch connections`), which runs over a
 * reserved administrative connection and so still answers when the server is full and no SQL login gets in
 * (the deploy gate's 53300 "remaining connection slots are reserved for roles with the SUPERUSER attribute").
 * cmux-vm.yml job pscale-connections-staging (action db-connections-staging on feat-cmux-next), with the
 * PlanetScale service token of cmux-vm-production, on branch staging only, never main.
 *
 *   bun staging-connections.ts show
 *   bun staging-connections.ts free [--idle-seconds 120]
 *
 * show: the connections grouped by role, application and state, with the longest duration of each group.
 * Never query text or client addresses.
 * free: show, then kill each connection that is idle (no open transaction) for longer than --idle-seconds and
 * belongs to one of our roles: the Worker's (cmux-vm-worker) and the release rails' temporary ones
 * (cmux-vm-stg-*). Every other role's connections are listed and never touched. `pscale` checks that a
 * connection is still the one it listed (by its backend start) before it ends it.
 */
import { appendFileSync } from "node:fs"
import { must, type RoleJson } from "./branches.ts"
import { TREES } from "./trees.ts"

const tree = TREES["cmux-vm"]
const DB = tree.database
const BRANCH = tree.branches.staging
const OUR_ROLE_NAME = (name: string) => name === tree.workerRole || name.startsWith("cmux-vm-stg-")

export interface LiveConnection {
  readonly connection_id?: string | null
  readonly pid?: number
  readonly state?: string | null
  readonly duration_ms?: number | null
  readonly username?: string | null
  readonly application_name?: string | null
  readonly transaction_id?: string | null
  readonly instance_role?: string | null
}

/** The connection rows of `show --format json`, wherever the envelope keeps them. */
export const rowsOf = (json: unknown): Array<LiveConnection> => {
  const looksLikeRows = (v: unknown): v is Array<LiveConnection> =>
    Array.isArray(v) && v.every((r) => typeof r === "object" && r !== null && ("pid" in r || "connection_id" in r))
  if (looksLikeRows(json)) return json
  if (typeof json === "object" && json !== null) {
    for (const value of Object.values(json)) if (looksLikeRows(value) && value.length) return value
    for (const value of Object.values(json)) if (looksLikeRows(value)) return value
  }
  return []
}

/** The SQL user without PlanetScale's `.<branch id>` suffix. */
export const bareUser = (username: string) => username.replace(/\.[a-z0-9]{8,16}$/, "")

export interface GroupRow {
  readonly username: string
  readonly app: string
  readonly state: string
  readonly n: number
  readonly maxSeconds: number
}

export const groupsOf = (rows: ReadonlyArray<LiveConnection>): Array<GroupRow> => {
  const groups = new Map<string, { username: string; app: string; state: string; n: number; maxSeconds: number }>()
  for (const r of rows) {
    const username = bareUser(r.username || "?")
    const app = r.application_name || "-"
    const state = r.state || "?"
    const key = `${username}\u0000${app}\u0000${state}`
    const g = groups.get(key) ?? { username, app, state, n: 0, maxSeconds: 0 }
    g.n += 1
    g.maxSeconds = Math.max(g.maxSeconds, Math.round((r.duration_ms ?? 0) / 1000))
    groups.set(key, g)
  }
  return [...groups.values()].sort((a, b) => b.n - a.n || a.username.localeCompare(b.username))
}

/** Ours, idle with no open transaction, idle longer than `idleSeconds`. */
export const killable = (rows: ReadonlyArray<LiveConnection>, ours: ReadonlySet<string>, idleSeconds: number): Array<LiveConnection> =>
  rows.filter(
    (r) =>
      !!r.connection_id &&
      r.state === "idle" &&
      !r.transaction_id &&
      (r.duration_ms ?? 0) > idleSeconds * 1000 &&
      ours.has(bareUser(r.username || "")),
  )

const summary = (lines: Array<string>) => {
  const path = process.env.GITHUB_STEP_SUMMARY
  if (path) appendFileSync(path, `${lines.join("\n")}\n`)
}

export const run = async (argv: Array<string>, log = (l: string) => console.log(l)): Promise<number> => {
  const [command] = argv
  const i = argv.indexOf("--idle-seconds")
  const idleSeconds = i >= 0 ? Number(argv[i + 1]) : 120
  if ((command !== "show" && command !== "free") || !Number.isInteger(idleSeconds) || idleSeconds < 30) {
    console.error("usage: staging-connections.ts show|free [--idle-seconds N>=30]")
    return 2
  }
  if (BRANCH !== "staging") throw new Error("staging-connections.ts runs on branch staging only")
  const rows = rowsOf(JSON.parse(await must(["branch", "connections", "show", DB, BRANCH, "--role", "primary"])))
  const groups = groupsOf(rows)
  const lines = [
    `### ${DB}/${BRANCH} live connections (pscale): ${rows.length}`,
    "",
    "| role | application | state | connections | longest (s) |",
    "|---|---|---|---:|---:|",
    ...groups.map((g) => `| ${g.username} | ${g.app} | ${g.state} | ${g.n} | ${g.maxSeconds} |`),
  ]
  for (const l of lines) log(l)
  if (command === "free") {
    const roles = JSON.parse(await must(["role", "list", DB, BRANCH])) as Array<RoleJson>
    const ours = new Set(roles.filter((r) => r.name && r.username && OUR_ROLE_NAME(r.name)).map((r) => bareUser(r.username as string)))
    const targets = killable(rows, ours, idleSeconds)
    let ended = 0
    for (const t of targets) {
      try {
        await must(["branch", "connections", "kill", DB, BRANCH, String(t.connection_id)])
        ended += 1
      } catch (e) {
        log(`could not end connection ${t.connection_id}: ${String((e as Error).message).slice(0, 160)}`)
      }
    }
    const line = `ended ${ended} of ${targets.length} idle connection(s) (over ${idleSeconds} s, no open transaction) of our roles (${[...ours].join(", ") || "none found"}); no other role's touched`
    log(line)
    lines.push("", line)
  }
  summary(lines)
  return 0
}

if (import.meta.main) {
  try {
    process.exit(await run(process.argv.slice(2)))
  } catch (e) {
    console.error(`::error title=staging-connections::${String((e as Error).message).slice(0, 300)}`)
    process.exit(1)
  }
}
