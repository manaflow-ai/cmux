#!/usr/bin/env bun
// The fork check (docs/app-store-platonic-ideal.md 5, phase 0; bb's "Plugin Fork Check", adapted):
// every first-party app must work when a user forks it, with only the public app SDK beside it.
//
// For each app in first-party-apps/ with its own tests:
//   1. copy the app into a temp tree with only the published SDK package beside it: the
//      cmux-extension-sdk package (cmux-tui/crates/cmux-extension-sdk/typescript) and the runtime
//      files it ships (its runtime-files.json), at their usual relative paths, plus any other
//      `file:` package the app's own package.json pins, the way `bun install` would deliver it;
//   2. rewrite its id to local/fork-<name> in both manifests and its catalog ops' owner (what a fork does);
//   3. import lint: its sources may import only files inside its own folder, the SDK's shipped
//      types (generated/cmux-app.d.ts), node:/bun: builtins and the packages its own package.json
//      pins (cmux-extension-sdk, cmux-extension-sdk/testing for tests);
//   4. run its own `bun test` in the fork.
// A failure names the private path. Apps that fail today are listed in fork-check-gaps.json with
// the reason; the check fails on any app that fails and is not listed, and notes a listed app that
// now passes (remove its row). Usage: bun first-party-apps/fork-check.ts [--json] [<name>...]
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join, relative, resolve } from "node:path"

const here = resolve(new URL(".", import.meta.url).pathname)
const root = resolve(here, "..")
/** The SDK package a fork builds against, as published. */
const sdkPackage = "cmux-tui/crates/cmux-extension-sdk/typescript"
/** The paths (repository-relative) the published package carries: the package and the runtime files it ships. */
export function sdkPaths(): string[] {
  const list = JSON.parse(readFileSync(join(root, sdkPackage, "runtime-files.json"), "utf8")) as { root: string; files: string[] }
  return [sdkPackage, ...list.files.map((file) => relative(root, resolve(root, sdkPackage, list.root, file)))]
}
/** The SDK's types an app source may name with `/// <reference path>` (the generated global). */
const sdkTypes = "cmux-tui/crates/cmux-app-host/generated"
const args = process.argv.slice(2)
const only = args.filter((a) => !a.startsWith("--"))
const gaps: Record<string, string> = JSON.parse(readFileSync(join(here, "fork-check-gaps.json"), "utf8")).gaps ?? {}

type Result = { app: string; ok: boolean; reason?: string }

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name)
    if (name === "node_modules" || name === "dist" || name === "web") return []
    return statSync(path).isDirectory() ? files(path) : [path]
  })
}

/** The packages the app's own package.json pins, name to version spec. */
function pins(appDir: string): Record<string, string> {
  const pkg = join(appDir, "package.json")
  if (!existsSync(pkg)) return {}
  const json = JSON.parse(readFileSync(pkg, "utf8"))
  return { ...(json.dependencies ?? {}), ...(json.devDependencies ?? {}) }
}

/** Imports that leave the app folder and are not the SDK's types, a builtin or a pinned package. */
export function privateImports(appDir: string): string[] {
  const pinned = new Set(Object.keys(pins(appDir)))
  const bad: string[] = []
  for (const file of files(appDir).filter((f) => /\.(ts|tsx|js|mjs)$/.test(f))) {
    const text = readFileSync(file, "utf8")
    const specs = [
      ...text.matchAll(/^\s*(?:import|export)\b[^;'"]*?\bfrom\s*["']([^"']+)["']/gm),
      ...text.matchAll(/^\s*import\s*["']([^"']+)["']/gm),
      ...text.matchAll(/\bimport\s*\(\s*["']([^"']+)["']\s*\)/g),
      ...text.matchAll(/\brequire\(\s*["']([^"']+)["']\s*\)/g),
    ].map((m) => m[1]!)
    const refs = [...text.matchAll(/reference path=["']([^"']+)["']/g)].map((m) => m[1]!)
    for (const spec of [...specs, ...refs]) {
      if (spec.startsWith("node:") || spec.startsWith("bun:") || spec === "bun") continue
      if (spec.startsWith(".")) {
        const target = resolve(dirname(file), spec)
        if (target.startsWith(appDir + "/") || target === appDir) continue
        if (relative(root, target).startsWith(sdkTypes + "/")) continue
        bad.push(`${relative(root, file)}: ${spec}`)
        continue
      }
      const name = spec.startsWith("@") ? spec.split("/").slice(0, 2).join("/") : spec.split("/")[0]!
      if (!pinned.has(name)) bad.push(`${relative(root, file)}: ${spec} (not pinned in the app's package.json)`)
    }
  }
  return bad
}

/** Renames the app to local/fork-<name> in both manifests and in the owner (`app:<id>`) of its catalog's ops. */
function forkIdentity(fork: string, name: string) {
  const id = `local/fork-${name}`
  let old: string | undefined
  for (const file of ["cmux-app.json", "cmux-app.v2.json"]) {
    const path = join(fork, file)
    if (!existsSync(path)) continue
    const manifest = JSON.parse(readFileSync(path, "utf8"))
    old ??= manifest.id
    manifest.id = id
    writeFileSync(path, JSON.stringify(manifest, null, 2) + "\n")
  }
  const catalog = join(fork, "catalog")
  if (!old || !existsSync(catalog)) return
  const rename = (value: unknown): unknown =>
    value === `app:${old}` ? `app:${id}`
    : Array.isArray(value) ? value.map(rename)
    : value && typeof value === "object" ? Object.fromEntries(Object.entries(value).map(([k, v]) => [k, rename(v)]))
    : value
  for (const file of readdirSync(catalog).filter((f) => f.endsWith(".json"))) {
    const path = join(catalog, file)
    writeFileSync(path, JSON.stringify(rename(JSON.parse(readFileSync(path, "utf8"))), null, 2) + "\n")
  }
}

function check(name: string): Result {
  const appDir = join(here, name)
  const lint = privateImports(appDir)
  if (lint.length > 0) return { app: name, ok: false, reason: `private imports: ${lint.slice(0, 3).join("; ")}${lint.length > 3 ? ` (+${lint.length - 3})` : ""}` }
  const tree = mkdtempSync(join(tmpdir(), `cmux-fork-${name}-`))
  try {
    const fork = join(tree, "first-party-apps", name)
    mkdirSync(dirname(fork), { recursive: true })
    cpSync(appDir, fork, { recursive: true, filter: (src) => !src.includes("/node_modules") })
    // The SDK as published, and each other `file:` package the app pins, where `bun install` puts
    // them for a fork that keeps the app's relative layout. Nothing else of the repository.
    const local = Object.values(pins(appDir))
      .filter((spec) => spec.startsWith("file:"))
      .map((spec) => relative(root, resolve(appDir, spec.slice("file:".length))))
      .filter((path) => path !== sdkPackage)
    for (const pub of [...sdkPaths(), ...local]) {
      if (pub === "" || pub.startsWith("..") || pub.startsWith("first-party-apps/")) throw new Error(`${name} pins ${pub}, outside the repository's packages`)
      mkdirSync(dirname(join(tree, pub)), { recursive: true })
      cpSync(join(root, pub), join(tree, pub), { recursive: true, filter: (src) => !src.includes("/node_modules") })
    }
    if (existsSync(join(appDir, "node_modules"))) cpSync(join(appDir, "node_modules"), join(fork, "node_modules"), { recursive: true })
    forkIdentity(fork, name)
    const run = Bun.spawnSync(["bun", "test"], { cwd: fork, stdout: "pipe", stderr: "pipe", env: { ...process.env, CI: "1" } })
    if (run.exitCode !== 0) {
      const out = (run.stderr.toString() + run.stdout.toString()).split("\n").filter((l) => /error|fail|✗|Cannot find/i.test(l)).slice(0, 3)
      return { app: name, ok: false, reason: `bun test failed in the fork: ${out.join(" | ") || `exit ${run.exitCode}`}` }
    }
    return { app: name, ok: true }
  } finally {
    rmSync(tree, { recursive: true, force: true })
  }
}

if (import.meta.main) {
  const names = readdirSync(here)
    .filter((n) => statSync(join(here, n)).isDirectory() && existsSync(join(here, n, "test")))
    // An app whose test/ holds only fixtures has no tests to run as a fork.
    .filter((n) => files(join(here, n, "test")).some((f) => /\.(test|spec)\.(ts|tsx|js)$/.test(f)))
    .filter((n) => only.length === 0 || only.includes(n))
    .sort()
  const results = names.map(check)
  let failed = false
  for (const r of results) {
    const listed = r.app in gaps
    if (r.ok && listed) console.log(`fork-check: ${r.app} passes now: remove its row from fork-check-gaps.json`)
    else if (r.ok) console.log(`fork-check: ${r.app} ok`)
    else if (listed) console.log(`fork-check: ${r.app} known gap: ${gaps[r.app]}`)
    else {
      failed = true
      console.error(`fork-check: ${r.app} FAILS as a fork: ${r.reason}`)
    }
  }
  if (args.includes("--json")) console.log(JSON.stringify(results, null, 2))
  const ok = results.filter((r) => r.ok).length
  console.log(`fork-check: ${ok}/${results.length} first-party apps work as forks; ${Object.keys(gaps).length} known gap(s)`)
  process.exit(failed ? 1 : 0)
}
