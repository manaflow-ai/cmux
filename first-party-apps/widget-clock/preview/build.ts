#!/usr/bin/env bun
// Writes preview/scenes.json: the scene ops the packed widget draws for each gallery variant, at a
// fixed instant (Monday, November 16, 2026, 9:41 AM in Los Angeles). The webviews gallery entry
// `apps.clock-widget` renders them with the real scene renderer, in Apple's widget tile sizes.
//   bun first-party-apps/widget-clock/preview/build.ts [--check]
process.env.TZ = "America/Los_Angeles"
import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { pack } from "cmux-extension-sdk/testing"
import { renderScene, type Render } from "./scenes.ts"

export const VARIANTS: Record<string, Render> = {
  small: { size: "small" },
  medium: { size: "medium" },
  large: { size: "large" },
  "small-analog": { size: "small", settings: { face: "analog" } },
  "medium-analog": { size: "medium", settings: { face: "analog" } },
  "large-24h": { size: "large", settings: { hourCycle: "24h", cities: "Europe/Paris, Asia/Kolkata, Asia/Singapore, Pacific/Auckland" } }
}

export async function buildScenes(): Promise<string> {
  const source = await pack(join(import.meta.dir, ".."))
  const entries: string[] = []
  for (const [name, render] of Object.entries(VARIANTS)) {
    const ops = (await renderScene(source, render)).ops.map((op) => `   ${JSON.stringify(op)}`).join(",\n")
    entries.push(` ${JSON.stringify(name)}: {\n  "size": ${JSON.stringify(render.size)},\n  "ops": [\n${ops}\n  ]\n }`)
  }
  // One op per line: a diff of a design change reads as the nodes it touched.
  return `{\n${entries.join(",\n")}\n}\n`
}

if (import.meta.main) {
  const target = join(import.meta.dir, "scenes.json")
  const text = await buildScenes()
  if (process.argv.includes("--check")) {
    if (readFileSync(target, "utf8") !== text) {
      console.error(`${target} is stale: run bun first-party-apps/widget-clock/preview/build.ts`)
      process.exit(1)
    }
  } else writeFileSync(target, text)
  console.log(`${target} ok`)
}
