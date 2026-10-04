#!/usr/bin/env bun
// Generates the typed `cmux` global for apps from the operation catalogs:
//   generated/cmux-app.d.ts  typed global (one method per op, TSDoc with class and scope)
//   generated/scopes.json    op name -> scope (the host's scope check and the consent UI)
//   generated/ops.json       op names
// Sources until the merged D7 catalog exists: cmux-tui resource ops, cloud ops,
// app actions, and every first-party app's catalog fragment (app-catalogs.ts).
// `--check` exits 1 when a generated file is stale.

import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { loadAppCatalogs, schemaType } from "./app-catalogs.ts"

const here = new URL(".", import.meta.url).pathname
const repo = join(here, "../../../..")
const outDir = join(here, "../generated")
export const API_VERSION = "1.0.0"

type TypeIR = { kind: string; [k: string]: unknown }
interface Field { required: boolean; type: TypeIR; description?: string }
interface Op {
  class: string; risk?: string; params?: { selectors?: Record<string, string>; fields?: Record<string, Field> }; result?: TypeIR; docs?: string
  source: "local" | "cloud" | "app"
  /** App catalog ops: the owning app and JSON Schema input/output instead of params/result. */
  owner?: string; input?: Record<string, unknown>; output?: Record<string, unknown>
}

/** Op families that share one scope family. */
const SCOPE_FAMILY: Record<string, string> = { tab: "workspace", pane: "workspace", screen: "workspace", window: "workspace", session: "session", frontend_projection: "client" }
/** Families apps never reach in phase 1 (grants, installs, accounts, pairing, raw client plumbing). */
const NEVER_FAMILIES = new Set(["install", "grant", "host", "pairing_request", "client", "request", "stream", "frontend_projection", "user", "app"])
const EXECUTE = /(^terminal\.input\.(write|keys|mouse)$|\.run$|^terminal\.(attach|project)$|^browser\.input\.|^session\.journal\.hook\.put$)/
const NEVER = /(\.close$|\.shutdown$|^session\.(open|reload_config|creation\.resolve)$|\.renderer_grant\.|\.history\.clear$)/

const readJSON = (p: string) => JSON.parse(readFileSync(join(repo, p), "utf8"))

export function scopeFor(name: string, op: Pick<Op, "class" | "risk">): string | null {
  const family = name.split(".")[0]!
  if (NEVER_FAMILIES.has(family) || NEVER.test(name)) return null
  const scopeFamily = SCOPE_FAMILY[family] ?? family
  if (op.risk) {
    switch (op.risk) {
      case "read": return `${scopeFamily}:read`
      case "mutate-own":
      case "mutate-shared": return `${scopeFamily}:write`
      case "execute": return `${scopeFamily}:execute`
      case "send-external": return `${scopeFamily}:external`
      default: return null
    }
  }
  if (op.class === "read") return `${scopeFamily}:read`
  if (EXECUTE.test(name)) return `${scopeFamily}:execute`
  if (op.class === "mutation") return `${scopeFamily}:write`
  return null
}

export function loadCatalog(): { ops: Record<string, Op>; types: Record<string, TypeIR>; generics: Record<string, { parameters: string[]; body: TypeIR }>; actions: string[] } {
  const local = readJSON("cmux-tui/spec/resource-operations-v2.json")
  const cloud = readJSON("backend/catalog/cloud-operations.json")
  const actions = readJSON("plans/cmux-next/action-surfaces.json").actions as Array<{ id: string; cli: string }>
  const ops: Record<string, Op> = {}
  for (const [name, op] of Object.entries(local.operations as Record<string, Op>)) ops[name] = { ...op, source: "local" }
  const cloudOps = (cloud.operations ?? {}) as Record<string, Op>
  for (const [name, op] of Object.entries(cloudOps)) if (!ops[name]) ops[name] = { ...op, source: "cloud" }
  for (const op of loadAppCatalogs(join(repo, "first-party-apps"))) {
    if (ops[op.name]) throw new Error(`${op.owner} declares ${op.name}, which ${ops[op.name]!.owner ?? `the ${ops[op.name]!.source} catalog`} already owns`)
    ops[op.name] = { class: op.class, risk: op.risk, docs: op.docs, source: "app", owner: op.owner, input: op.input, output: op.output }
  }
  return { ops, types: { ...cloud.types, ...local.types }, generics: { ...(cloud.generics ?? {}), ...(local.generics ?? {}) }, actions: actions.filter((a) => a.cli === "offered").map((a) => a.id).sort() }
}

const ident = (s: string) => (/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(s) ? s : JSON.stringify(s))

function tsType(t: TypeIR | undefined, depth = 0): string {
  if (!t || depth > 8) return "unknown"
  switch (t.kind) {
    case "primitive": {
      const n = t.name as string
      if (n === "bool" || n === "boolean") return "boolean"
      if (/^(u?int|float|double|number)/.test(n)) return "number"
      return "string" // decimal, string, int64 and timestamps travel as strings or numbers; keep strings for decimals
    }
    case "resource_id": return `string /* ${String(t.resource)}_… */`
    case "ref": return `Cmux.${t.name as string}`
    case "array": return `Array<${tsType((t.items as TypeIR) ?? (t.value as TypeIR), depth + 1)}>`
    case "map": return `Record<string, ${tsType(t.values as TypeIR, depth + 1)}>`
    case "nullable": return `${tsType((t.value as TypeIR) ?? (t.inner as TypeIR), depth + 1)} | null`
    case "enum": return (t.values as string[]).map((v) => JSON.stringify(v)).join(" | ") || "string"
    case "object": return objectType(t.fields as Record<string, Field> | undefined, depth)
    case "apply": return `Cmux.${t.name as string}<${((t.arguments as TypeIR[]) ?? []).map((a) => tsType(a, depth + 1)).join(", ")}>`
    case "parameter": case "generic": case "param": return (t.name as string) ?? "unknown"
    default: return "unknown"
  }
}

function objectType(fields: Record<string, Field> | undefined, depth: number): string {
  const entries = Object.entries(fields ?? {})
  if (!entries.length) return "Record<string, never>"
  return `{ ${entries.map(([k, f]) => `${ident(k)}${f.required ? "" : "?"}: ${tsType(f.type, depth + 1)}`).join("; ")} }`
}

function paramsType(op: Op): string {
  if (op.source === "app") return schemaType(op.input)
  const parts: string[] = []
  for (const [sel, need] of Object.entries(op.params?.selectors ?? {})) {
    // The host fills machine and session with the current ones, so they are optional for apps.
    const optional = need !== "required" || sel === "machine" || sel === "session"
    parts.push(`${ident(sel)}${optional ? "?" : ""}: string`)
  }
  for (const [k, f] of Object.entries(op.params?.fields ?? {})) parts.push(`${ident(k)}${f.required ? "" : "?"}: ${tsType(f.type)}`)
  return parts.length ? `{ ${parts.join("; ")} }` : "Record<string, never>"
}

export function generate(): Record<string, string> {
  const { ops, types, generics } = loadCatalog()
  const names = Object.keys(ops).sort()
  const scopes: Record<string, { scope: string; class: string }> = {}
  const never: string[] = []
  for (const name of names) {
    const s = scopeFor(name, ops[name]!)
    if (s) scopes[name] = { scope: s, class: ops[name]!.class }
    else never.push(name)
  }
  // Host-provided ops that are not in the catalogs yet.
  const hostOps: Record<string, { scope: string; class: string }> = {
    "action.run": { scope: "actions:run", class: "mutation" },
    "action.list": { scope: "actions:run", class: "read" },
    "app.storage.get": { scope: "storage:local", class: "read" },
    "app.storage.set": { scope: "storage:local", class: "mutation" },
    "app.storage.delete": { scope: "storage:local", class: "mutation" },
    "app.storage.keys": { scope: "storage:local", class: "read" },
    "net.fetch": { scope: "net:<host>", class: "runtime" },
    "clipboard.write": { scope: "clipboard:write", class: "mutation" },
    "integration.request": { scope: "integration:<provider>", class: "runtime" },
    // Mac-side app ops (AppHostCapabilities in CmuxNextApp; APP-R1 provider channel later).
    "coderouter.status": { scope: "coderouter:read", class: "read" },
    "coderouter.accounts.list": { scope: "coderouter:read", class: "read" },
    "coderouter.usage.get": { scope: "coderouter:read", class: "read" }
  }
  Object.assign(scopes, hostOps)

  // d.ts: nested namespaces by family.
  type Tree = { ops: Array<[string, string]>; children: Map<string, Tree> }
  const root: Tree = { ops: [], children: new Map() }
  for (const name of names) {
    if (!scopes[name]) continue
    const parts = name.split(".")
    let node = root
    for (const p of parts.slice(0, -1)) {
      if (!node.children.has(p)) node.children.set(p, { ops: [], children: new Map() })
      node = node.children.get(p)!
    }
    const op = ops[name]!
    const owner = op.source === "app" && op.owner ? `, owner \`${op.owner}\`` : ""
    const doc = `/** \`${name}\` (${op.class}, scope \`${scopes[name]!.scope}\`${owner})${op.docs ? `: ${op.docs}` : ""} */`
    const result = op.source === "app" ? (op.output ? schemaType(op.output) : "unknown") : tsType(op.result)
    node.ops.push([parts.at(-1)!, `${doc}\n${ident(parts.at(-1)!)}: CmuxOp<${paramsType(op)}, ${result}>`])
  }
  const render = (t: Tree, indent: string): string => {
    const lines: string[] = []
    const keys = new Set([...t.ops.map(([k]) => k), ...t.children.keys()])
    for (const k of [...keys].sort()) {
      const opLine = t.ops.find(([n]) => n === k)
      const child = t.children.get(k)
      if (opLine && child) lines.push(`${indent}${opLine[1].replace(/\n/g, `\n${indent}`).replace(/;?$/, "")} & {\n${render(child, indent + "  ")}\n${indent}}`)
      else if (opLine) lines.push(`${indent}${opLine[1].replace(/\n/g, `\n${indent}`)}`)
      else lines.push(`${indent}${ident(k)}: {\n${render(child!, indent + "  ")}\n${indent}}`)
    }
    return lines.join("\n")
  }
  const typeDecls = [
    ...Object.entries(types).sort(([a], [b]) => a.localeCompare(b)).map(([n, t]) => `  type ${n} = ${tsType(t as TypeIR)}`),
    ...Object.entries(generics).sort(([a], [b]) => a.localeCompare(b)).map(([n, g]) => `  type ${n}<${g.parameters.join(", ")}> = ${tsType(g.body)}`)
  ]
  const dts = `// Generated by cmux-tui/crates/cmux-app-host/tools/gen-cmux-global.ts. Do not edit.
// cmux app API ${API_VERSION}. Every op is checked by the host against the app's granted scopes.

declare namespace Cmux {
${typeDecls.join("\n")}
}

interface CmuxAbortSignal { readonly aborted: boolean; readonly reason: unknown; onabort: ((ev: { type: "abort" }) => void) | null; addEventListener(type: "abort", fn: () => void): void; removeEventListener(type: "abort", fn: () => void): void; throwIfAborted(): void }
interface CmuxCallOptions { idempotencyKey?: string; expectedRevision?: string; gesture?: string; /** Rejects the call with \`aborted\` when the signal fires. */ signal?: CmuxAbortSignal }
type CmuxOp<P, R> = ((params?: P, options?: CmuxCallOptions) => Promise<R>) & { readonly opName: string }
type CmuxSignal<T> = () => T
interface CmuxLive<T> { (): T | undefined; error(): CmuxError | null; loading(): boolean; refresh(): void }
declare class CmuxError extends Error { readonly code: string; readonly details?: unknown; readonly retryable: boolean }
interface CmuxFetchResponse { status: number; ok: boolean; headers: Record<string, string>; text(): string; json<T = unknown>(): T }
// App action ids are not enumerated here: the registry changes daily. List them at runtime with cmux.actions.list().
type CmuxActionId = string

interface CmuxGlobal {
${render(root, "  ")}
  call<T = unknown>(name: string, params?: unknown, options?: CmuxCallOptions): Promise<T>
  live<T = unknown>(op: string | { opName: string }, params?: unknown, options?: { events?: string[]; select?: (v: unknown) => T }): CmuxLive<T>
  events: { on(stream: string, fn: (payload: unknown) => void, filter?: unknown): () => void }
  actions: { run(id: CmuxActionId | (string & {}), args?: Record<string, unknown>): Promise<unknown> }
  storage: { get<T = unknown>(key: string): Promise<T | null>; set(key: string, value: unknown): Promise<unknown>; delete(key: string): Promise<unknown>; keys(): Promise<string[]> }
  net: { fetch(url: string, init?: { method?: string; headers?: Record<string, string>; body?: string }): Promise<CmuxFetchResponse> }
  integrations: Record<string, { request(params: { method: string; path: string; body?: unknown }): Promise<unknown> }>
  timer: { after(ms: number, fn: () => void): number; every(ms: number, fn: () => void): number; clear(id: number): void }
  app: { readonly id: string; readonly version: string; readonly apiVersion: string; readonly locale: string; settings: { (): Record<string, unknown>; set(values: Record<string, unknown>): Promise<unknown> } }
  /** The current user-gesture token, else null. On a command's ctx.cmux: the invocation's token while the command runs. On the global: the event token, only inside a user event handler before its first await; pass it as options.gesture later. */
  gesture(): string | null
  /** The app's string for key in the user's locale, else fallback; {name} placeholders. */
  t(key: string, fallbackOrParams?: string | Record<string, unknown>, params?: Record<string, unknown>): string
  palette: CmuxPalette
  act: typeof act
  log(...parts: unknown[]): void
}
declare const cmux: CmuxGlobal

// Palette scopes (contributes.paletteScopes). Items are plain data: at most 2 KiB each, 10000 per snapshot, 200 per batch, no functions.
/** A typed reference to a catalog action or op, or an app command \`app:<id>#<command>\`. */
interface CmuxActionRef { id: string; args: Record<string, unknown>; title?: string; symbol?: string }
interface CmuxPaletteItem {
  id: string; title: string; subtitle?: string; symbol?: string; keywords?: string[]
  accessory?: { date?: number | string; text?: string; badge?: string | number; symbol?: string }
  /** Return runs the first, Cmd-Return the second; Tab (default drill) lists them all. */
  actions?: CmuxActionRef[]
  /** Tab drills into this scope with the item as context (default \`actions\`). */
  drill?: string
  /** A scope row: Return or Tab enters this scope. */
  enters?: string
}
interface CmuxPaletteContext { readonly scope: string; readonly generation: number; readonly signal: CmuxAbortSignal; readonly context?: string; readonly filter?: string; readonly session?: string }
interface CmuxPaletteDetail { markdown?: string; metadata?: Array<{ label: string; value: string; symbol?: string }>; actions?: CmuxActionRef[] }
interface CmuxPaletteCached { readonly __cmuxPaletteCached: true }
type CmuxPaletteSource<F> = F & { readonly __cmuxPaletteKind: "snapshot" | "query" | "detail" }
interface CmuxPalette {
  /** The whole candidate set; the host ranks it and caches it. Runs once per invalidation, never per keystroke. */
  snapshot(fn: (ctx: CmuxPaletteContext) => CmuxPaletteItem[] | Promise<CmuxPaletteItem[]>): CmuxPaletteSource<(ctx: CmuxPaletteContext) => Promise<CmuxPaletteItem[]>>
  /** Per query: every \`yield\` is a batch; a new query aborts the old generator through \`ctx.signal\`. */
  query(fn: (query: string, ctx: CmuxPaletteContext) => AsyncIterable<CmuxPaletteItem[] | CmuxPaletteCached> | Promise<CmuxPaletteItem[]>): CmuxPaletteSource<(query: string, ctx: CmuxPaletteContext) => unknown>
  /** Detail of the highlighted row (layout listWithDetail). */
  detail(fn: (itemId: string, ctx: { scope: string; signal: CmuxAbortSignal }) => CmuxPaletteDetail | null | Promise<CmuxPaletteDetail | null>): CmuxPaletteSource<(itemId: string) => unknown>
  /** Yield from a query source: the last complete result of the longest cached prefix of the query (provisional until the first live batch). */
  cached(): CmuxPaletteCached
}
declare const palette: CmuxPalette
declare function act(op: string, args?: Record<string, unknown>, overrides?: { title?: string; symbol?: string }): CmuxActionRef
/** The second argument of a command export. \`cmux\` here carries the invocation's user gesture until the command settles (origin user); the global \`cmux\` does not. */
interface CmuxCommandContext { readonly app: { id: string; version: string }; readonly gesture?: string; readonly cmux: CmuxGlobal }

// Reactivity and views (the old cmux JS sidebar API).
declare function signal<T>(initial: T): [CmuxSignal<T>, (next: T | ((prev: T) => T)) => void]
declare function computed<T>(fn: () => T): CmuxSignal<T>
declare function effect(fn: () => void): () => void
declare function onCleanup(fn: () => void): void
declare function untrack<T>(fn: () => T): T
type Bindable<T> = T | (() => T)
interface CmuxView {
  font(v: Bindable<string | number>): this; weight(v: Bindable<string>): this; bold(): this; italic(): this; monospaced(): this
  color(v: Bindable<string | null>): this; secondary(): this; lineLimit(v: Bindable<number>): this; truncation(v: Bindable<"head" | "middle" | "tail">): this
  marquee(delaySeconds?: number): this; fade(width: Bindable<number>): this
  padding(v?: Bindable<number | Record<string, number>>): this; paddingHorizontal(v: Bindable<number>): this; paddingVertical(v: Bindable<number>): this
  frame(v: Bindable<Record<string, number | string>>): this; layoutPriority(v: Bindable<number>): this; fixedSize(axis?: "both" | "horizontal" | "vertical"): this
  background(v: Bindable<string | null>): this; hoverBackground(v: Bindable<string | null>): this; cornerRadius(v: Bindable<number>): this
  borderColor(v: Bindable<string | null>): this; borderWidth(v: Bindable<number>): this; opacity(v: Bindable<number>): this
  fill(v: Bindable<string | null>): this; stroke(v: Bindable<string | null>): this; strokeWidth(v: Bindable<number>): this; size(v: Bindable<number>): this
  rotation(degrees: Bindable<number>): this; cursor(v: "pointer" | "default"): this; help(v: Bindable<string>): this
  fixed(): this; destructive(): this; disabled(v?: Bindable<boolean>): this; onTap(fn: () => unknown): this; contextMenu(items: CmuxView[] | (() => CmuxView[])): this
}
type CmuxChildren = Array<CmuxView | (() => unknown) | null | undefined | false>
interface CmuxListSpec<T> { items: () => readonly T[] | null | undefined; key: (item: T, index: number) => string | number; onMove?: (id: string, index: number, extra: { side?: string; block?: boolean }) => unknown; onDragChange?: (state: unknown) => unknown; spacing?: number }
declare function VStack(propsOrChildren?: Record<string, unknown> | CmuxChildren, children?: CmuxChildren): CmuxView
declare function HStack(propsOrChildren?: Record<string, unknown> | CmuxChildren, children?: CmuxChildren): CmuxView
declare function ZStack(propsOrChildren?: Record<string, unknown> | CmuxChildren, children?: CmuxChildren): CmuxView
declare function LazyVStack(propsOrChildren?: Record<string, unknown> | CmuxChildren, children?: CmuxChildren): CmuxView
declare function Group(propsOrChildren?: Record<string, unknown> | CmuxChildren, children?: CmuxChildren): CmuxView
declare function Text(text: Bindable<string | number | null | undefined>): CmuxView
declare function Icon(name: Bindable<string>): CmuxView
declare function Image(source: Bindable<string> | { systemName: Bindable<string> }): CmuxView
declare function Button(label: Bindable<string> | CmuxView, action?: () => unknown): CmuxView
declare function Menu(title: Bindable<string>, items: CmuxView[]): CmuxView
declare function Spacer(): CmuxView
declare function Divider(): CmuxView
declare function Circle(props?: Record<string, unknown>): CmuxView
declare function Capsule(props?: Record<string, unknown>): CmuxView
declare function Rectangle(props?: Record<string, unknown>): CmuxView
declare function RoundedRectangle(props?: Record<string, unknown>): CmuxView
declare function ProgressView(value?: Bindable<number | null>): CmuxView
declare function TextField(value: Bindable<string>, options?: { placeholder?: string; autofocus?: boolean; onSubmit?: (t: string) => unknown; onEdit?: (t: string) => unknown; onCancel?: () => unknown }): CmuxView
declare function Row(props: { title: Bindable<string>; subtitle?: Bindable<string | null>; symbol?: Bindable<string | null>; badge?: Bindable<string | number | null>; unread?: Bindable<boolean>; selected?: Bindable<boolean>; tint?: Bindable<string | null>; accessory?: Bindable<string | null> }): CmuxView
declare function Badge(text: Bindable<string | number>, tone?: Bindable<string>): CmuxView
declare function EmptyState(props: { title: Bindable<string>; message?: Bindable<string>; symbol?: Bindable<string> }): CmuxView
declare function ForEach<T>(spec: CmuxListSpec<T>, template: (item: CmuxSignal<T>, key: string) => CmuxView): CmuxView
declare function Reorderable<T>(spec: CmuxListSpec<T>, template: (item: CmuxSignal<T>, key: string) => CmuxView): CmuxView
`
  const scopesJson = JSON.stringify({ apiVersion: API_VERSION, ops: Object.fromEntries(Object.entries(scopes).sort(([a], [b]) => a.localeCompare(b))), never: never.sort() }, null, 2) + "\n"
  const opsJson = JSON.stringify({ apiVersion: API_VERSION, ops: Object.keys(scopes).sort() }, null, 2) + "\n"
  return { "cmux-app.d.ts": dts, "scopes.json": scopesJson, "ops.json": opsJson }
}

if (import.meta.main) {
  const files = generate()
  const check = process.argv.includes("--check")
  let stale = false
  for (const [name, content] of Object.entries(files)) {
    const path = join(outDir, name)
    const current = existsSync(path) ? readFileSync(path, "utf8") : ""
    if (current === content) continue
    if (check) {
      console.error(`generated/${name} is stale: run bun tools/gen-cmux-global.ts`)
      stale = true
    } else writeFileSync(path, content)
  }
  if (stale) process.exit(1)
  console.log(check ? "generated files up to date" : "generated files written")
}
