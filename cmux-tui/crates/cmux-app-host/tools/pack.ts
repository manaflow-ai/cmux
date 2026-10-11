#!/usr/bin/env bun
// `cmux app pack` build step (until the Rust CLI verb exists): bundles an app's
// `src/main.ts` into the classic script `dist/main.js` that every engine loads.
// The script sets globalThis.__cmuxAppExports to the module's exports.
// Usage: bun tools/pack.ts <app dir> [--check]
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"

export async function pack(dir: string): Promise<string> {
  const entry = join(dir, "src/main.ts")
  const wrapper = join(dir, "src/.cmux-pack-entry.ts")
  writeFileSync(wrapper, `import * as app from "./main.ts"\n;(globalThis as any).__cmuxAppExports = { ...app }\n`)
  try {
    const out = await Bun.build({ entrypoints: [wrapper], format: "iife", target: "browser", minify: false, root: dir })
    if (!out.success) throw new Error(out.logs.map(String).join("\n"))
    if (!existsSync(entry)) throw new Error(`${entry} not found`)
    const body = (await out.outputs[0]!.text()).replace(/^\s*\/\/ \S+\.ts\n/gm, "")
    return `// Built by cmux app pack from src/main.ts. Do not edit.\n${body}`
  } finally {
    rmSync(wrapper, { force: true })
  }
}

if (import.meta.main) {
  const dir = resolve(process.argv[2] ?? ".")
  const code = await pack(dir)
  const target = join(dir, "dist/main.js")
  if (process.argv.includes("--check")) {
    if (!existsSync(target) || readFileSync(target, "utf8") !== code) {
      console.error(`${target} is stale: run bun tools/pack.ts ${process.argv[2]}`)
      process.exit(1)
    }
  } else {
    mkdirSync(join(dir, "dist"), { recursive: true })
    writeFileSync(target, code)
  }
  console.log(`${target} ok`)
}
