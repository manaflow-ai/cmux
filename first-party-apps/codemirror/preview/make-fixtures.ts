// Generates web pane preview fixtures for the editor apps (invented data).
// Usage: bun first-party-apps/<editor app>/preview/make-fixtures.ts [out dir]
// Format: {init: partial bridge init message, ops: {op: value | {$error}}, events: [{afterMs, stream, payload}]}.
import { writeFileSync } from "node:fs"

const out = process.argv[2] ?? new URL(".", import.meta.url).pathname
const rev = (counter: number) => ({ counter, hash: `h${counter.toString(16).padStart(6, "0")}` })
const ts = `import { LruCache } from "./lru"

/** Rendered pages, newest last. Evictions are counted. */
const pages = new LruCache<string, string>(500, (key) => metrics.count("cache.evict", { key }))

export interface RenderOptions {
  locale: string
  preview?: boolean
}

export function render(path: string, options: RenderOptions = { locale: "en" }): string {
  const key = \`\${options.locale}:\${path}\`
  const hit = pages.get(key)
  if (hit !== undefined) return hit
  const html = template(path, options).replace(/\\s+$/g, "")
  if (!options.preview) pages.set(key, html)
  return html
}

export const clearPages = () => pages.clear()
`
const md = `# Page cache

Rendered pages stay in an **LRU cache** of 500 entries.

- Evictions are counted as \`cache.evict\`.
- Call \`clearPages()\` after a deploy.

See [the routes](src/server/routes.ts) for the key format.
`
const info = (over: Record<string, unknown> = {}) => ({
  doc: "doc_routes",
  uri: "file://mac/Users/dev/orbit/src/server/routes.ts",
  name: "routes.ts",
  type: { uti: "public.typescript-source", language: "typescript" },
  encoding: "utf-8",
  lineEnding: "lf",
  revision: rev(7),
  dirty: false,
  readOnly: false,
  conflict: null,
  ...over
})
const base = (variant: string, over: Record<string, unknown> = {}, text = ts) => ({
  init: { settings: { variant }, props: { doc: "doc_routes" } },
  ops: { "document.open": { info: info(over), text }, "document.edit": { revision: rev(8), dirty: true }, "document.save": { revision: rev(8), dirty: false } }
})
const before = ts.replace("(500, (key) => metrics.count(\"cache.evict\", { key }))", "(100)").replace("  if (!options.preview) pages.set(key, html)\n", "  pages.set(key, html)\n").replace("\nexport const clearPages = () => pages.clear()\n", "")
const write = (name: string, v: unknown) => writeFileSync(`${out}/${name}.json`, JSON.stringify(v, null, 2) + "\n")

write("statusLine", base("statusLine", { dirty: true }))
write("header", { ...base("header", { dirty: true, name: "caching.md", uri: "file://mac/Users/dev/orbit/docs/caching.md", type: { uti: "net.daringfireball.markdown", language: "markdown" } }, md) })
write("bare", base("bare"))
write("conflict", base("statusLine", { dirty: true, conflict: { diskRevision: rev(9), bufferRevision: rev(8) } }))
write("readOnly", base("bare", { readOnly: true, readOnlyReason: "permissions" }))
write("reloaded", {
  ...base("statusLine"),
  events: [{ afterMs: 150, stream: "document.changed", payload: { doc: "doc_routes", base_revision: rev(7), revision: rev(8), dirty: false, origin: "disk", edits: [{ from: ts.indexOf("500"), to: ts.indexOf("500") + 3, text: "1000" }] } }]
})
const diffInit = (layout: string) => ({ init: { settings: { variant: "bare" }, props: { readOnly: true, chrome: "none", diff: { original: { diff: "diff_prop7", path: "src/server/routes.ts", side: "base" }, modified: { diff: "diff_prop7", path: "src/server/routes.ts", side: "head" }, layout, path: "src/server/routes.ts" } } } })
write("diffSideBySide", { ...diffInit("sideBySide"), ops: { "diff.file.read": { $sequence: [{ text: before }, { text: ts }] } } })
write("diffInline", { ...diffInit("inline"), ops: { "diff.file.read": { $sequence: [{ text: before }, { text: ts }] } } })
write("missing", { init: { settings: { variant: "statusLine" }, props: { doc: "doc_routes" } }, ops: {} })
