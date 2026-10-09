/**
 * cmux-old compatibility gate (plans/cmux-next/release-rails.md, "cmux-old compatibility").
 *
 *   bun compat.ts static --change migrations:<tree> | image:<var>:<sh-id> | deploy:<tree> --target production
 *       [--base REV] [--release TAG] [--root DIR]
 *   bun compat.ts smoke-record --change ... --target production --result pass|fail --detail TEXT
 *       (written by the cmux-old client smoke, compat-smoke.sh, after it ran against STAGING)
 *   bun compat.ts check --change ... --target production
 *
 * Production steps (db-release apply, promote, deploy) refuse without a passing
 * `compat-static` AND a passing `compat-smoke` receipt of the same change key in
 * the last 24 h. Static checks: (1) inventory: `git grep` at the latest stable
 * release tag for every host and name the change reaches (cmux-vm and cmux-next
 * API hosts, the snapshot var names and value); a hit makes the change
 * cmux-old-affecting and is reported; (2) migrations: the linter, including the
 * cmux-vm schema confinement; (3) API contract: cmux-vm openapi.json through the
 * pinned oasdiff (removed endpoints or fields, new required inputs, narrowed
 * types) and backend/catalog/cloud-operations.json (removed operations, params,
 * types, fields, enum values or error codes, new required params) against
 * --base (default: origin/main for production, origin/feat-cmux-next for staging).
 */
import { execFileSync, spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { CONTRACT_PATH, lintTree, LOCK_PATH, readJson, readMigrations, sha256, type Lock, type RoleContract } from "./lint.ts"
import { actor, readReceipts, receiptsDir, runIdOf, summaryLine, writeReceipt, REHEARSAL_MAX_AGE_MS } from "./receipts.ts"
import { REPO_ROOT, treeOf, type Tree } from "./trees.ts"

export type Change = { readonly kind: "migrations"; readonly tree: Tree } | { readonly kind: "image"; readonly variable: string; readonly snapshotId: string } | { readonly kind: "deploy"; readonly tree: Tree }

export const parseChange = (text: string | undefined): Change => {
  const [kind, a, b] = (text ?? "").split(":")
  if (kind === "migrations" || kind === "deploy") return { kind, tree: treeOf(a) }
  if (kind === "image" && (a === "CLOUD_FREESTYLE_SNAPSHOT" || a === "TEAM_VM_SNAPSHOT") && b?.startsWith("sh-")) return { kind, variable: a, snapshotId: b }
  throw new Error(`--change must be migrations:<tree>, deploy:<tree> or image:<CLOUD_FREESTYLE_SNAPSHOT|TEAM_VM_SNAPSHOT>:<sh-id>, got ${JSON.stringify(text)}`)
}

/** The change key a production step and its compat receipts must share. */
export const changeKey = (root: string, change: Change, gitSha?: string): string => {
  if (change.kind === "migrations") return `migrations:${change.tree.name}:${sha256(readMigrations(root, change.tree).map((f) => `${f.name}:${f.checksum}`).join("\n")).slice(0, 16)}`
  if (change.kind === "image") return `image:${change.variable}:${change.snapshotId}`
  if (!gitSha) throw new Error("a deploy change key needs the commit")
  return `deploy:${change.tree.name}:${gitSha}`
}

/** What cmux-old could reach through this change: hosts and names to look for in the shipped release. */
export const needles = (change: Change, snapshotName?: string): Array<string> => {
  if (change.kind === "image") return [change.variable, ...(snapshotName ? [snapshotName] : [])]
  return change.tree.name === "cmux-vm" ? ["vm.cmux.dev", "vm-staging.cmux.dev", "cmux-vm-staging", "cmux-vm-production"] : ["cloud-api.cmux.dev", "cloud-api-staging.cmux.dev", "cmux-api-staging", "cmux-api.debussy"]
}

/** Shipped paths at a release tag (the app, its packages, the CLI and the bundled cmux-tui), tests excluded. */
const SHIPPED = ["CLI", "Sources", "Packages", "cmux-tui/crates", ":!**/*Tests*", ":!**/tests/**", ":!**/*.md"]

export const latestRelease = (): string => execFileSync("gh", ["release", "view", "--repo", "manaflow-ai/cmux", "--json", "tagName", "--jq", ".tagName"], { encoding: "utf8" }).trim()

export const inventoryHits = (root: string, tag: string, words: ReadonlyArray<string>): Array<string> => {
  spawnSync("git", ["-C", root, "fetch", "--quiet", "--no-tags", "--depth=1", "origin", `refs/tags/${tag}:refs/tags/${tag}`])
  const hits: Array<string> = []
  for (const w of words) {
    const run = spawnSync("git", ["-C", root, "grep", "-l", "-F", w, tag, "--", ...SHIPPED], { encoding: "utf8" })
    if (run.status === 128) throw new Error(`git grep at ${tag} failed: ${run.stderr.trim()}`)
    for (const line of run.stdout.split("\n").filter(Boolean)) hits.push(`${w} in ${line.replace(`${tag}:`, "")}`)
  }
  return hits
}

const show = (root: string, rev: string, path: string): string | undefined => {
  const run = spawnSync("git", ["-C", root, "show", `${rev}:${path}`], { encoding: "utf8", maxBuffer: 256 << 20 })
  return run.status === 0 ? run.stdout : undefined
}

type Json = Record<string, any>
const IGNORED = new Set(["description", "docs", "since", "cli", "mcp", "examples", "owner", "focuses", "risk", "input_json_schema", "output_json_schema"])

/** Everything `base` promises that `head` no longer does: removed keys, changed kinds or names, removed enum values. */
export const supersetProblems = (base: unknown, head: unknown, path: string, out: Array<string> = []): Array<string> => {
  if (Array.isArray(base)) {
    if (!Array.isArray(head)) out.push(`${path}: was a list`)
    else if (base.every((v) => typeof v !== "object")) for (const v of base) if (!head.includes(v)) out.push(`${path}: ${JSON.stringify(v)} removed`)
    return out
  }
  if (base && typeof base === "object") {
    if (!head || typeof head !== "object") {
      out.push(`${path}: removed`)
      return out
    }
    for (const [k, v] of Object.entries(base as Json)) {
      if (IGNORED.has(k)) continue
      if (!(k in (head as Json))) out.push(`${path}.${k}: removed`)
      else supersetProblems(v, (head as Json)[k], `${path}.${k}`, out)
    }
    return out
  }
  if ((path.endsWith(".kind") || path.endsWith(".name") || path.endsWith(".class")) && base !== head) out.push(`${path}: ${JSON.stringify(base)} became ${JSON.stringify(head)}`)
  return out
}

/** Breaking changes of backend/catalog/cloud-operations.json for clients built against `base`. */
export const catalogProblems = (base: Json, head: Json): Array<string> => {
  const out: Array<string> = []
  supersetProblems(base.errors ?? {}, head.errors ?? {}, "errors", out)
  supersetProblems(base.types ?? {}, head.types ?? {}, "types", out)
  for (const [name, op] of Object.entries((base.operations ?? {}) as Json)) {
    const next = (head.operations ?? {})[name]
    if (!next) {
      out.push(`operations.${name}: removed`)
      continue
    }
    supersetProblems(op.result, next.result, `operations.${name}.result`, out)
    const before = (op.params?.fields ?? {}) as Json
    const after = (next.params?.fields ?? {}) as Json
    for (const f of Object.keys(before)) if (!(f in after)) out.push(`operations.${name}.params.${f}: removed`)
    for (const [f, spec] of Object.entries(after)) if ((spec as Json).required === true && (before[f] as Json | undefined)?.required !== true) out.push(`operations.${name}.params.${f}: newly required`)
  }
  return out
}

const OASDIFF_VERSION = "1.32.1"
const DARWIN = { file: `oasdiff_${OASDIFF_VERSION}_darwin_all.tar.gz`, sha256: "e4d74b7e2dfb9d4819e7fc720c905ec86547e4637ac270a2b0187c0f1fb7187e" }
/** The release's checksums.txt; linux-x64 equals workers/cmux-vm/scripts/openapi-breaking.sh. */
const OASDIFF: Record<string, { file: string; sha256: string }> = {
  "linux-x64": { file: `oasdiff_${OASDIFF_VERSION}_linux_amd64.tar.gz`, sha256: "7c8939fc49b75ee11fec66a5b83b37a2fca6aee109fed85013b1ba2ac2a1ee7f" },
  "darwin-arm64": DARWIN,
  "darwin-x64": DARWIN,
}

/** cmux-vm openapi.json, base vs head, through the same pinned oasdiff as workers/cmux-vm/scripts/openapi-breaking.sh. */
export const openapiProblems = (baseDoc: string, headDoc: string): Array<string> => {
  const pin = OASDIFF[`${process.platform}-${process.arch}`]
  if (!pin) return [`oasdiff is not pinned for ${process.platform}-${process.arch}`]
  const work = mkdtempSync(join(tmpdir(), "compat-oasdiff-"))
  writeFileSync(join(work, "base.json"), baseDoc)
  writeFileSync(join(work, "head.json"), headDoc)
  const archive = join(work, "oasdiff.tgz")
  const url = `https://github.com/oasdiff/oasdiff/releases/download/v${OASDIFF_VERSION}/${pin.file}`
  const fetched = spawnSync("curl", ["-fsSL", "--retry", "3", "-o", archive, url], { encoding: "utf8" })
  if (fetched.status !== 0) return [`could not fetch the pinned oasdiff: ${fetched.stderr.trim().slice(0, 200)}`]
  const digest = createHash("sha256").update(readFileSync(archive)).digest("hex")
  if (digest !== pin.sha256) return [`oasdiff archive sha256 ${digest} is not the pinned ${pin.sha256}`]
  if (spawnSync("tar", ["-xzf", archive, "-C", work, "oasdiff"]).status !== 0) return ["could not unpack oasdiff"]
  const run = spawnSync(join(work, "oasdiff"), ["breaking", join(work, "base.json"), join(work, "head.json"), "--fail-on", "ERR", "--format", "text"], { encoding: "utf8" })
  return run.status === 0 ? [] : [`openapi: ${(run.stdout || run.stderr).trim().slice(0, 2000)}`]
}

export interface StaticResult {
  readonly key: string
  readonly errors: Array<string>
  readonly notes: Array<string>
  readonly affectsCmuxOld: boolean
}

export const staticChecks = async (root: string, change: Change, options: { base: string; release: string; snapshotName?: string; gitSha?: string; openapi?: typeof openapiProblems }): Promise<StaticResult> => {
  const errors: Array<string> = []
  const notes: Array<string> = []
  const hits = inventoryHits(root, options.release, needles(change, options.snapshotName))
  if (hits.length) notes.push(`cmux-old ${options.release} reaches this change: ${hits.join("; ")}`)
  else notes.push(`cmux-old ${options.release} references none of ${needles(change, options.snapshotName).join(", ")} in its shipped code`)
  if (change.kind !== "image") {
    const report = await lintTree(change.tree, { root, lock: readJson<Lock>(join(root, LOCK_PATH)), contract: readJson<RoleContract>(join(root, CONTRACT_PATH)), base: options.base })
    errors.push(...report.errors)
    if (change.tree.name === "cmux-vm") {
      const baseDoc = show(root, options.base, "workers/cmux-vm/openapi.json")
      const headDoc = show(root, "HEAD", "workers/cmux-vm/openapi.json")
      if (baseDoc && headDoc && baseDoc !== headDoc) errors.push(...(options.openapi ?? openapiProblems)(baseDoc, headDoc))
    } else {
      const baseDoc = show(root, options.base, "backend/catalog/cloud-operations.json")
      const headDoc = show(root, "HEAD", "backend/catalog/cloud-operations.json")
      if (baseDoc && headDoc) errors.push(...catalogProblems(JSON.parse(baseDoc), JSON.parse(headDoc)).map((p) => `catalog ${p}`))
    }
  }
  return { key: changeKey(root, change, options.gitSha), errors, notes, affectsCmuxOld: hits.length > 0 }
}

/** The passing static and smoke receipts of `key` for `target` in the last 24 h, or what is missing. */
export const compatProblems = (dir: string, key: string, target: string, now = Date.now()): Array<string> => {
  const fresh = readReceipts(dir).filter((r) => r.target === target && r.setHash === key && now - Date.parse(r.at) <= REHEARSAL_MAX_AGE_MS)
  const problems: Array<string> = []
  const last = (action: "compat-static" | "compat-smoke") => fresh.filter((r) => r.action === action).at(-1)
  if (last("compat-static")?.result !== "pass") problems.push(`no passing cmux-old static compat receipt for ${key} (bun scripts/cmux-next/release/compat.ts static ...)`)
  if (last("compat-smoke")?.result !== "pass") problems.push(`no passing cmux-old client smoke against staging for ${key} in the last 24 h (scripts/cmux-next/release/compat-smoke.sh on cmux-lawrence-2)`)
  return problems
}

const main = async (argv: ReadonlyArray<string>): Promise<number> => {
  const [command, ...rest] = argv
  const value = (flag: string) => (rest.includes(flag) ? rest[rest.indexOf(flag) + 1] : undefined)
  const root = value("--root") ?? REPO_ROOT
  const change = parseChange(value("--change"))
  const target = value("--target") ?? "production"
  const dir = receiptsDir()
  const sha = spawnSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).stdout.trim()
  const key = changeKey(root, change, sha)
  const emit = (action: "compat-static" | "compat-smoke", result: "pass" | "fail", what: string, errors: Array<string>, notes: Array<string>) => {
    const receipt = { action, what, tree: change.kind === "image" ? "images" : change.tree.name, target, result, at: new Date().toISOString(), setHash: key, runId: runIdOf(), by: actor(), ...(errors.length ? { errors } : {}), ...(notes.length ? { warnings: notes } : {}), gitSha: sha }
    const file = writeReceipt(dir, receipt)
    console.log(`bd-summary: ${summaryLine(receipt, file)}`)
  }
  if (command === "static") {
    const release = value("--release") ?? latestRelease()
    const base = value("--base") ?? (target === "production" ? "origin/main" : "origin/feat-cmux-next")
    const result = await staticChecks(root, change, { base, release, ...(value("--snapshot-name") ? { snapshotName: value("--snapshot-name")! } : {}), gitSha: sha })
    for (const n of result.notes) console.log(`note: ${n}`)
    for (const e of result.errors) console.error(`compat: ${e}`)
    emit("compat-static", result.errors.length ? "fail" : "pass", `cmux-old static compat of ${key} against ${base}, release ${release}`, result.errors, result.notes)
    return result.errors.length ? 1 : 0
  }
  if (command === "smoke-record") {
    const result = value("--result")
    if (result !== "pass" && result !== "fail") throw new Error("--result pass|fail")
    emit("compat-smoke", result, `cmux-old client smoke against staging for ${key}: ${value("--detail") ?? ""}`, [], [])
    return result === "pass" ? 0 : 1
  }
  if (command === "check") {
    const problems = compatProblems(dir, key, target)
    for (const p of problems) console.error(`compat: ${p}`)
    if (!problems.length) console.log(`compat ok: ${key} (${target})`)
    return problems.length ? 1 : 0
  }
  console.error("usage: compat.ts static|smoke-record|check --change ... --target ...")
  return 2
}

if (import.meta.main) process.exit(await main(process.argv.slice(2)))
