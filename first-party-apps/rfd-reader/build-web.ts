#!/usr/bin/env bun
// Builds the web pane bundle web-src/ -> web/ (no network at runtime, no CDN), and the preview
// page preview/dist/ (the same page on fixtures, for screenshots; not shipped).
// Usage: bun first-party-apps/rfd-reader/build-web.ts [--check]
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const dir = new URL(".", import.meta.url).pathname
const check = process.argv.includes("--check")

async function bundle(entry: string, out: string) {
  const r = await Bun.build({
    entrypoints: [entry],
    outdir: out,
    format: "esm",
    target: "browser",
    minify: true,
    splitting: false,
    naming: { entry: "[name].[ext]", asset: "[name].[ext]" },
  })
  if (!r.success) throw new Error(r.logs.map(String).join("\n"))
}

async function build(out: string) {
  rmSync(out, { recursive: true, force: true })
  mkdirSync(out, { recursive: true })
  await bundle(join(dir, "web-src/main.ts"), out)
  cpSync(join(dir, "web-src/index.html"), join(out, "index.html"))
  cpSync(join(dir, "THIRD_PARTY_NOTICES"), join(out, "THIRD_PARTY_NOTICES.txt"))
}

async function buildPreview() {
  const out = join(dir, "preview/dist")
  rmSync(out, { recursive: true, force: true })
  mkdirSync(out, { recursive: true })
  await bundle(join(dir, "preview/host.ts"), out)
  const html = readFileSync(join(dir, "web-src/index.html"), "utf8")
    .replace('href="main.css"', 'href="../../web/main.css"')
    .replace('<script type="module" src="main.js"></script>', '<script type="module" src="host.js"></script>\n  <script type="module" src="../../web/main.js"></script>')
  writeFileSync(join(out, "index.html"), html)
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
} else {
  await build(join(dir, "web"))
  await buildPreview()
}
for (const f of files(join(dir, "web"))) console.log(`web/${f} ${statSync(join(dir, "web", f)).size} bytes`)
