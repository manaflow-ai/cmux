/**
 * Post-deploy rail for a Cloudflare Worker (plans/cmux-next/release-rails.md).
 *
 *   bun worker-release.ts previous --worker NAME [--wrangler BIN] [--out FILE] [--allow-first-deploy]
 *       Prints (and writes to FILE) the version id serving 100% now. Run BEFORE the deploy.
 *       Refuses (exit 1) when wrangler cannot name it, unless --allow-first-deploy.
 *   bun worker-release.ts verify --worker NAME --url BASE --routes FILE --previous-file FILE
 *       [--changed-since REV] [--source-dir DIR] [--wrangler BIN] [--attempts N] [--interval-ms MS]
 *       Smokes every route of FILE without `sources`, and each route whose
 *       `sources` match a file changed since REV (all routes when REV is
 *       unknown). On red: `wrangler rollback <previous> --name NAME -y`, smoke
 *       the always-routes again, and exit 1 either way (the job fails).
 *   bun worker-release.ts vars --worker NAME --config wrangler.jsonc --env ENV [--wrangler BIN]
 *       Run BEFORE a deploy that must ship code only (development: no secrets are sent). Compares
 *       the config's env.ENV.vars with the plain-text and JSON vars of the version serving 100%
 *       (`wrangler versions view --json`; secrets and other bindings are not compared) and
 *       refuses (exit 1) on any added, removed or changed var, naming the vars, never their values.
 *
 * Routes file: {"routes":[{"name","method","path","expect":[status...],"body"?,
 * "bodyIncludes"?,"sources"?:[glob relative to --source-dir],"expectByWorker"?:{worker:[status...]},"why"?}]}.
 * A route passes when one of `attempts` tries (default 6, `interval-ms` apart,
 * default 5000) answers an expected status (and body text): new versions take
 * seconds to reach every location.
 */
import { execFileSync, spawnSync } from "node:child_process"
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { relative, resolve } from "node:path"

export interface Route {
  readonly name: string
  readonly method: string
  readonly path: string
  readonly expect: ReadonlyArray<number>
  /** Per Worker name: statuses that replace `expect` for that Worker (e.g. a production-only known state). */
  readonly expectByWorker?: Readonly<Record<string, ReadonlyArray<number>>>
  readonly body?: string
  readonly bodyIncludes?: string
  readonly sources?: ReadonlyArray<string>
  readonly why?: string
}

export interface RouteResult {
  readonly route: Route
  readonly ok: boolean
  readonly last: string
}

export const globRegex = (glob: string) =>
  new RegExp(`^${glob.split("**").map((part) => part.split("*").map((p) => p.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join("[^/]*")).join(".*")}$`)

/** The routes as `worker` must answer them: a route's `expectByWorker[worker]`, when set, replaces `expect`. */
export const routesFor = (routes: ReadonlyArray<Route>, worker: string): Array<Route> =>
  routes.map((r) => {
    const own = r.expectByWorker?.[worker]
    return own === undefined ? r : { ...r, expect: own }
  })

/** Routes to smoke: those without sources always; the rest when a changed file matches (all, when `changed` is undefined). */
export const selectRoutes = (routes: ReadonlyArray<Route>, changed: ReadonlyArray<string> | undefined): Array<Route> =>
  routes.filter((r) => !r.sources || changed === undefined || r.sources.some((g) => changed.some((f) => globRegex(g).test(f) || f.startsWith(g.endsWith("/") ? g : `${g}/`))))

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

export const smoke = async (base: string, routes: ReadonlyArray<Route>, attempts = 6, intervalMs = 5000): Promise<Array<RouteResult>> => {
  const results: Array<RouteResult> = []
  for (const route of routes) {
    let last = "not tried"
    let ok = false
    for (let i = 0; i < attempts && !ok; i++) {
      if (i > 0) await sleep(intervalMs)
      try {
        const response = await fetch(new URL(route.path, base), {
          method: route.method,
          ...(route.body !== undefined ? { body: route.body, headers: { "content-type": "application/json" } } : {}),
          signal: AbortSignal.timeout(15_000),
          redirect: "manual",
        })
        const text = await response.text()
        ok = route.expect.includes(response.status) && (route.bodyIncludes === undefined || text.includes(route.bodyIncludes))
        last = `HTTP ${response.status}${route.bodyIncludes !== undefined && !text.includes(route.bodyIncludes) ? ` (body lacks ${JSON.stringify(route.bodyIncludes)})` : ""}`
      } catch (e) {
        last = (e as Error).message
      }
    }
    results.push({ route, ok, last })
  }
  return results
}

/** The version serving 100% of traffic, from `wrangler deployments status --json`. */
export const currentVersion = (statusJson: string): string | undefined => {
  type Deployment = { created_on?: string; versions?: Array<{ version_id?: string; percentage?: number }> }
  const status = JSON.parse(statusJson) as Deployment | Array<Deployment>
  // A list is ordered by nothing we rely on: the newest deployment by created_on is the serving one.
  const deployment = Array.isArray(status) ? [...status].sort((a, b) => Date.parse(b.created_on ?? "") - Date.parse(a.created_on ?? ""))[0] : status
  const versions = deployment?.versions ?? []
  if (versions.length !== 1 || (versions[0]?.percentage ?? 100) !== 100) {
    if (versions.length > 1) throw new Error(`a gradual deployment is in progress (${versions.length} versions); finish or roll it back by hand first`)
    return undefined
  }
  return versions[0]?.version_id
}

/** JSONC to JSON: drops comments and trailing commas outside strings. */
export const stripJsonc = (text: string): string => {
  let noComments = ""
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!
    if (c === '"') {
      let j = i + 1
      while (j < text.length && text[j] !== '"') j += text[j] === "\\" ? 2 : 1
      noComments += text.slice(i, j + 1)
      i = j
    } else if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++
      noComments += "\n"
    } else if (c === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2)
      i = end < 0 ? text.length : end + 1
    } else noComments += c
  }
  let out = ""
  for (let i = 0; i < noComments.length; i++) {
    const c = noComments[i]!
    if (c === '"') {
      let j = i + 1
      while (j < noComments.length && noComments[j] !== '"') j += noComments[j] === "\\" ? 2 : 1
      out += noComments.slice(i, j + 1)
      i = j
    } else if (c === ",") {
      let k = i + 1
      while (k < noComments.length && /\s/.test(noComments[k]!)) k++
      if (noComments[k] !== "}" && noComments[k] !== "]") out += c
    } else out += c
  }
  return out
}

/** The `vars` of env `env` in a wrangler JSONC config ({} when the env has none). */
export const envVars = (jsonc: string, env: string): Record<string, unknown> => {
  const doc = JSON.parse(stripJsonc(jsonc)) as { env?: Record<string, { vars?: Record<string, unknown> }> }
  const section = doc.env?.[env]
  if (!section) throw new Error(`no env ${env} in the config`)
  return section.vars ?? {}
}

export interface Binding {
  readonly type?: string
  readonly name?: string
  readonly text?: unknown
  readonly json?: unknown
}

/** JSON with sorted object keys, so two equal values always print the same. */
const canonical = (v: unknown): string =>
  v !== null && typeof v === "object"
    ? Array.isArray(v)
      ? `[${v.map(canonical).join(",")}]`
      : `{${Object.keys(v as object).sort().map((k) => `${JSON.stringify(k)}:${canonical((v as Record<string, unknown>)[k])}`).join(",")}}`
    : JSON.stringify(v)

/**
 * The vars a deploy of `config` would change on a version with `bindings`: wrangler uploads a
 * string var as `plain_text` and any other value as `json`; secrets and other bindings are ignored.
 */
export const diffVars = (config: Record<string, unknown>, bindings: ReadonlyArray<Binding>) => {
  const deployed = new Map<string, string>()
  for (const b of bindings) {
    if (typeof b.name !== "string") continue
    if (b.type === "plain_text") deployed.set(b.name, canonical(String(b.text ?? "")))
    else if (b.type === "json") deployed.set(b.name, `json:${canonical(b.json)}`)
  }
  const want = new Map(Object.entries(config).map(([k, v]) => [k, typeof v === "string" ? canonical(v) : `json:${canonical(v)}`] as const))
  const added = [...want.keys()].filter((k) => !deployed.has(k)).sort()
  const removed = [...deployed.keys()].filter((k) => !want.has(k)).sort()
  const changed = [...want.keys()].filter((k) => deployed.has(k) && deployed.get(k) !== want.get(k)).sort()
  return { added, removed, changed, compared: want.size }
}

/** The JSON object in wrangler's output (a banner or warning line may precede it). */
const parseJsonOut = (out: string): unknown => {
  try {
    return JSON.parse(out)
  } catch {
    const at = out.indexOf("{")
    return at < 0 ? undefined : JSON.parse(out.slice(at))
  }
}

const wranglerArgs = (bin: string, args: ReadonlyArray<string>) => (bin.endsWith(".ts") || bin.endsWith(".js") ? { cmd: "bun", args: [bin, ...args] } : { cmd: bin, args: [...args] })

const runWrangler = (bin: string, args: ReadonlyArray<string>) => {
  const { cmd, args: full } = wranglerArgs(bin, args)
  return spawnSync(cmd, full, { encoding: "utf8", env: process.env, maxBuffer: 16 << 20 })
}

const changedFiles = (rev: string | undefined, sourceDir: string): Array<string> | undefined => {
  if (!rev || /^0+$/.test(rev)) return undefined
  try {
    const top = execFileSync("git", ["-C", sourceDir, "rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim()
    const files = execFileSync("git", ["-C", top, "diff", "--name-only", `${rev}`, "HEAD"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).split("\n").filter(Boolean)
    const prefix = relative(top, resolve(sourceDir))
    return files.filter((f) => prefix === "" || f.startsWith(`${prefix}/`)).map((f) => (prefix === "" ? f : f.slice(prefix.length + 1)))
  } catch {
    return undefined
  }
}

export interface IO {
  readonly log: (line: string) => void
  readonly error: (line: string) => void
}

const defaultIO: IO = {
  log: (l) => console.log(l),
  error: (l) => console.error(process.env.GITHUB_ACTIONS ? `::error title=Worker release::${l}` : `worker-release: ${l}`),
}

export const main = async (argv: ReadonlyArray<string>, io: IO = defaultIO): Promise<number> => {
  const [command, ...rest] = argv
  const value = (flag: string) => (rest.includes(flag) ? rest[rest.indexOf(flag) + 1] : undefined)
  const worker = value("--worker")
  const wrangler = value("--wrangler") ?? process.env.WRANGLER_BIN ?? "wrangler"
  if (!worker) {
    io.error("--worker is required")
    return 2
  }
  if (command === "previous") {
    const run = runWrangler(wrangler, ["deployments", "status", "--name", worker, "--json"])
    let version: string | undefined
    if (run.status === 0) {
      try {
        version = currentVersion(run.stdout)
      } catch (e) {
        io.error((e as Error).message)
        return 1
      }
    }
    if (!version) {
      // Without the serving version a red smoke could not roll back: refuse the deploy, except a Worker's first one.
      const why = run.status === 0 ? "wrangler reported no serving version" : `wrangler deployments status failed (exit ${run.status}): ${(run.stderr || run.stdout).trim().slice(0, 300)}`
      if (!rest.includes("--allow-first-deploy")) {
        io.error(`${why}; no rollback target for ${worker}, so the deploy is refused (pass --allow-first-deploy only for a Worker's first deploy)`)
        return 1
      }
      io.log(`${why}; --allow-first-deploy: a red smoke cannot roll back`)
    }
    const out = value("--out")
    if (out) writeFileSync(out, version ?? "")
    io.log(`previous version of ${worker}: ${version ?? "none"}`)
    return 0
  }
  if (command === "verify") {
    const url = value("--url")
    const routesFile = value("--routes")
    if (!url || !routesFile) {
      io.error("verify needs --url and --routes")
      return 2
    }
    const previousFile = value("--previous-file")
    const previous = value("--previous") ?? (previousFile && existsSync(previousFile) ? readFileSync(previousFile, "utf8").trim() : "")
    const routes = routesFor((JSON.parse(readFileSync(routesFile, "utf8")) as { routes: Array<Route> }).routes, worker)
    const changed = changedFiles(value("--changed-since"), value("--source-dir") ?? ".")
    const chosen = selectRoutes(routes, changed)
    const attempts = Number(value("--attempts") ?? 6)
    const interval = Number(value("--interval-ms") ?? 5000)
    io.log(`smoke ${worker} at ${url}: ${chosen.map((r) => r.name).join(", ")}${changed === undefined ? " (all routes: change set unknown)" : ""}`)
    const results = await smoke(url, chosen, attempts, interval)
    for (const r of results) io.log(`${r.ok ? "PASS" : "FAIL"} ${r.route.method} ${r.route.path} (${r.route.name}): ${r.last}; want ${r.route.expect.join("/")}`)
    const red = results.filter((r) => !r.ok)
    if (red.length === 0) {
      io.log(`smoke green: ${worker}`)
      return 0
    }
    io.error(`smoke red on ${worker}: ${red.map((r) => `${r.route.name} ${r.last}`).join("; ")}`)
    if (!previous) {
      io.error(`no previous version recorded for ${worker}; cannot roll back automatically`)
      return 1
    }
    const run = runWrangler(wrangler, ["rollback", previous, "--name", worker, "-y", "--message", `auto-rollback: smoke red (${red.map((r) => r.route.name).join(", ")})`.slice(0, 100)])
    if (run.status !== 0) {
      io.error(`wrangler rollback ${previous} failed (exit ${run.status}): ${(run.stderr || run.stdout).trim().slice(0, 400)}`)
      return 1
    }
    io.error(`rolled ${worker} back to ${previous}`)
    const after = await smoke(url, routes.filter((r) => !r.sources), attempts, interval)
    for (const r of after) io.log(`after rollback: ${r.ok ? "PASS" : "FAIL"} ${r.route.name}: ${r.last}`)
    if (after.some((r) => !r.ok)) io.error(`${worker} is still red after the rollback: fix forward now`)
    return 1
  }
  if (command === "vars") {
    const configFile = value("--config")
    const env = value("--env")
    if (!configFile || !env) {
      io.error("vars needs --config and --env")
      return 2
    }
    let want: Record<string, unknown>
    try {
      want = envVars(readFileSync(configFile, "utf8"), env)
    } catch (e) {
      io.error(`cannot read env.${env}.vars from ${configFile}: ${(e as Error).message}; deploy refused`)
      return 1
    }
    const status = runWrangler(wrangler, ["deployments", "status", "--name", worker, "--json"])
    let id: string | undefined
    try {
      id = status.status === 0 ? currentVersion(status.stdout) : undefined
    } catch (e) {
      io.error(`${(e as Error).message}; deploy refused`)
      return 1
    }
    if (!id) {
      io.error(`cannot name the version serving ${worker} (wrangler deployments status exit ${status.status}: ${(status.stderr || status.stdout).trim().slice(0, 300)}), so its vars cannot be compared; deploy refused`)
      return 1
    }
    const view = runWrangler(wrangler, ["versions", "view", id, "--name", worker, "--json"])
    let bindings: unknown
    try {
      bindings = view.status === 0 ? (parseJsonOut(view.stdout) as { resources?: { bindings?: unknown } } | undefined)?.resources?.bindings : undefined
    } catch {
      bindings = undefined
    }
    if (!Array.isArray(bindings)) {
      io.error(`version ${id} of ${worker} answered no bindings (wrangler versions view exit ${view.status}: ${(view.stderr || "").trim().slice(0, 300)}); deploy refused`)
      return 1
    }
    const d = diffVars(want, bindings as Array<Binding>)
    if (d.added.length + d.removed.length + d.changed.length === 0) {
      io.log(`vars unchanged: all ${d.compared} vars of env.${env} in ${configFile} match ${worker} version ${id} (secrets not compared, not sent)`)
      return 0
    }
    const parts = [d.added.length ? `added: ${d.added.join(", ")}` : "", d.removed.length ? `removed: ${d.removed.join(", ")}` : "", d.changed.length ? `changed: ${d.changed.join(", ")}` : ""].filter(Boolean)
    io.error(`vars drift between ${configFile} env.${env}.vars and ${worker} version ${id} (${parts.join("; ")}). This deploy ships code only; deploy refused. Reconcile the vars with their owner first`)
    return 1
  }
  io.error(`unknown command ${JSON.stringify(command)}`)
  return 2
}

if (import.meta.main) process.exit(await main(process.argv.slice(2)))
