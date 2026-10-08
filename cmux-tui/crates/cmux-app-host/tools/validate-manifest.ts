#!/usr/bin/env bun
// `cmux app validate` logic (until the Rust CLI verb exists): validates an app
// package directory the same way the registry does before it records a version.
// Usage: bun tools/validate-manifest.ts <dir> [--json]
// Exit 0 valid, 2 invalid, 1 usage error.

import { existsSync, readFileSync, statSync } from "node:fs"
import { join, normalize, resolve } from "node:path"
import { SchemaValidator, type SchemaError } from "./json-schema.ts"

const here = new URL(".", import.meta.url).pathname
const schemaPath = join(here, "../schema/cmux-app.schema.json")
const scopesPath = join(here, "../generated/scopes.json")

export interface ValidationResult {
  ok: boolean
  errors: SchemaError[]
  warnings: SchemaError[]
  manifest?: Record<string, unknown>
}

const RESERVED_PUBLISHERS = new Set(["cmux", "manaflow-ai"])
const SPECIAL_SCOPES = [/^net:(\*\.)?[a-z0-9.-]+$/, /^integration:[a-z0-9-]+(:read)?$/, /^storage:synced$/, /^mcp:expose$/, /^clipboard:write$/, /^actions:run$/]
const LIMITS = { manifestBytes: 64 * 1024, mainBytes: 2 * 1024 * 1024 }
const HEX_COLOR = /"#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?"/

let cachedValidator: SchemaValidator | undefined
const validator = () => (cachedValidator ??= new SchemaValidator(JSON.parse(readFileSync(schemaPath, "utf8"))))

/** Scope names the host knows: every scope in generated/scopes.json plus the special scopes. */
export const knownScope = (scope: string, generated: ReadonlySet<string>) => generated.has(scope) || SPECIAL_SCOPES.some((r) => r.test(scope))

const loadGeneratedOps = (): Set<string> => {
  if (!existsSync(scopesPath)) return new Set()
  const doc = JSON.parse(readFileSync(scopesPath, "utf8")) as { ops: Record<string, unknown> }
  return new Set(Object.keys(doc.ops))
}

const loadGeneratedScopes = (): Set<string> => {
  if (!existsSync(scopesPath)) return new Set()
  const doc = JSON.parse(readFileSync(scopesPath, "utf8")) as { ops: Record<string, { scope: string }> }
  return new Set(Object.values(doc.ops).map((o) => o.scope))
}

/** Loads a built `main` script with stub globals and returns each exported function with its palette kind, when it is a palette source. */
export const exportedFunctions = (source: string): Map<string, "snapshot" | "query" | "detail" | undefined> => {
  const noop = () => stub
  const stub: unknown = new Proxy(noop, { get: () => stub, apply: () => stub })
  const sandbox: Record<string, unknown> = { __cmuxAppExports: undefined }
  const KIND = "__cmuxPaletteKind"
  const tagged = (kind: string) => (f: unknown) => Object.assign(() => f, { [KIND]: kind })
  const palette = { snapshot: tagged("snapshot"), query: tagged("query"), detail: tagged("detail"), cached: () => ({}) }
  const act = (id: string, args: unknown = {}) => ({ id, args })
  // The script declares `var __cmuxAppExports = (() => {...})()`; run it as a function body and return the binding.
  const fn = new Function("globalThis", "cmux", "signal", "computed", "effect", "palette", "act", `${source}\n;return typeof __cmuxAppExports === "undefined" ? globalThis.__cmuxAppExports : __cmuxAppExports;`)
  const exports = fn(sandbox, stub, () => [stub, stub], () => stub, () => undefined, palette, act) as Record<string, unknown> | undefined
  const out = new Map<string, "snapshot" | "query" | "detail" | undefined>()
  if (!exports || typeof exports !== "object") return out
  for (const [k, v] of Object.entries(exports)) if (typeof v === "function") out.set(k, (v as unknown as Record<string, unknown>)[KIND] as "snapshot" | "query" | "detail" | undefined)
  return out
}

/** Loads a built `main` script with stub globals and returns the names it exports. */
export const exportedNames = (source: string): string[] => [...exportedFunctions(source).keys()]

const APP_SCOPE_REF = /^app:([^#]+)#(.+)$/

/**
 * Manifest-level palette rules the schema cannot express (palette-scopes.md
 * section 6): prefixes are first-party only and unique, keywords do not
 * collide inside the app, `children` name a scope of this manifest or
 * `app:<id>#<scope>`, references to the app's own commands exist, and
 * `mode: form` commands declare `arguments`.
 */
export function checkPalette(manifest: Record<string, unknown>): { errors: SchemaError[]; warnings: SchemaError[] } {
  const errors: SchemaError[] = []
  const warnings: SchemaError[] = []
  const id = String(manifest.id ?? "")
  const contributes = (manifest.contributes ?? {}) as Record<string, unknown>
  const scopes = (Array.isArray(contributes.paletteScopes) ? contributes.paletteScopes : []) as Array<Record<string, any>>
  const commands = (Array.isArray(contributes.commands) ? contributes.commands : []) as Array<Record<string, any>>
  const scopeIds = new Set(scopes.map((s) => s.id))
  const commandIds = new Set(commands.map((c) => c.id))
  const keywordOwner = new Map<string, string>()
  const prefixOwner = new Map<string, string>()
  const ownAction = (at: string, action: unknown) => {
    const m = typeof action === "string" ? APP_SCOPE_REF.exec(action) : null
    if (m && m[1] === id && !commandIds.has(m[2]!)) errors.push({ path: at, code: "action.unknown", message: `${action} names no command of this app` })
  }
  scopes.forEach((s, i) => {
    const at = `/contributes/paletteScopes/${i}`
    if (typeof s.prefix === "string") {
      if (!id.startsWith("cmux/")) errors.push({ path: `${at}/prefix`, code: "prefix.reserved", message: "only first-party apps (cmux/) may declare a prefix; users can assign one in cmux.json" })
      else if (prefixOwner.has(s.prefix)) errors.push({ path: `${at}/prefix`, code: "prefix.collision", message: `prefix ${s.prefix} is also used by scope ${prefixOwner.get(s.prefix)}` })
      else prefixOwner.set(s.prefix, s.id)
    }
    ;((s.keywords ?? []) as string[]).forEach((k, j) => {
      const owner = keywordOwner.get(k)
      if (owner !== undefined && owner !== s.id) errors.push({ path: `${at}/keywords/${j}`, code: "keyword.collision", message: `keyword ${k} is also used by scope ${owner}` })
      else keywordOwner.set(k, s.id)
    })
    ;((s.children ?? []) as string[]).forEach((child, j) => {
      const path = `${at}/children/${j}`
      const m = APP_SCOPE_REF.exec(child)
      const local = m ? (m[1] === id ? m[2]! : null) : child
      if (local === s.id) errors.push({ path, code: "children.self", message: "a scope cannot be its own child" })
      else if (local !== null && !scopeIds.has(local)) errors.push({ path, code: "children.unknown", message: `${child} is not a palette scope of this app` })
    })
    ownAction(`${at}/primary`, s.primary)
    ownAction(`${at}/emptyState/action`, s.emptyState?.action)
  })
  commands.forEach((c, i) => {
    if (c.mode === "form" && (typeof c.arguments !== "object" || c.arguments === null || typeof c.arguments.properties !== "object")) {
      errors.push({ path: `/contributes/commands/${i}/arguments`, code: "arguments.required", message: "mode form renders the arguments schema; declare arguments with properties" })
    }
  })
  return { errors, warnings }
}

const insideFiles = (path: string, files: readonly string[] | undefined) => {
  if (!files) return true
  const p = normalize(path)
  return files.some((f) => {
    const base = normalize(f)
    return base.endsWith("/") ? p.startsWith(base) : p === base || p.startsWith(`${base}/`)
  })
}

export function validatePackage(dir: string, options: { generatedScopes?: ReadonlySet<string> } = {}): ValidationResult {
  const errors: SchemaError[] = []
  const warnings: SchemaError[] = []
  const manifestPath = join(dir, "cmux-app.json")
  if (!existsSync(manifestPath)) return { ok: false, errors: [{ path: "", code: "manifest.missing", message: "cmux-app.json not found" }], warnings }
  const raw = readFileSync(manifestPath, "utf8")
  if (Buffer.byteLength(raw) > LIMITS.manifestBytes) errors.push({ path: "", code: "limit.manifest", message: "cmux-app.json is larger than 64 KiB" })
  let manifest: Record<string, unknown>
  try {
    manifest = JSON.parse(raw)
  } catch (e) {
    return { ok: false, errors: [{ path: "", code: "json.invalid", message: String((e as Error).message) }], warnings }
  }
  errors.push(...validator().validate(manifest))
  if (errors.length) return { ok: false, errors, warnings, manifest }

  const id = manifest.id as string
  const publisher = id.split("/")[0]!
  const repository = manifest.repository as string | undefined
  if (publisher !== "local" && RESERVED_PUBLISHERS.has(publisher) && repository && !/^https:\/\/github\.com\/manaflow-ai\//.test(repository)) {
    errors.push({ path: "/id", code: "publisher.reserved", message: `publisher ${publisher} is reserved for first-party apps` })
  }
  if (publisher !== "local" && !repository) errors.push({ path: "/repository", code: "repository.required", message: "store apps need a GitHub repository" })
  if (publisher !== "local" && repository && !RESERVED_PUBLISHERS.has(publisher)) {
    const owner = repository.split("/")[3]!.toLowerCase()
    if (owner !== publisher) errors.push({ path: "/id", code: "publisher.mismatch", message: `publisher ${publisher} must equal the repository owner ${owner}` })
  }

  const files = manifest.files as string[] | undefined
  const paths: Array<[string, string]> = []
  if (typeof manifest.main === "string") paths.push(["/main", manifest.main])
  if (typeof manifest.icon === "string") paths.push(["/icon", manifest.icon])
  ;((manifest.screenshots as string[] | undefined) ?? []).forEach((p, i) => paths.push([`/screenshots/${i}`, p]))

  // Native code paths (a cmux-shipped server binary, a built-in native pane view) are first-party only in
  // phase 1 (Verified later); hosts refuse them for other tiers, and the validator says so up front.
  const server = manifest.server as { kind?: string; catalog?: string } | undefined
  if (typeof server?.catalog === "string") paths.push(["/server/catalog", server.catalog])
  const firstParty = RESERVED_PUBLISHERS.has(publisher)
  if (server?.kind === "native" && !firstParty) errors.push({ path: "/server/kind", code: "tier.native", message: "native servers are allowed only for first-party apps" })

  const contributes = (manifest.contributes ?? {}) as Record<string, unknown>
  ;((contributes.paneKinds as Array<Record<string, unknown>> | undefined) ?? []).forEach((p, i) => {
    if (p.renderer === "native" && !firstParty) errors.push({ path: `/contributes/paneKinds/${i}/renderer`, code: "tier.native", message: "native pane renderers are allowed only for first-party apps" })
  })
  const seen = new Map<string, string>()
  const exportRefs: Array<[string, string, ("snapshot" | "query" | "detail")?]> = []
  for (const [kind, list] of Object.entries(contributes)) {
    if (!Array.isArray(list)) continue
    list.forEach((entry: Record<string, unknown>, i) => {
      const at = `/contributes/${kind}/${i}`
      const cid = entry.id as string
      if (seen.has(cid)) errors.push({ path: `${at}/id`, code: "contribution.duplicate", message: `contribution id ${cid} is also used at ${seen.get(cid)}` })
      else seen.set(cid, at)
      for (const key of ["render", "run"]) if (typeof entry[key] === "string") exportRefs.push([`${at}/${key}`, entry[key] as string])
      if (kind === "paletteScopes") {
        const source = entry.source as { kind?: string; export?: string } | undefined
        if (source && (source.kind === "snapshot" || source.kind === "query") && typeof source.export === "string") exportRefs.push([`${at}/source/export`, source.export, source.kind])
        const detail = entry.detail as { export?: string } | undefined
        if (typeof detail?.export === "string") exportRefs.push([`${at}/detail/export`, detail.export, "detail"])
      }
      for (const key of ["path", "ghostty", "template", "web"]) if (typeof entry[key] === "string") paths.push([`${at}/${key}`, entry[key] as string])
    })
  }

  for (const [at, p] of paths) {
    const full = resolve(dir, p)
    if (!full.startsWith(resolve(dir))) errors.push({ path: at, code: "path.escape", message: `${p} leaves the package` })
    else if (!existsSync(full)) errors.push({ path: at, code: "path.missing", message: `${p} does not exist` })
    else if (!insideFiles(p, files)) errors.push({ path: at, code: "path.notInFiles", message: `${p} is not listed in files` })
  }

  if (exportRefs.length && typeof manifest.main !== "string") {
    errors.push({ path: "/main", code: "main.required", message: "contributions with render/run need main" })
  } else if (typeof manifest.main === "string" && existsSync(join(dir, manifest.main))) {
    const source = readFileSync(join(dir, manifest.main), "utf8")
    if (statSync(join(dir, manifest.main)).size > LIMITS.mainBytes) errors.push({ path: "/main", code: "limit.main", message: "main is larger than 2 MiB" })
    let functions = new Map<string, "snapshot" | "query" | "detail" | undefined>()
    try {
      functions = exportedFunctions(source)
    } catch (e) {
      errors.push({ path: "/main", code: "main.load", message: `main failed to load: ${(e as Error).message}` })
    }
    if (!functions.size && !errors.some((e) => e.code === "main.load")) {
      errors.push({ path: "/main", code: "main.noExports", message: "main defines no __cmuxAppExports (build with --format=iife --global-name=__cmuxAppExports)" })
    }
    for (const [at, name, kind] of exportRefs) {
      if (!functions.size) continue
      if (!functions.has(name)) errors.push({ path: at, code: "export.missing", message: `main does not export function ${name}` })
      else if (kind && functions.get(name) !== undefined && functions.get(name) !== kind) errors.push({ path: at, code: "export.kind", message: `${name} is a palette.${functions.get(name)} source, not ${kind}` })
    }
    if (HEX_COLOR.test(source)) warnings.push({ path: "/main", code: "color.hex", message: "hex colors found; prefer semantic color tokens (primary, secondary, accent, success, warning, danger)" })
  }

  const paletteChecks = checkPalette(manifest)
  errors.push(...paletteChecks.errors)
  warnings.push(...paletteChecks.warnings)
  const scopeList = (Array.isArray(contributes.paletteScopes) ? contributes.paletteScopes : []) as Array<{ source?: { kind?: string; op?: string } }>
  const knownOps = loadGeneratedOps()
  scopeList.forEach((s, i) => {
    if (s.source?.kind === "op" && s.source.op && knownOps.size && !knownOps.has(s.source.op)) {
      warnings.push({ path: `/contributes/paletteScopes/${i}/source/op`, code: "op.unknown", message: `${s.source.op} is not in the operation catalog (fine for an op your app server owns)` })
    }
  })

  const generated = options.generatedScopes ?? loadGeneratedScopes()
  for (const key of ["scopes", "optionalScopes"]) {
    for (const scope of Object.keys((manifest[key] ?? {}) as Record<string, string>)) {
      if (generated.size && !knownScope(scope, generated)) warnings.push({ path: `/${key}/${scope.replace(/\//g, "~1")}`, code: "scope.unknown", message: `scope ${scope} is not known to this API version` })
    }
  }
  return { ok: errors.length === 0, errors, warnings, manifest }
}

if (import.meta.main) {
  const args = process.argv.slice(2)
  const dir = args.find((a) => !a.startsWith("--"))
  if (!dir) {
    console.error("usage: validate-manifest.ts <dir> [--json]")
    process.exit(1)
  }
  const result = validatePackage(dir)
  const { manifest: _m, ...out } = result
  if (args.includes("--json")) console.log(JSON.stringify(out, null, 2))
  else {
    for (const e of result.errors) console.log(`error ${e.path || "/"}: ${e.message} [${e.code}]`)
    for (const w of result.warnings) console.log(`warning ${w.path || "/"}: ${w.message} [${w.code}]`)
    console.log(result.ok ? "valid" : "invalid")
  }
  process.exit(result.ok ? 0 : 2)
}
