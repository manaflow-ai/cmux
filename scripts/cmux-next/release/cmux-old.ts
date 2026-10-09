/**
 * cmux-old client replay (compat gate, plans/cmux-next/release-rails.md). The shipped cmux app makes
 * every Cloud call itself, so instead of running it this replays the requests its source builds.
 *
 *   bun cmux-old.ts generate --tag vX.Y.Z [--repo DIR] [--origin https://cmux.com] [--out FILE]
 *       Reads every "/api/..." request the tag's shipped Swift builds (method from the nearby
 *       httpMethod, header names set nearby), probes each GET once against the production origin
 *       without credentials, and records the status class and, for a JSON 2xx, its top-level keys.
 *       Writes scripts/cmux-next/release/cmux-old/<tag>.json with the tag's commit.
 *   bun cmux-old.ts replay --change KEY [--spec FILE] [--origin https://cmux-staging.vercel.app]
 *       Sends the same requests to staging (non-GET with body {}), passes when every GET answers
 *       its recorded class (a JSON 2xx with at least the recorded keys) and every other method
 *       answers anything but 404, 405 or 5xx, then writes the compat-smoke receipt with the tag.
 *
 * Production steps refuse when the latest stable release is newer than the replayed spec (compat.ts).
 * Not covered yet: authenticated replays (a signed-in agent profile) and the real binary on an
 * isolated cloud Mac (a follow-up bead).
 */
import { execFileSync, spawnSync } from "node:child_process"
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { actor, receiptsDir, runIdOf, summaryLine, writeReceipt } from "./receipts.ts"
import { REPO_ROOT } from "./trees.ts"

export interface OldRequest {
  readonly method: string
  readonly path: string
  readonly headers: ReadonlyArray<string>
  readonly sources: ReadonlyArray<string>
  /** GET only: the status class production answered without credentials when the spec was made. */
  readonly expect?: string
  /** GET only: top-level keys of a JSON 2xx answer. */
  readonly keys?: ReadonlyArray<string>
}

export interface Spec {
  readonly schema: 1
  readonly tag: string
  readonly sha: string
  readonly origin: string
  readonly generated_at: string
  readonly requests: ReadonlyArray<OldRequest>
}

export const SPEC_DIR = join(import.meta.dirname, "cmux-old")
export const PLACEHOLDER = "cmuxold-smoke"

/** A Swift string literal's path with every `\(...)` interpolation replaced and the query removed. */
export const normalizePath = (literal: string): string => {
  let out = ""
  for (let i = 0; i < literal.length; i++) {
    if (literal[i] === "\\" && literal[i + 1] === "(") {
      let depth = 0
      let j = i + 1
      for (; j < literal.length; j++) {
        if (literal[j] === "(") depth++
        else if (literal[j] === ")" && --depth === 0) break
      }
      out += PLACEHOLDER
      i = j
    } else out += literal[i]
  }
  return out.split("?")[0]!.replace(/\/+$/, "") || "/"
}

export const statusClass = (code: number): string =>
  code >= 200 && code < 300 ? "2xx" : code === 401 || code === 403 ? "auth" : code === 400 || code === 422 ? "4xx-input" : code >= 500 ? "5xx" : String(code)

const SHIPPED = ["CLI", "Sources", "Packages", ":!**/*Tests*", ":!**/Tests/**", ":!**/*.md"]

/** Requests the tag's shipped Swift builds, from the source alone. */
export const extractRequests = (repo: string, tag: string): Array<Omit<OldRequest, "expect" | "keys">> => {
  const grep = spawnSync("git", ["-C", repo, "grep", "-n", "-E", '"/api/', tag, "--", ...SHIPPED], { encoding: "utf8", maxBuffer: 64 << 20 })
  if (grep.status === 128) throw new Error(`git grep at ${tag}: ${grep.stderr.trim()}`)
  const files = new Map<string, Array<string>>()
  const lines = (path: string) => {
    if (!files.has(path)) files.set(path, execFileSync("git", ["-C", repo, "show", `${tag}:${path}`], { encoding: "utf8", maxBuffer: 64 << 20 }).split("\n"))
    return files.get(path)!
  }
  const found = new Map<string, { method: string; path: string; headers: Set<string>; sources: Set<string> }>()
  for (const hit of grep.stdout.split("\n").filter(Boolean)) {
    const m = hit.match(/^[^:]+:([^:]+):(\d+):(.*)$/)
    if (!m) continue
    const [, path, num, text] = m
    if (!path!.endsWith(".swift")) continue
    const at = Number(num) - 1
    const around = lines(path!).slice(Math.max(0, at - 12), at + 13).join("\n")
    const method = around.match(/httpMethod\s*=\s*"(GET|POST|PUT|PATCH|DELETE)"/)?.[1] ?? around.match(/method:\s*\.?"?(get|post|put|patch|delete)\b/i)?.[1]?.toUpperCase() ?? "GET"
    const headers = [...around.matchAll(/forHTTPHeaderField:\s*"([^"]+)"/g)].map((h) => h[1]!)
    for (const lit of text!.matchAll(/"(\/api\/(?:[^"\\]|\\\([^"]*?\)|\\.)*)"/g)) {
      const p = normalizePath(lit[1]!)
      const key = `${method} ${p}`
      const entry = found.get(key) ?? { method, path: p, headers: new Set<string>(), sources: new Set<string>() }
      for (const h of headers) entry.headers.add(h)
      entry.sources.add(`${path}:${num}`)
      found.set(key, entry)
    }
  }
  return [...found.values()].sort((a, b) => `${a.path} ${a.method}`.localeCompare(`${b.path} ${b.method}`)).map((e) => ({ method: e.method, path: e.path, headers: [...e.headers].sort(), sources: [...e.sources].sort() }))
}

const probe = async (origin: string, method: string, path: string): Promise<{ code: number; keys?: Array<string> }> => {
  const response = await fetch(new URL(path, origin), {
    method,
    redirect: "manual",
    signal: AbortSignal.timeout(20_000),
    headers: { "user-agent": "cmux-release-rails/cmux-old-replay", ...(method === "GET" ? {} : { "content-type": "application/json" }) },
    ...(method === "GET" || method === "DELETE" ? {} : { body: "{}" }),
  })
  const text = await response.text()
  let keys: Array<string> | undefined
  if (response.status < 300 && (response.headers.get("content-type") ?? "").includes("json")) {
    try {
      const body = JSON.parse(text)
      if (body && typeof body === "object" && !Array.isArray(body)) keys = Object.keys(body).sort()
    } catch {}
  }
  return { code: response.status, ...(keys ? { keys } : {}) }
}

export const generate = async (repo: string, tag: string, origin: string, now = new Date()): Promise<Spec> => {
  const sha = execFileSync("git", ["-C", repo, "rev-list", "-n", "1", tag], { encoding: "utf8" }).trim()
  const requests: Array<OldRequest> = []
  for (const r of extractRequests(repo, tag)) {
    if (r.method !== "GET") {
      requests.push(r)
      continue
    }
    const { code, keys } = await probe(origin, "GET", r.path)
    requests.push({ ...r, expect: statusClass(code), ...(keys ? { keys } : {}) })
  }
  return { schema: 1, tag, sha, origin, generated_at: now.toISOString(), requests }
}

export interface ReplayResult {
  readonly ok: boolean
  readonly lines: Array<string>
  readonly failures: Array<string>
  readonly warnings: Array<string>
}

export interface Gap {
  readonly method: string
  readonly path: string
  readonly status: number
  readonly reason: string
}

export const readGaps = (file = join(SPEC_DIR, "staging-gaps.json")): Array<Gap> => (existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as { gaps: Array<Gap> }).gaps : [])

/** Replays `spec` against `origin`; a recorded 5xx is skipped (it was broken when the spec was made). */
export const replay = async (spec: Spec, origin: string, gaps: ReadonlyArray<Gap> = []): Promise<ReplayResult> => {
  const lines: Array<string> = []
  const failures: Array<string> = []
  const warnings: Array<string> = []
  for (const r of spec.requests) {
    let got: { code: number; keys?: Array<string> }
    try {
      got = await probe(origin, r.method, r.path)
    } catch (e) {
      failures.push(`${r.method} ${r.path}: ${(e as Error).message}`)
      continue
    }
    const cls = statusClass(got.code)
    let problem: string | undefined
    if (r.method === "GET") {
      if (r.expect === "5xx") {
        lines.push(`SKIP ${r.method} ${r.path}: answered 5xx when the spec was made`)
        continue
      }
      if (cls !== r.expect) problem = `answered ${got.code} (${cls}), ${spec.tag} saw ${r.expect}`
      else if (r.keys?.length) {
        const missing = r.keys.filter((k) => !(got.keys ?? []).includes(k))
        if (missing.length) problem = `JSON lacks ${missing.join(", ")}`
      }
    } else if (cls === "404" || cls === "405" || cls === "5xx") problem = `answered ${got.code}: the route ${spec.tag} calls is gone or broken`
    const gap = problem ? gaps.find((g) => g.method === r.method && g.path === r.path && g.status === got.code) : undefined
    if (gap) {
      warnings.push(`known staging gap ${r.method} ${r.path} ${got.code}: ${gap.reason}`)
      lines.push(`GAP  ${r.method} ${r.path}: ${got.code} (${gap.reason})`)
      continue
    }
    lines.push(`${problem ? "FAIL" : "PASS"} ${r.method} ${r.path}: ${got.code}${problem ? ` (${problem})` : ""}`)
    if (problem) failures.push(`${r.method} ${r.path}: ${problem}`)
  }
  return { ok: failures.length === 0, lines, failures, warnings }
}

/** The newest spec on disk (by tag, semver order). */
export const newestSpec = (dir = SPEC_DIR): Spec | undefined => {
  if (!existsSync(dir)) return undefined
  const tags = readdirSync(dir)
    .filter((f) => /^v\d+\.\d+\.\d+\.json$/.test(f))
    .map((f) => f.slice(0, -5))
    .sort((a, b) => a.slice(1).split(".").map(Number).reduce((acc, n, i) => acc || n - Number(b.slice(1).split(".")[i]), 0))
  const tag = tags.at(-1)
  return tag ? (JSON.parse(readFileSync(join(dir, `${tag}.json`), "utf8")) as Spec) : undefined
}

const main = async (argv: ReadonlyArray<string>): Promise<number> => {
  const [command, ...rest] = argv
  const value = (flag: string) => (rest.includes(flag) ? rest[rest.indexOf(flag) + 1] : undefined)
  if (command === "generate") {
    const tag = value("--tag")
    if (!tag) throw new Error("--tag vX.Y.Z")
    const spec = await generate(value("--repo") ?? REPO_ROOT, tag, value("--origin") ?? "https://cmux.com")
    mkdirSync(SPEC_DIR, { recursive: true })
    const out = value("--out") ?? join(SPEC_DIR, `${tag}.json`)
    writeFileSync(out, `${JSON.stringify(spec, null, 2)}\n`)
    console.log(`wrote ${out}: ${spec.requests.length} requests from ${tag} (${spec.sha.slice(0, 12)})`)
    return 0
  }
  if (command === "replay") {
    const change = value("--change")
    if (!change) throw new Error("--change <compat change key> (compat.ts check prints it)")
    const spec = value("--spec") ? (JSON.parse(readFileSync(value("--spec")!, "utf8")) as Spec) : newestSpec()
    if (!spec) throw new Error(`no spec in ${SPEC_DIR}; run generate first`)
    const origin = value("--origin") ?? "https://cmux-staging.vercel.app"
    const result = await replay(spec, origin, readGaps())
    for (const l of result.lines) console.log(l)
    const receipt = {
      action: "compat-smoke" as const,
      what: `replay ${spec.requests.length} ${spec.tag} requests against ${origin}: ${result.failures.length} failed`,
      tree: "compat",
      target: value("--target") ?? "production",
      result: result.ok ? ("pass" as const) : ("fail" as const),
      at: new Date().toISOString(),
      setHash: change,
      release: spec.tag,
      releaseSha: spec.sha,
      runId: runIdOf(),
      by: actor(),
      ...(result.failures.length ? { errors: result.failures } : {}),
      ...(result.warnings.length ? { warnings: result.warnings } : {}),
    }
    const file = writeReceipt(receiptsDir(), receipt)
    console.log(`bd-summary: ${summaryLine(receipt, file)}`)
    return result.ok ? 0 : 1
  }
  console.error("usage: cmux-old.ts generate --tag vX.Y.Z | replay --change KEY")
  return 2
}

if (import.meta.main) process.exit(await main(process.argv.slice(2)))
