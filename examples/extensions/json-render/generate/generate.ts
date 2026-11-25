// An agent makes a widget from the catalog: catalog.json becomes json-render's own catalog (Zod
// props) and prompt, a model answers with json-render's JSONL patch stream, json-render's stream
// compiler folds it into a spec, and the extension's own check() decides whether it draws.
//
//   bun generate.ts "make me a todo widget" ../specs/todo.json [--model claude-sonnet-5-5]
//
// Needs the `claude` CLI signed in. The spec it writes is what the sidebar section shows.

import { createSpecStreamCompiler, defineCatalog } from "@json-render/core"
import { schema } from "@json-render/react/schema"
import { spawnSync } from "node:child_process"
import { readFileSync, writeFileSync } from "node:fs"
import { z } from "zod"
import catalogJson from "../catalog.json"
import { check } from "../src/check.ts"

type PropDef = { type?: string; enum?: string[]; required?: boolean }
const prop = (p: PropDef) => {
  const base = p.enum ? z.enum(p.enum as [string, ...string[]]) : p.type === "number" ? z.number() : p.type === "boolean" ? z.boolean() : z.string()
  return p.required ? base : base.nullable()
}

const catalog = defineCatalog(schema, {
  components: Object.fromEntries(Object.entries(catalogJson.components).map(([name, c]) => [name, {
    props: z.object(Object.fromEntries(Object.entries(c.props as Record<string, PropDef>).map(([k, p]) => [k, prop(p)]))),
    description: c.description,
    ...("children" in c && c.children ? { slots: ["default"] } : {}),
    ...("events" in c ? { events: c.events } : {})
  }])),
  actions: {}
})

const [ask, out, ...rest] = process.argv.slice(2)
if (!ask || !out) {
  console.error('usage: bun generate.ts "make me a todo widget" OUT.json [--model M]')
  process.exit(2)
}
const model = rest[rest.indexOf("--model") + 1] ?? "claude-sonnet-5-5"
const system = catalog.prompt({
  mode: "standalone",
  customRules: [
    "This UI is a small widget in a narrow sidebar (about 260 points wide): one Panel at the root, few elements.",
    "Only the built-in actions setState, pushState and removeState exist.",
    "Every prop you set must be in the component's props list; omit props you don't need instead of writing null."
  ]
})
writeFileSync(out.replace(/\.json$/, ".prompt.txt"), system)

const t0 = performance.now()
const r = spawnSync("claude", ["-p", ask, "--model", model, "--system-prompt", system], { encoding: "utf8", maxBuffer: 1 << 24 })
if (r.status !== 0) {
  console.error(r.stderr || r.stdout)
  process.exit(1)
}
const ms = Math.round(performance.now() - t0)

const compiler = createSpecStreamCompiler<Record<string, unknown>>()
const lines = r.stdout.split("\n").filter((l) => l.trim().startsWith("{"))
for (const line of lines) compiler.push(line + "\n")
const spec = compiler.getResult()
const issues = check(spec)
writeFileSync(out, JSON.stringify(spec, null, 2) + "\n")
writeFileSync(out.replace(/\.json$/, ".jsonl"), lines.join("\n") + "\n")
console.log(JSON.stringify({ model, ms, patches: lines.length, elements: Object.keys((spec.elements as object) ?? {}).length, issues, promptChars: system.length }))
process.exit(issues.length ? 1 : 0)
