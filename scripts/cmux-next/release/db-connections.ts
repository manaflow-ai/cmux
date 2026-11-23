/**
 * Who holds a cmux_vm database's connection slots, and freeing our own idle ones (cmux-vm.yml action
 * db-connections-staging and the deploy-staging step before the ordering gate). The gate's 53300 "remaining
 * connection slots are reserved for roles with the SUPERUSER attribute" means the server is full.
 *
 *   bun db-connections.ts report --url-env CMUX_VM_DATABASE_URL
 *   bun db-connections.ts free   --url-env CMUX_VM_DATABASE_URL [--idle-seconds 120] [--wait-seconds 0]
 *
 * report: max_connections, the reserved slots and the timeouts, then the client backends grouped by role,
 * application and state, with the longest idle and the oldest age of each group; a warning at 80 % used.
 * free: report, then end only backends of the URL's own role (current_user) that sit idle, not in a
 * transaction, for longer than --idle-seconds (default 120). Never another role's, never an active one,
 * never one inside a transaction. For the Worker's role these are Hyperdrive's pooled origin connections,
 * which Hyperdrive opens again on demand.
 *
 * It connects direct first and, when the server is full, through the branch's PgBouncer (port 6432),
 * which may still hold a free server connection. With --wait-seconds N it tries again every 15 s for up to N s
 * while the server stays full (the db-connections-staging action waits that way after it restarts the Worker's
 * Hyperdrive pool: the old pool drained in minutes, not seconds, on 2026-11-09). When no login gets in at all,
 * restarting that pool is the way to free the slots: a full server reserves the rest for superusers, which
 * no role of ours is. It prints no URL, password, query text or client address.
 */
import { appendFileSync } from "node:fs"

interface Client {
  query<T>(text: string, params?: Array<unknown>): Promise<Array<T>>
  end(): Promise<void>
}

const APP = "cmux-db-connections"
const WARN_RATIO = 0.8

const connectOnce = async (url: string): Promise<Client> => {
  const { default: pg } = await import("pg")
  const client = new pg.Client({ connectionString: url, application_name: APP, connectionTimeoutMillis: 10_000, query_timeout: 15_000 })
  // query_timeout is client side: PgBouncer refuses a statement_timeout startup parameter (08P01).
  client.on("error", () => {})
  await client.connect()
  return { query: async <T>(text: string, params?: Array<unknown>) => (await client.query(text, params)).rows as Array<T>, end: () => client.end() }
}

const code = (e: unknown) => String((e as { code?: unknown } | null)?.code ?? "")
/** An error's message with any `scheme://user:password@` cut out: a malformed URL's parse error quotes it. */
export const safeMessage = (e: unknown, max = 160) =>
  String((e as Error | null)?.message ?? e).replace(/[a-z][a-z0-9+.-]*:\/\/\S*@/gi, "<redacted>@").slice(0, max)
export const isFull = (e: unknown) => ["53300", "57P03"].includes(code(e))

/** The same URL on PgBouncer's port (PlanetScale runs one next to every primary on 6432). */
export const bouncerUrl = (url: string): string => {
  const u = new URL(url)
  u.port = "6432"
  return u.toString()
}

/** Direct, then PgBouncer when the server answers full. Returns the route that worked. */
export const connect = async (url: string, open: (url: string) => Promise<Client> = connectOnce): Promise<{ client: Client; route: string }> => {
  try {
    return { client: await open(url), route: "direct" }
  } catch (e) {
    if (!isFull(e)) throw e
    console.log(`direct connection refused: ${code(e)} (${safeMessage(e, 120)}); trying PgBouncer (6432)`)
    return { client: await open(bouncerUrl(url)), route: "pgbouncer" }
  }
}

/** connect, tried again every `everyMs` while the server is full, until `waitMs` of wall time has passed
 * (the attempts count too: each may wait out its connect timeout). */
export const connectWaiting = async (
  url: string,
  waitMs: number,
  open?: (url: string) => Promise<Client>,
  sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms)),
  everyMs = 15_000,
  now: () => number = Date.now,
): Promise<{ client: Client; route: string }> => {
  const deadline = now() + waitMs
  for (;;) {
    try {
      return await connect(url, open)
    } catch (e) {
      if (!isFull(e) || now() + everyMs > deadline) throw e
      console.log(`still full, ${Math.round((deadline - now()) / 1000)} s left; trying again in ${everyMs / 1000} s`)
      await sleep(everyMs)
    }
  }
}

export interface Group {
  usename: string
  app: string
  state: string
  n: number
  max_idle_s: number | null
  max_age_s: number | null
}

const SETTINGS_SQL = `select name, setting from pg_settings where name in
  ('max_connections', 'superuser_reserved_connections', 'reserved_connections',
   'idle_session_timeout', 'idle_in_transaction_session_timeout', 'statement_timeout') order by name`

// state, state_change and backend_start read null for other roles' sessions without pg_read_all_stats.
const GROUPS_SQL = `select coalesce(usename, '?') as usename, coalesce(nullif(application_name, ''), '-') as app,
  coalesce(state, '(hidden)') as state, count(*)::int as n,
  max(extract(epoch from now() - state_change))::int as max_idle_s,
  max(extract(epoch from now() - backend_start))::int as max_age_s
  from pg_stat_activity where backend_type = 'client backend'
  group by 1, 2, 3 order by n desc, usename, app, state`

const FREE_SQL = `select usename, count(*) filter (where ended)::int as ended, count(*)::int as matched from (
  select usename, pg_terminate_backend(pid) as ended from pg_stat_activity
  where backend_type = 'client backend' and usename = current_user and pid <> pg_backend_pid()
    and state = 'idle' and state_change < now() - make_interval(secs => $1::int)) t group by usename`

export const table = (groups: ReadonlyArray<Group>): Array<string> => [
  "| role | application | state | backends | longest in state (s) | oldest (s) |",
  "|---|---|---|---:|---:|---:|",
  ...groups.map((g) => `| ${g.usename} | ${g.app} | ${g.state} | ${g.n} | ${g.max_idle_s ?? "?"} | ${g.max_age_s ?? "?"} |`),
]

export const usageLine = (used: number, max: number, reserved: number) => {
  const open = max - reserved
  const pct = open > 0 ? Math.round((used / open) * 100) : 100
  return { line: `${used} of ${open} open slots used (${pct} %; max_connections ${max}, ${reserved} reserved)`, warn: used >= open * WARN_RATIO }
}

const summary = (lines: Array<string>) => {
  const path = process.env.GITHUB_STEP_SUMMARY
  if (path) appendFileSync(path, `${lines.join("\n")}\n`)
}

const arg = (argv: Array<string>, name: string) => {
  const i = argv.indexOf(name)
  return i >= 0 ? argv[i + 1] : undefined
}

export const run = async (argv: Array<string>, open?: (url: string) => Promise<Client>): Promise<number> => {
  const [command] = argv
  const urlEnv = arg(argv, "--url-env")
  const idleSeconds = Number(arg(argv, "--idle-seconds") ?? 120)
  const waitSeconds = Number(arg(argv, "--wait-seconds") ?? 0)
  if ((command !== "report" && command !== "free") || !urlEnv || !Number.isInteger(idleSeconds) || idleSeconds < 30 || !Number.isInteger(waitSeconds) || waitSeconds < 0 || waitSeconds > 900) {
    console.error("usage: db-connections.ts report|free --url-env NAME [--idle-seconds N>=30] [--wait-seconds 0..900]")
    return 2
  }
  const url = process.env[urlEnv]
  if (!url) {
    console.error(`${urlEnv} is not set`)
    return 2
  }
  let client: Client
  let route: string
  try {
    ;({ client, route } = await connectWaiting(url, waitSeconds * 1000, open))
  } catch (e) {
    const line = `cannot read the database's connections: ${code(e) || "error"} (${safeMessage(e)})`
    console.log(`::warning title=db-connections::${line}`)
    summary([`### Database connections`, "", line])
    return 1
  }
  try {
    const settings = Object.fromEntries((await client.query<{ name: string; setting: string }>(SETTINGS_SQL)).map((r) => [r.name, r.setting]))
    const groups = await client.query<Group>(GROUPS_SQL)
    const used = groups.reduce((s, g) => s + g.n, 0)
    const max = Number(settings.max_connections ?? 0)
    const reserved = Number(settings.superuser_reserved_connections ?? 0) + Number(settings.reserved_connections ?? 0)
    const usage = usageLine(used, max, reserved)
    const lines = [
      `### Database connections (${route})`,
      "",
      usage.line,
      "",
      `timeouts: idle_session ${settings.idle_session_timeout ?? "?"}, idle_in_transaction_session ${settings.idle_in_transaction_session_timeout ?? "?"}, statement ${settings.statement_timeout ?? "?"}`,
      "",
      ...table(groups),
    ]
    for (const l of lines) console.log(l)
    if (usage.warn) console.log(`::warning title=db-connections::${usage.line}`)
    if (command === "free") {
      const freed = await client.query<{ usename: string; ended: number; matched: number }>(FREE_SQL, [idleSeconds])
      const line = freed.length
        ? freed.map((f) => `ended ${f.ended} of ${f.matched} idle backend(s) of ${f.usename} idle over ${idleSeconds} s`).join("; ")
        : `no backend of this role idle over ${idleSeconds} s`
      console.log(line)
      lines.push("", line)
    }
    summary(lines)
    return 0
  } finally {
    await client.end().catch(() => {})
  }
}

if (import.meta.main) process.exit(await run(process.argv.slice(2)))
