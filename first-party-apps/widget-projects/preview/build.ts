#!/usr/bin/env bun
// Writes preview/scenes.json: the scene ops the packed widget draws for each gallery variant, at a
// fixed instant (Tuesday, November 17, 2026, 1:12 PM in Los Angeles) with a fake project index. The
// webviews gallery entry `apps.projects-widget` renders them with the real scene renderer, in
// Apple's widget tile sizes.
//   bun first-party-apps/widget-projects/preview/build.ts [--check]
import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { pack } from "cmux-extension-sdk/testing"
import { renderScene, type Render } from "./scenes.ts"

export const VARIANTS: Record<string, Render> = {
  small: { size: "small", index: "busy" },
  medium: { size: "medium", index: "busy" },
  large: { size: "large", index: "busy" },
  "small-sidebar": { size: "small", index: "busy", place: "sidebar" },
  "medium-few": { size: "medium", index: "few" },
  "medium-empty": { size: "medium", index: "empty" },
  "small-denied": { size: "small", index: "denied" },
  "large-other-mac": { size: "large", index: "busy", machine: "Studio" }
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
      console.error(`${target} is stale: run bun first-party-apps/widget-projects/preview/build.ts`)
      process.exit(1)
    }
  } else writeFileSync(target, text)
}
