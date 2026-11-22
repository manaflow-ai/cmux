/**
 * Cloud VM image staleness guard (bead cx-4l51; plans/cmux-next/release-rails.md "Image staleness").
 *
 *   bun scripts/cmux-next/release/image-staleness.ts [--root <repo>] [--rev <git rev>] [--now <ISO>] [--max-age-days 7] [--json]
 *
 * Every image a channel points at (images/cmux-vm/channels/<channel>.json: the Cloud image at the
 * top level, the team VM image under team_vm) must have a bake record in channels/dev.json
 * `history` with `cmux_tui.capabilities` (the daemon handshake the bake read, identify.ts). The
 * guard compares that list with the tip's capability list, read from the cmux-tui source of the
 * checkout (`advertised_capabilities` and `identify_capabilities` in
 * cmux-tui-core/src/server/capabilities.rs), so it needs no VM and no binary. It fails when:
 *   (The workflow reports by issue only; this script exits 1 so the report is explicit.)
 *   1. an image lacks a capability the tip always serves (at once: the push that adds a capability
 *      is when the image starts to fall behind);
 *   2. an image's capability set differs from the tip's and its cmux-tui commit is more than
 *      --max-age-days (7) older than the tip commit (catches removed or renamed capabilities);
 *   3. an image has no bake record or no recorded capability list;
 *   4. backend/apps/api/wrangler.jsonc boots an image for an env whose channel file does not point
 *      at it (an image the guard cannot see).
 * Capabilities the daemon adds only at run time (inside an `if` in identify_capabilities, and the
 * app host and file ops lists that depend on the machine) are "conditional": never required.
 * A capability name the source reader cannot resolve fails the guard (fail closed).
 */
import { execFileSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { ENV_OF, readVar, type Channel, type SnapshotVar } from "./promote-lib.ts"
import { REPO_ROOT } from "./trees.ts"

const CRATES = "cmux-tui/crates"
const CORE = "cmux-tui/crates/cmux-tui-core/src"
const CAPABILITIES_RS = `${CORE}/server/capabilities.rs`
const CHANNELS = "images/cmux-vm/channels"
const WRANGLER = "backend/apps/api/wrangler.jsonc"
const VARS: ReadonlyArray<SnapshotVar> = ["CLOUD_FREESTYLE_SNAPSHOT", "TEAM_VM_SNAPSHOT"]
const CHANNEL_LIST: ReadonlyArray<Channel> = ["dev", "staging", "production"]

/** Reads repository files from the working tree, or from a git revision. */
export interface SourceReader {
  read(path: string): string | undefined
  /** `git grep -n -A1 -E <pattern> -- <dir>` output lines, without the revision prefix. */
  grep(pattern: string, dir: string): Array<string>
  /** The commit time (ISO) of the revision read, or of HEAD. */
  commitTime(): string
  commit(): string
}

/** git grep output; exit 1 (no match) is an empty list. */
const grepLines = (run: () => string): Array<string> => {
  try {
    return run().split("\n")
  } catch (error) {
    if ((error as { status?: number }).status === 1) return []
    throw error
  }
}

export const treeReader = (root: string): SourceReader => {
  const git = (...args: Array<string>) => execFileSync("git", ["-C", root, ...args], { encoding: "utf8", maxBuffer: 64 << 20, stdio: ["ignore", "pipe", "pipe"] })
  return {
    read: (path) => (existsSync(join(root, path)) ? readFileSync(join(root, path), "utf8") : undefined),
    grep: (pattern, dir) => grepLines(() => git("grep", "-n", "-A1", "-E", pattern, "--", dir)),
    commitTime: () => git("log", "-1", "--format=%cI", "HEAD").trim(),
    commit: () => git("rev-parse", "HEAD").trim(),
  }
}

export const revReader = (root: string, rev: string): SourceReader => {
  const git = (...args: Array<string>) => execFileSync("git", ["-C", root, ...args], { encoding: "utf8", maxBuffer: 64 << 20, stdio: ["ignore", "pipe", "pipe"] })
  return {
    read: (path) => {
      try {
        return git("show", `${rev}:${path}`)
      } catch {
        return undefined
      }
    },
    grep: (pattern, dir) => grepLines(() => git("grep", "-n", "-A1", "-E", pattern, rev, "--", dir)).map((l) => (l.startsWith(`${rev}:`) ? l.slice(rev.length + 1) : l)),
    commitTime: () => git("log", "-1", "--format=%cI", rev).trim(),
    commit: () => git("rev-parse", rev).trim(),
  }
}

export interface TipCapabilities {
  /** Served by every daemon of this source on Linux. */
  readonly always: Array<string>
  /** Added only at run time (machine or role dependent); never required of an image. */
  readonly conditional: Array<string>
}

const stripComments = (source: string) => source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/[^\n]*/g, "")

const fnBody = (source: string, name: string): string => {
  const start = source.search(new RegExp(`\\bfn\\s+${name}\\s*\\(`))
  if (start < 0) throw new Error(`${CAPABILITIES_RS}: no fn ${name}`)
  const open = source.indexOf("{", start)
  let depth = 0
  for (let i = open; i < source.length; i++) {
    if (source[i] === "{") depth++
    else if (source[i] === "}" && --depth === 0) return source.slice(open + 1, i)
  }
  throw new Error(`${CAPABILITIES_RS}: fn ${name} has no end`)
}

/** Every `const NAME: &str = "value"` (value on the same or the next line) in the cmux-tui crates, tests excluded, by name. */
const constIndex = (reader: SourceReader): Map<string, Array<{ file: string; value: string }>> => {
  const index = new Map<string, Array<{ file: string; value: string }>>()
  const lines = reader.grep("const [A-Z][A-Z0-9_]*: &('static )?str =", CRATES)
  for (let i = 0; i < lines.length; i++) {
    const hit = lines[i]!.match(/^(.+?\.rs):\d+:(.*)$/)
    if (!hit || /(^|\/)tests?(\/|\.rs$)|_tests?\.rs$/.test(hit[1]!)) continue
    const next = lines[i + 1]?.match(/^.+?\.rs-\d+-(.*)$/)?.[1] ?? ""
    const m = `${hit[2]} ${next}`.match(/\bconst\s+([A-Z][A-Z0-9_]*)\s*:\s*&\s*(?:'static\s+)?str\s*=\s*"([^"]*)"/)
    if (!m || hit[2]!.trim().startsWith("//")) continue
    const list = index.get(m[1]!) ?? []
    list.push({ file: hit[1]!, value: m[2]! })
    index.set(m[1]!, list)
  }
  return index
}

/** The module files a Rust path (`crate::a::b`, `a::b` relative to server) can name. */
const moduleFiles = (segments: Array<string>): Array<string> => {
  const rel = segments.filter((s) => s !== "crate" && s !== "super" && s !== "self")
  if (rel.length === 0) return []
  const p = rel.join("/")
  const roots = segments[0] === "crate" ? [CORE] : [`${CORE}/server`, CORE]
  return roots.flatMap((r) => [`${r}/${p}.rs`, `${r}/${p}/mod.rs`])
}

const resolveToken = (token: string, index: Map<string, Array<{ file: string; value: string }>>, reader: SourceReader, depth = 0): string => {
  const literal = token.match(/^"([^"]*)"$/)
  if (literal) return literal[1]!
  const segments = token.split("::").map((s) => s.trim())
  const name = segments.pop()!
  const found = index.get(name) ?? []
  const distinct = (list: Array<{ value: string }>) => [...new Set(list.map((c) => c.value))]
  const files = moduleFiles(segments)
  if (files.length) {
    const inModule = found.filter((c) => files.includes(c.file) || files.some((f) => f.endsWith("/mod.rs") && c.file.startsWith(f.slice(0, -"mod.rs".length))) || files.some((f) => c.file.startsWith(f.slice(0, -".rs".length) + "/")))
    if (distinct(inModule).length === 1) return inModule[0]!.value
    // A re-export in the module file: `use path::OTHER as NAME;` or `use path::NAME;`.
    for (const file of files) {
      const text = stripComments(reader.read(file) ?? "")
      const alias = text.match(new RegExp(`\\buse\\s+([\\w:]+)::(\\w+)\\s+as\\s+${name}\\s*;`)) ?? text.match(new RegExp(`\\buse\\s+([\\w:]+)::(${name})\\s*;`))
      if (alias && depth < 4) return resolveToken(`${alias[1]}::${alias[2]}`, index, reader, depth + 1)
    }
  }
  if (distinct(found).length === 1) return found[0]!.value
  throw new Error(`cannot resolve capability ${token} (${found.length} constants named ${name}: ${found.map((c) => c.file).join(", ") || "none"}); teach image-staleness.ts this form`)
}

const splitTopLevel = (text: string): Array<string> =>
  text
    .split(",")
    .map((t) => t.replace(/\s+/g, "").trim())
    .filter(Boolean)

/** The tip's capability list from cmux-tui source (see the file comment). */
export const tipCapabilities = (reader: SourceReader): TipCapabilities => {
  const source = reader.read(CAPABILITIES_RS)
  if (!source) throw new Error(`${CAPABILITIES_RS} is missing`)
  const text = stripComments(source)
  const index = constIndex(reader)
  const always = new Set<string>()
  const conditional = new Set<string>()
  const advertised = fnBody(text, "advertised_capabilities")
  const vec = advertised.match(/vec!\s*\[([\s\S]*?)\]/)
  if (!vec) throw new Error(`${CAPABILITIES_RS}: advertised_capabilities has no vec![...]`)
  for (const token of splitTopLevel(vec[1]!)) always.add(resolveToken(token, index, reader))
  // Statements after the vec: a push counts on Linux unless its cfg excludes Linux; an extend is a machine-dependent list.
  const rest = advertised.slice(advertised.indexOf(vec[0]) + vec[0].length)
  for (const m of rest.matchAll(/(#\[cfg\(([^\]]*)\)\]\s*)?capabilities\.(push|extend)\(([^;]*)\);/g)) {
    const cfg = m[2] ?? ""
    const linux = !cfg || (!/not\s*\(/.test(cfg) && /unix|linux/.test(cfg))
    if (m[3] === "extend") continue
    if (linux) always.add(resolveToken(m[4]!.trim(), index, reader))
  }
  const identify = fnBody(text, "identify_capabilities")
  let depth = 0
  for (const line of identify.split("\n")) {
    const push = line.match(/capabilities\.push\(([^;]*)\);/)
    if (push) (depth === 0 ? always : conditional).add(resolveToken(push[1]!.trim(), index, reader))
    depth += (line.match(/\{/g)?.length ?? 0) - (line.match(/\}/g)?.length ?? 0)
  }
  for (const c of always) conditional.delete(c)
  return { always: [...always].sort(), conditional: [...conditional].sort() }
}

export interface ImageRecord {
  readonly snapshot: string
  readonly snapshot_id: string
  readonly names?: Partial<Record<Channel, { readonly snapshot: string; readonly snapshot_id: string }>>
  readonly cmux_tui?: { readonly commit?: string; readonly committed_at?: string; readonly capabilities?: ReadonlyArray<string> }
}

export interface ImageVerdict {
  readonly channel: Channel
  readonly variable: SnapshotVar
  readonly snapshot: string
  readonly snapshot_id: string | null
  readonly cmux_tui_commit: string | null
  readonly missing: Array<string>
  readonly extra: Array<string>
  readonly age_days: number | null
  readonly problems: Array<string>
}

export interface StalenessReport {
  readonly tip_commit: string
  readonly tip_committed_at: string
  readonly tip_capabilities: number
  readonly images: Array<ImageVerdict>
  readonly problems: Array<string>
}

type Json = Record<string, unknown>
const DAY = 86_400_000

/** Pointer per var in one channel file: the Cloud image at the top level, the team VM image under team_vm. */
const pointersOf = (doc: Json): Array<{ variable: SnapshotVar; snapshot: string; snapshot_id: string | null }> => {
  const out: Array<{ variable: SnapshotVar; snapshot: string; snapshot_id: string | null }> = []
  if (typeof doc.snapshot === "string") out.push({ variable: "CLOUD_FREESTYLE_SNAPSHOT", snapshot: doc.snapshot, snapshot_id: typeof doc.snapshot_id === "string" ? doc.snapshot_id : null })
  const team = doc.team_vm as Json | undefined
  if (team && typeof team.snapshot === "string") out.push({ variable: "TEAM_VM_SNAPSHOT", snapshot: team.snapshot, snapshot_id: typeof team.snapshot_id === "string" ? team.snapshot_id : null })
  return out
}

export const checkStaleness = (reader: SourceReader, options: { maxAgeDays?: number } = {}): StalenessReport => {
  const maxAgeDays = options.maxAgeDays ?? 7
  const tip = tipCapabilities(reader)
  const tipTime = reader.commitTime()
  const problems: Array<string> = []
  const images: Array<ImageVerdict> = []
  const devText = reader.read(`${CHANNELS}/dev.json`)
  const history: Array<ImageRecord> = devText ? (((JSON.parse(devText) as Json).history as Array<ImageRecord> | undefined) ?? []) : []
  const wrangler = reader.read(WRANGLER)
  for (const channel of CHANNEL_LIST) {
    const text = reader.read(`${CHANNELS}/${channel}.json`)
    const doc: Json = text ? (JSON.parse(text) as Json) : {}
    const pointers = pointersOf(doc)
    if (wrangler)
      for (const variable of VARS) {
        let serving: string | undefined
        try {
          serving = readVar(wrangler, ENV_OF[channel], variable)
        } catch {
          serving = undefined
        }
        if (serving && !pointers.some((p) => p.variable === variable && p.snapshot === serving))
          problems.push(`${channel}: ${WRANGLER} env ${ENV_OF[channel]} boots ${variable}=${serving}, but channels/${channel}.json does not point at it (promote it with images/cmux-vm/promote.ts so the guard can see it)`)
      }
    for (const pointer of pointers) {
      const entry = history.find((h) => (channel === "dev" ? h.snapshot_id === pointer.snapshot_id : h.names?.[channel]?.snapshot_id === pointer.snapshot_id))
      const label = `${channel} ${pointer.variable} ${pointer.snapshot} (${pointer.snapshot_id ?? "no id"})`
      const own: Array<string> = []
      const recorded = entry?.cmux_tui?.capabilities
      let missing: Array<string> = []
      let extra: Array<string> = []
      let age: number | null = null
      if (!entry) own.push(`${label}: no bake record in channels/dev.json history`)
      else if (!recorded?.length) own.push(`${label}: its bake record has no cmux_tui.capabilities (re-probe it with web/scripts/cmux-vm-image/capabilities-probe.ts and record the list, or rebake)`)
      else {
        const served = new Set(recorded)
        missing = tip.always.filter((c) => !served.has(c))
        extra = [...served].filter((c) => !tip.always.includes(c) && !tip.conditional.includes(c)).sort()
        const at = entry.cmux_tui?.committed_at
        age = at ? (Date.parse(tipTime) - Date.parse(at)) / DAY : null
        if (missing.length) own.push(`${label}: cmux-tui ${entry.cmux_tui?.commit?.slice(0, 12) ?? "?"} lacks ${missing.length} tip capabilit${missing.length === 1 ? "y" : "ies"}: ${missing.join(", ")}`)
        if ((missing.length || extra.length) && (age === null || age > maxAgeDays))
          own.push(`${label}: capability set differs from the tip and its cmux-tui is ${age === null ? "of unknown age (no cmux_tui.committed_at)" : `${age.toFixed(1)} days`} older than the tip (limit ${maxAgeDays})${extra.length ? `; not served by the tip: ${extra.join(", ")}` : ""}`)
      }
      problems.push(...own)
      images.push({ channel, variable: pointer.variable, snapshot: pointer.snapshot, snapshot_id: pointer.snapshot_id, cmux_tui_commit: entry?.cmux_tui?.commit ?? null, missing, extra, age_days: age, problems: own })
    }
  }
  return { tip_commit: reader.commit(), tip_committed_at: tipTime, tip_capabilities: tip.always.length, images, problems }
}

export const formatReport = (report: StalenessReport): string => {
  const lines = [`tip ${report.tip_commit.slice(0, 12)} (${report.tip_committed_at}): ${report.tip_capabilities} capabilities always served`]
  for (const image of report.images)
    lines.push(`${image.problems.length ? "STALE" : "ok   "} ${image.channel} ${image.variable} ${image.snapshot} cmux-tui ${image.cmux_tui_commit?.slice(0, 12) ?? "?"}${image.age_days === null ? "" : `, ${image.age_days.toFixed(1)} days behind the tip commit`}${image.missing.length ? `, missing ${image.missing.join(", ")}` : ""}`)
  for (const p of report.problems) lines.push(`problem: ${p}`)
  lines.push(report.problems.length ? `image-staleness: FAIL (${report.problems.length} problem${report.problems.length === 1 ? "" : "s"})` : "image-staleness: PASS")
  return lines.join("\n")
}

if (import.meta.main) {
  const argv = process.argv.slice(2)
  const value = (flag: string) => (argv.includes(flag) ? argv[argv.indexOf(flag) + 1] : undefined)
  const root = value("--root") ?? REPO_ROOT
  const rev = value("--rev")
  const reader = rev ? revReader(root, rev) : treeReader(root)
  const report = checkStaleness(reader, { maxAgeDays: Number(value("--max-age-days") ?? 7) })
  console.log(argv.includes("--json") ? JSON.stringify(report, null, 2) : formatReport(report))
  process.exit(report.problems.length ? 1 : 0)
}
