#!/usr/bin/env bun
// Writes webviews/src/apps/scene/fixtures/todo-widget-scenes.json (inside webviews, so the gallery's
// CI checkout of webviews/ has it): the scene ops the packed widget draws for each gallery variant over a
// sample list (preview/scenes.ts). The webviews gallery entry `apps.todo-widget` renders them with
// the real scene renderer, in Apple's widget tile sizes; light and dark come from the gallery theme.
//   bun first-party-apps/widget-todo/preview/build.ts [--check]
import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { pack } from "cmux-extension-sdk/testing"
import { renderScene, SAMPLE, type Size } from "./scenes.ts"

const FEW = Object.fromEntries(Object.entries(SAMPLE).filter(([key]) => ["item:a", "item:b", "item:c"].includes(key)))

export const VARIANTS: Record<string, { size: Size; seed: Record<string, unknown>; expandDone?: boolean }> = {
  small: { size: "small", seed: SAMPLE },
  medium: { size: "medium", seed: SAMPLE },
  large: { size: "large", seed: SAMPLE },
  "large-completed-open": { size: "large", seed: SAMPLE, expandDone: true },
  "medium-few": { size: "medium", seed: FEW },
  "small-empty": { size: "small", seed: {} },
  "medium-empty": { size: "medium", seed: {} },
  "large-empty": { size: "large", seed: {} }
}

export async function buildScenes(): Promise<string> {
  const source = await pack(join(import.meta.dir, ".."))
  const entries: string[] = []
  for (const [name, v] of Object.entries(VARIANTS)) {
    const ops = (await renderScene(source, v.size, v.seed, { expandDone: v.expandDone })).map((op) => `   ${JSON.stringify(op)}`).join(",\n")
    entries.push(` ${JSON.stringify(name)}: {\n  "size": ${JSON.stringify(v.size)},\n  "ops": [\n${ops}\n  ]\n }`)
  }
  // One op per line: a diff of a design change reads as the nodes it touched.
  return `{\n${entries.join(",\n")}\n}\n`
}

if (import.meta.main) {
  const target = join(import.meta.dir, "..", "..", "..", "webviews", "src", "apps", "scene", "fixtures", "todo-widget-scenes.json")
  const text = await buildScenes()
  if (process.argv.includes("--check")) {
    // As data: the web formatter re-indents the committed copy, which changes nothing it holds.
    if (JSON.stringify(JSON.parse(readFileSync(target, "utf8"))) !== JSON.stringify(JSON.parse(text))) {
      console.error(`${target} is stale: run bun first-party-apps/widget-todo/preview/build.ts`)
      process.exit(1)
    }
  } else writeFileSync(target, text)
  console.log(`${target} ok`)
}
