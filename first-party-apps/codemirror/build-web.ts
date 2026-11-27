#!/usr/bin/env bun
// Builds the web pane bundle web-src/ -> web/ (no network at runtime, no CDN).
// Usage: bun first-party-apps/<app>/build-web.ts [--check]
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const dir = new URL(".", import.meta.url).pathname
const check = process.argv.includes("--check")

async function build(out: string) {
  rmSync(out, { recursive: true, force: true })
  mkdirSync(out, { recursive: true })
  const r = await Bun.build({
    // main.ts is the page; editor-worker.ts, when present, is a same-origin worker.
    entrypoints: ["main.ts", "editor-worker.ts"].map((f) => join(dir, "web-src", f)).filter((f) => existsSync(f)),
    outdir: out,
    format: "esm",
    target: "browser",
    minify: true,
    splitting: false,
    naming: { entry: "[name].[ext]", asset: "[name].[ext]" }
  })
  if (!r.success) throw new Error(r.logs.map(String).join("\n"))
  cpSync(join(dir, "web-src/index.html"), join(out, "index.html"))
  cpSync(join(dir, "THIRD_PARTY_NOTICES"), join(out, "THIRD_PARTY_NOTICES.txt"))
}

const files = (d: string) => readdirSync(d).filter((f) => statSync(join(d, f)).isFile()).sort()

if (check) {
  const tmp = mkdtempSync(join(tmpdir(), "cmux-web-"))
  await build(tmp)
  const target = join(dir, "web")
  const stale = !existsSync(target) || files(tmp).join() !== files(target).join() || files(tmp).some((f) => !readFileSync(join(tmp, f)).equals(readFileSync(join(target, f))))
  rmSync(tmp, { recursive: true, force: true })
  if (stale) {
    console.error(`${target} is stale: run bun ${join(dir, "build-web.ts")}`)
    process.exit(1)
  }
} else await build(join(dir, "web"))
for (const f of files(join(dir, "web"))) console.log(`web/${f} ${statSync(join(dir, "web", f)).size} bytes`)
