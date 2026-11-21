#!/usr/bin/env bun
// `cmux app pack` build step (until the Rust CLI verb exists): bundles an app's
// `src/main.ts` into the classic script `dist/main.js` that every engine loads.
// The script sets globalThis.__cmuxAppExports to the module's exports.
// Usage: bun tools/pack.ts <app dir> [--check]
// CMUX_EXTENSION_SDK (or `sdk`) names an SDK entry (`.../typescript/src/index.ts`) that
// `cmux-extension-sdk` resolves to when the folder has no copy of its own: `cmux ext dev` passes
// the one built into the CLI, so an extension outside a cmux checkout builds with no install.
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import type { BunPlugin } from "bun"

/** The folder's own `cmux-extension-sdk` (node_modules, tsconfig `paths`) first, else `sdk`. */
function sdkFallback(sdk: string): BunPlugin {
  return {
    name: "cmux-extension-sdk-fallback",
    setup(build) {
      build.onResolve({ filter: /^cmux-extension-sdk$/ }, (args) => {
        try {
          return { path: Bun.resolveSync(args.path, dirname(args.importer)) }
        } catch {
          return { path: sdk }
        }
      })
    }
  }
}

export async function pack(dir: string, options: { sdk?: string } = {}): Promise<string> {
  const entry = join(dir, "src/main.ts")
  const wrapper = join(dir, "src/.cmux-pack-entry.ts")
  const sdk = options.sdk ?? process.env.CMUX_EXTENSION_SDK
  writeFileSync(wrapper, `import * as app from "./main.ts"\n;(globalThis as any).__cmuxAppExports = { ...app }\n`)
  try {
    const out = await Bun.build({ entrypoints: [wrapper], format: "iife", target: "browser", minify: false, root: dir, plugins: sdk ? [sdkFallback(sdk)] : [] })
    if (!out.success) throw new Error(out.logs.map(String).join("\n"))
    if (!existsSync(entry)) throw new Error(`${entry} not found`)
    const body = (await out.outputs[0]!.text()).replace(/^\s*\/\/ \S+\.(ts|json)\n/gm, "")
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
