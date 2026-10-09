/**
 * Post-deploy rail for a Cloudflare Worker (plans/cmux-next/release-rails.md).
 *
 *   bun worker-release.ts previous --worker NAME [--wrangler BIN] [--out FILE]
 *       Prints (and writes to FILE) the version id serving 100% now. Run BEFORE the deploy.
 *   bun worker-release.ts verify --worker NAME --url BASE --routes FILE --previous-file FILE
 *       [--changed-since REV] [--source-dir DIR] [--wrangler BIN] [--attempts N] [--interval-ms MS]
 *       Smokes every route of FILE without `sources`, and each route whose
 *       `sources` match a file changed since REV (all routes when REV is
 *       unknown). On red: `wrangler rollback <previous> --name NAME -y`, smoke
 *       the always-routes again, and exit 1 either way (the job fails).
 *
 * Routes file: {"routes":[{"name","method","path","expect":[status...],"body"?,
 * "bodyIncludes"?,"sources"?:[glob relative to --source-dir],"why"?}]}.
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
  const status = JSON.parse(statusJson) as { versions?: Array<{ version_id?: string; percentage?: number }> } | Array<{ versions?: Array<{ version_id?: string; percentage?: number }> }>
  const deployment = Array.isArray(status) ? status.at(-1) : status
  const versions = deployment?.versions ?? []
  if (versions.length !== 1 || (versions[0]?.percentage ?? 100) !== 100) {
    if (versions.length > 1) throw new Error(`a gradual deployment is in progress (${versions.length} versions); finish or roll it back by hand first`)
    return undefined
  }
  return versions[0]?.version_id
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
    } else io.log(`no current deployment of ${worker} (wrangler exit ${run.status}); a red smoke cannot roll back`)
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
    const routes = (JSON.parse(readFileSync(routesFile, "utf8")) as { routes: Array<Route> }).routes
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
  io.error(`unknown command ${JSON.stringify(command)}`)
  return 2
}

if (import.meta.main) process.exit(await main(process.argv.slice(2)))
