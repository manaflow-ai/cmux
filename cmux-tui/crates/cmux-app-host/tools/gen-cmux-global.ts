#!/usr/bin/env bun
// Generates the typed `cmux` global for apps from the operation catalogs:
//   generated/cmux-app.d.ts  typed global (one method per op, TSDoc with class and scope)
//   generated/scopes.json    op name -> scope (the host's scope check and the consent UI)
//   generated/ops.json       op names
//   generated/signals.json   signal sources for cmux.watch (from schema/v2/signals.json)
//   schema/merged/            index, per-family op rows and type digests of the four op sources (drift check; no second copy)
//   generated/REFERENCE.md   the docs reference: ops, event streams and signal sources in tables
// Sources until the merged D7 catalog exists: cmux-tui resource ops, cloud ops,
// app actions, and every first-party app's catalog fragment (app-catalogs.ts).
// `--check` exits 1 when a generated file is stale.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { createHash } from "node:crypto"
import { dirname, join } from "node:path"
import { loadAppCatalogs, schemaType } from "./app-catalogs.ts"
import { SchemaValidator } from "./json-schema.ts"
import { referenceMarkdown } from "./gen-reference.ts"
import { createCmux } from "../js/src/cmux.ts"

const here = new URL(".", import.meta.url).pathname
const repo = join(here, "../../../..")
const outDir = join(here, "../generated")
export const API_VERSION = "1.0.0"

type TypeIR = { kind: string; [k: string]: unknown }
interface Field { required: boolean; type: TypeIR; description?: string }
interface Op {
  class: string; risk?: string; params?: { selectors?: Record<string, string>; fields?: Record<string, Field> }; result?: TypeIR; docs?: string
  source: "local" | "cloud" | "app"
  /** Backend ops: who may call it; an op without "install" is for a signed-in person only. */
  principals?: string[]
  /** App catalog ops: the owning app and JSON Schema input/output instead of params/result. */
  owner?: string; input?: Record<string, unknown>; output?: Record<string, unknown>
}

/** Op families that share one scope family. */
const SCOPE_FAMILY: Record<string, string> = { tab: "workspace", pane: "workspace", screen: "workspace", window: "workspace", session: "session", frontend_projection: "client" }
/** Families apps never reach in phase 1 (grants, installs, accounts, pairing, raw client plumbing, origin confirmations, launch credentials, browser page history). */
const NEVER_FAMILIES = new Set(["install", "grant", "host", "pairing_request", "client", "request", "stream", "frontend_projection", "user", "app", "origin", "credential", "history"])
const EXECUTE = /(^terminal\.input\.(write|keys|mouse)$|\.run$|^terminal\.(attach|project)$|^browser\.input\.|^session\.journal\.hook\.put$)/
// team_vm.retired.export (cx-lyvg) hands out the whole team's files: a person's session only, never an app.
// team.audit.list and team.members.remove (cx-3bi.4): the audit chain and member removal are a person's session only.
// agent.message.list/mark/release/send/unsend (#16430): no app access to agent messages until the agent-inbox lane designs a scoped
// grant. An app that sends to an agent is a prompt-injection path; an app that reads them sees the agent's context.
// settings.set/reset/reset_all/edit (cx-9ce.10): the settings file is the person's; an app may read settings only.
// layout.bulk (cx-gzh.5) closes tabs, panes, screens and workspaces, like every .close op.
// workspace.open_url (cx-ebm.59.3) navigates the person's browser tabs; Home and the person's tools only.
// conductor_import.plan/record read Conductor's database and worktrees and keep the import ledger: the app's
// own Import from Conductor only.
// classic_import.plan/record read classic cmux's session files and keep the migration ledger: the app's own
// move from classic cmux only.
// browser_import.read reads another browser's bookmarks, history and tabs by path: the app's own browser
// import only (the daemon also refuses any origin but the verified app).
// language_packs.ensure downloads the app's languages into its own cache by path: the app itself only.
// palette.rank ranks rows for a cmux page's own palette (the Channels page); apps have `cmux.palette`, the
// app palette, so the op family would collide with it.
const NEVER = /(^settings\.(set|reset|reset_all|edit)$|^layout\.bulk$|^keybindings\.(set|remove|reset)$|\.close$|\.shutdown$|^session\.(open|reload_config|creation\.resolve)$|\.renderer_grant\.|\.history\.clear$|^workspace\.agent_(folder|start)\.|^workspace\.open_url$|^conductor_import\.|^browser_import\.|^language_packs\.|^classic_import\.|^palette\.rank$|^team_vm\.retired\.export$|^team\.(audit\.list|members\.remove)$|^agent\.message\.(list|mark|release|send|unsend)$|^diff\.comments\.send$)/

/** The daemon's Cloud API calls carry the person's own access token in their params; the app's own Cloud code only. */
const CLOUD_API_CALLS = [
  "cloud.machine.chat_access",
  "cloud.machine.io",
  "cloud.machine.share_chat",
  "cloud.machine.chief_start",
  "cloud.machine.chief_resize",
  "cloud.owner.acpmux_keyed_start",
  "cloud.owner.acpmux_person_holds",
  "cloud.owner.fork_run",
  "cloud.owner.github_app",
  "cloud.owner.github_connect",
  "cloud.owner.github_repos",
  "cloud.owner.handoff_begin_turn",
  "cloud.owner.handoff_open",
  "cloud.owner.handoff_wait",
  "cloud.owner.handoffs",
  "cloud.owner.harness_login_copy",
  "cloud.owner.turn_checkpoint",
  "cloud.owner.turn_rewind",
  "cloud.owner.turns",
  "cloud.previews.create_link",
  "cloud.previews.refresh",
  "cloud.previews.revoke_link",
  "cloud.runs.cancel",
  "cloud.runs.create",
  "cloud.runs.sandbox",
  "cloud.runs.start",
  "cloud.runs.wait",
  "cloud.vm.domains",
  "cloud.vm.firewall_create",
  "cloud.vm.firewall_delete",
  "cloud.vm.firewall_get",
  "cloud.vm.firewall_list",
  "cloud.vm.networks",
  "cloud.vm.provision_api",
  "cloud.vm.publication_api_keys",
  "cloud.vm.publications",
  "cloud.vm.revoke_publication_api_key",
  "cloud.vm.scp_endpoint",
  "cloud.vm.tunnel_attach",
  "cloud.vm.tunnel_detach",
  "cloud.vm.tunnel_enroll",
  "cloud.vm.tunnel_revoke",
  "cloud.vm.tunnel_rotate_key",
]

/** Ops no app may call, whatever their risk (cloud.machine.link_token mints dial tokens). */
export const NEVER_OPS = new Set(["cloud.machine.link_token", ...CLOUD_API_CALLS])

const readJSON = (p: string) => JSON.parse(readFileSync(join(repo, p), "utf8"))

export function scopeFor(name: string, op: Pick<Op, "class" | "risk" | "principals">): string | null {
  const family = name.split(".")[0]!
  if (NEVER_FAMILIES.has(family) || NEVER.test(name) || NEVER_OPS.has(name)) return null
  // Money moves and person-only ops (no install principal) never reach apps.
  if (op.risk === "money" || (op.principals && !op.principals.includes("install"))) return null
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

/** The merged schema directory, relative to generated/. */
export const MERGED_DIR = "../schema/merged"

const digest = (v: unknown): string => createHash("sha256").update(JSON.stringify(v)).digest("hex").slice(0, 16)

/**
 * The merged schema directory: one small file per op family (ops/<family>.json: each op's source, owner,
 * class, risk and a digest of its whole definition), types.json (a digest per type and generic) and
 * index.json (version, families, offered actions). The definitions stay in their four sources, so no
 * clone carries a second copy; a change to any of them changes a digest, and `--check` fails until the
 * directory is regenerated.
 */
function mergedFiles(ops: Record<string, Op>, types: Record<string, TypeIR>, generics: Record<string, unknown>, actions: string[]): Record<string, string> {
  const out: Record<string, string> = {}
  const json = (v: unknown) => JSON.stringify(v, null, 2) + "\n"
  const byFamily: Record<string, Record<string, unknown>> = {}
  for (const name of Object.keys(ops).sort()) {
    const op = ops[name]!
    const family = name.split(".")[0]!
    ;(byFamily[family] ??= {})[name] = { source: op.source, ...(op.owner ? { owner: op.owner } : {}), class: op.class, ...(op.risk ? { risk: op.risk } : {}), digest: digest(op) }
  }
  const families = Object.keys(byFamily).sort()
  for (const f of families) out[`${MERGED_DIR}/ops/${f}.json`] = json({ family: f, ops: byFamily[f] })
  const digests = (o: Record<string, unknown>) => Object.fromEntries(Object.keys(o).sort().map((k) => [k, digest(o[k])]))
  out[`${MERGED_DIR}/types.json`] = json({ types: digests(types), generics: digests(generics) })
  out[`${MERGED_DIR}/index.json`] = json({ apiVersion: API_VERSION, families, offeredActions: actions })
  return out
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

const SIGNALS = join(here, "../schema/v2/signals.json")
const EVENTS = join(here, "../schema/v2/events.json")
const SIGNALS_SCHEMA = join(here, "../schema/v2/signals.schema.json")

interface SignalDef {
  docs: string; scopes: string[]; params: Record<string, unknown>; value: Record<string, unknown>
  read: { op: string } | { reader: string; ops: Array<{ op: string; scope: string; docs: string }> }
  push: string[]; pollFloorSeconds: number; staleAfterSeconds: number; safetyPollSeconds?: number
}

/** A value or params schema as TS: schemaType plus `{"$ref": "cmux:types/<Name>"}` for catalog types. */
function signalType(schema: unknown, types: Record<string, unknown>, depth = 0): string {
  if (!schema || typeof schema !== "object" || depth > 8) return "unknown"
  const s = schema as Record<string, unknown>
  if (typeof s.$ref === "string") {
    const name = /^cmux:types\/([A-Za-z0-9_]+)$/.exec(s.$ref)?.[1]
    if (!name || !(name in types)) throw new Error(`signals.json: unknown type ${s.$ref}`)
    return `Cmux.${name}`
  }
  if (s.type === "array") return `Array<${signalType(s.items, types, depth + 1)}>`
  if (s.type === "object" && s.properties) {
    const required = new Set((s.required ?? []) as string[])
    const props = Object.entries(s.properties as Record<string, Record<string, unknown>>)
    return `{ ${props.map(([k, v]) => `${typeof v.description === "string" ? `/** ${v.description.replace(/\*\//g, "* /")} */ ` : ""}${ident(k)}${required.has(k) ? "" : "?"}: ${signalType(v, types, depth + 1)}`).join("; ")} }`
  }
  return schemaType(s, depth)
}

/**
 * schema/v2/signals.json, checked against its schema, every read op and scope against the catalog,
 * as the runtime's table (generated/signals.json) and the d.ts name -> {params, value} map.
 */
export function loadSignals(scopes: Record<string, { scope: string; class: string }>, types: Record<string, unknown>): { json: string; dts: string } {
  const file = JSON.parse(readFileSync(SIGNALS, "utf8")) as { signals: Record<string, SignalDef> }
  const errors = new SchemaValidator(JSON.parse(readFileSync(SIGNALS_SCHEMA, "utf8"))).validate(file)
  if (errors.length) throw new Error(`schema/v2/signals.json: ${errors.map((e) => `${e.path || "/"} ${e.message}`).join("; ")}`)
  const names = Object.keys(file.signals).sort()
  const lines: string[] = []
  for (const name of names) {
    const def = file.signals[name]!
    const ops = "op" in def.read ? [{ op: def.read.op, scope: scopes[def.read.op]?.scope ?? "" }] : def.read.ops
    for (const { op, scope } of ops) {
      const known = scopes[op]
      if (!known) throw new Error(`signals.json: ${name} reads ${op}, which apps cannot call`)
      if (known.class !== "read" && known.class !== "runtime") throw new Error(`signals.json: ${name} reads ${op}, which is not a read (${known.class})`)
      const fits = known.scope === scope || (known.scope.includes("<") && new RegExp(`^${known.scope.replace(/<[a-z]+>/g, "[^:]+")}(:read)?$`).test(scope))
      if (!fits) throw new Error(`signals.json: ${name} says ${op} needs ${scope}, the catalog says ${known.scope}`)
      if (!def.scopes.includes(scope)) throw new Error(`signals.json: ${name} reads ${op} with ${scope}, which its scopes do not list`)
    }
    if (def.staleAfterSeconds < def.pollFloorSeconds) throw new Error(`signals.json: ${name} goes stale before it may be polled again`)
    if (def.safetyPollSeconds !== undefined && !def.push.length) throw new Error(`signals.json: ${name} has safetyPollSeconds but nothing pushes it`)
    if (def.safetyPollSeconds !== undefined && def.safetyPollSeconds < def.staleAfterSeconds) throw new Error(`signals.json: ${name} re-reads faster while pushed than while polled`)
    const pushedBy = def.push.map((p) => `\`${p}\``).join(", ")
    const how = !def.push.length
      ? `polled every ${def.staleAfterSeconds} s (never faster than ${def.pollFloorSeconds} s): nothing pushes it yet`
      : def.safetyPollSeconds === undefined
        ? `pushed by ${pushedBy}`
        : `pushed by ${pushedBy} from outside this machine: while that push is live it re-reads every ${def.safetyPollSeconds} s, and until it is, it polls every ${def.staleAfterSeconds} s (never faster than ${def.pollFloorSeconds} s)`
    lines.push(`  /** \`${name}\`: ${def.docs.replace(/\*\//g, "* /")} Scope: any of ${def.scopes.map((s) => `\`${s}\``).join(", ")}; ${how}. */`)
    lines.push(`  ${JSON.stringify(name)}: { params: ${signalType(def.params, types)}; value: ${signalType(def.value, types)} }`)
  }
  const table = Object.fromEntries(names.map((n) => [n, file.signals[n]]))
  return { json: JSON.stringify({ version: 1, signals: table }, null, 2) + "\n", dts: lines.join("\n") }
}

/**
 * schema/v2/events.json, each stream's `reads` op checked against the catalog: the daemon delivers a
 * stream only to an app that may call its `reads` op (apps/subscriptions.rs declared_reads), so that op's
 * scope is the stream's scope.
 */
export function loadEvents(scopes: Record<string, { scope: string; class: string }>): Record<string, { docs: string; reads: string; scope: string }> {
  const file = JSON.parse(readFileSync(EVENTS, "utf8")) as { version: number; events: Record<string, { docs: string; reads: string; readsParams?: Record<string, unknown>; scope?: string }> }
  if (file.version !== 1) throw new Error(`schema/v2/events.json: version ${file.version}, expected 1`)
  const out: Record<string, { docs: string; reads: string; scope: string }> = {}
  for (const name of Object.keys(file.events).sort()) {
    const { docs, reads, readsParams, scope } = file.events[name]!
    const family = name.match(/^([a-z][a-z0-9_]*)\.changed$/)?.[1]
    if (!family) throw new Error(`events.json: ${name} is not <family>.changed`)
    const known = scopes[reads]
    if (!known) throw new Error(`events.json: ${name} reads ${reads}, which apps cannot call`)
    // A host op that reads (integration.request as a GET) is a read once readsParams say so.
    const reading = known.class === "read" || (known.class === "runtime" && readsParams !== undefined && String(readsParams.method ?? "GET").toUpperCase() === "GET")
    if (!reading) throw new Error(`events.json: ${name} reads ${reads}, which is not a read (${known.class})`)
    // A scope with a <placeholder> needs the stream's own narrowed scope, which must fit it.
    if (known.scope.includes("<") !== (scope !== undefined)) throw new Error(`events.json: ${name} must name its scope exactly when ${reads}'s scope (${known.scope}) has a placeholder`)
    if (scope !== undefined && !new RegExp(`^${known.scope.replace(/<[a-z]+>/g, "[^:]+")}(:read)?$`).test(scope)) throw new Error(`events.json: ${name} says ${scope}, which ${reads}'s scope ${known.scope} does not fit`)
    out[name] = { docs, reads, scope: scope ?? known.scope }
  }
  return out
}

export function generate(): Record<string, string> {
  const { ops, types, generics, actions } = loadCatalog()
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
    // A notice in the app's own toast presenter, one slot per app (ToastAppOps in CmuxNextApps). Local and
    // non-network, so no grant: scope `none` is always held.
    "toast.show": { scope: "none", class: "mutation" },
    // Extension signal sources (cmux.signal.source/1, cmux-tui-core apps/signal_sources.rs). Scope `none` here:
    // the daemon decides each call per source (only the declaring app publishes; a reader needs the source's
    // `<app namespace>:read` scope).
    "signal.publish": { scope: "none", class: "mutation" },
    "signal.read": { scope: "none", class: "read" },
    "signal.sources.list": { scope: "none", class: "read" },
    "integration.request": { scope: "integration:<provider>", class: "runtime" },
    // Mac-side app ops (AppHostCapabilities in CmuxNextApp, served over the provider channel).
    "coderouter.status": { scope: "coderouter:read", class: "read" },
    "agent_cli.list": { scope: "agent_cli:read", class: "read" },
    "coderouter.detect": { scope: "coderouter:read", class: "read" },
    "coderouter.accounts.list": { scope: "coderouter:read", class: "read" },
    "coderouter.usage.get": { scope: "coderouter:read", class: "read" },
    // The Agent Memory app's search, from the agent memory index (optchat-chief agent-memory).
    "memory.search": { scope: "memory:read", class: "read" },
    // The older name of chat.list for a customize section's thread list: the daemon answers it
    // from the same chat index as chat.list (apps/routing.rs), shaped {chats: [...]}.
    "agent_chat.list": { scope: "agent_chat:read", class: "read" },
    // A browser tab's page in the Mac app (PageAppOps in CmuxNextApps): reader-mode text and links,
    // and link hints drawn and followed by the built-in hints' own scripts. Hints and follow need a gesture.
    "page.read": { scope: "page:read", class: "read" },
    "page.hints": { scope: "page:write", class: "mutation" },
    "page.follow": { scope: "page:write", class: "mutation" },
    // What plays in cmux, from the Now Playing card's sources (cmux's player, a browser tab, another
    // app while sidebar.nowPlaying.otherApps is on), answered by the Mac app (MediaAppOps). media.control
    // runs only on a tap (PLAYBACK_OPS in cmux-app-manifest capabilities.rs).
    "media.get": { scope: "media:read", class: "read" },
    "media.control": { scope: "media:control", class: "mutation" },
    // The person's system calendar on the Mac (CalendarAppOps in CmuxNextApps, EventKit), apart from the
    // Cloud's Google `calendar.*` family: events
    // never prompts; request_access shows the system prompt, so it needs a gesture.
    "system_calendar.events": { scope: "system_calendar:read", class: "read" },
    "system_calendar.request_access": { scope: "system_calendar:read", class: "mutation" }
  }
  Object.assign(scopes, hostOps)
  const signals = loadSignals(scopes, types)

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
  // `cmux.<name>` answers the runtime's own member first (js/src/cmux.ts createCmux), so a catalog
  // family with a member's name (`theme.scheme.*`, `integrations.*`) is unreachable as
  // `cmux.theme.scheme`; declaring it too made TypeScript type `cmux.theme` as the family. Leave
  // it out here; those ops stay callable as `cmux.call("theme.scheme.convert", ...)`.
  const runtimeMembers = new Set(Reflect.ownKeys(createCmux(() => undefined)).filter((k): k is string => typeof k === "string"))
  for (const name of runtimeMembers) root.children.delete(name)
  root.ops = root.ops.filter(([k]) => !runtimeMembers.has(k))
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

interface CmuxAppContext { readonly [key: string]: unknown }

/** One block of a page's main text (\`page.read\`): a heading has \`level\` (1-6), an image \`src\` and its alt text. */
interface CmuxPageBlock { kind: "heading" | "paragraph" | "list_item" | "quote" | "code" | "image"; text: string; level?: number; src?: string }
/** \`page.read\`'s answer: the page's address and title, its main text as reader-mode blocks, and its links. */
interface CmuxPageRead {
  tab: string; url: string; title: string
  article: { title: string; byline: string | null; site: string | null; blocks: CmuxPageBlock[] }
  links: Array<{ text: string; href: string }>
}
/** A link-hint label \`page.hints\` drew: type it to \`page.follow\` it. \`href\` is null for a button, field or other non-link. */
interface CmuxPageHint { label: string; text: string; href: string | null }

/** Whether cmux may read the person's calendar: the system's answer, or \`unavailable\` where there is no system calendar (not macOS). */
type CmuxCalendarAccess = "granted" | "denied" | "restricted" | "notDetermined" | "unavailable"
/** One event of the person's calendar (\`system_calendar.events\`). Times are epoch ms; \`calendar\` is the calendar's title, \`color\` its color as \`#rrggbb\` when it has one. */
interface CmuxCalendarEvent { id: string; title: string; start: number; end: number; allDay: boolean; calendar: string; location?: string; url?: string; color?: string }
/** \`system_calendar.events\`' answer: the access status, and the events (empty unless \`access\` is \`granted\`). */
interface CmuxCalendarEvents { access: CmuxCalendarAccess; events: CmuxCalendarEvent[] }

interface CmuxGlobal {
${render(root, "  ")}
  call<T = unknown>(name: string, params?: unknown, options?: CmuxCallOptions): Promise<T>
  live<T = unknown>(op: string | { opName: string }, params?: unknown, options?: { events?: string[]; select?: (v: unknown) => T }): CmuxLive<T>
  /** A live, cached read of a signal source (schema/v2/signals.json): one upstream read per (name, params) however many sections watch it, pushed re-reads, polling only at the source's floor, stale-while-revalidate. See CmuxSignalMap for the sources. */
  watch: CmuxWatchFn
  events: { on(stream: string, fn: (payload: unknown) => void, filter?: unknown): () => void }
  actions: { run(id: CmuxActionId | (string & {}), args?: Record<string, unknown>): Promise<unknown> }
  storage: { get<T = unknown>(key: string): Promise<T | null>; set(key: string, value: unknown): Promise<unknown>; delete(key: string): Promise<unknown>; keys(): Promise<string[]> }
  net: { fetch(url: string, init?: { method?: string; headers?: Record<string, string>; body?: string }): Promise<CmuxFetchResponse> }
  integrations: Record<string, { request(params: { method: string; path: string; body?: unknown }): Promise<unknown> }>
  timer: { after(ms: number, fn: () => void): number; every(ms: number, fn: () => void): number; clear(id: number): void }
  /** Time zones. The sandbox has no Intl and \`toLocaleString\` ignores \`timeZone\`: \`zone(name, at?)\` gives an IANA zone's offset (minutes east of UTC) and short name at \`at\` (epoch ms, default now). An unknown name throws CmuxError \`zone.unknown\`. Local time is \`new Date(utcMs + offsetMinutes * 60000)\` read with the getUTC* methods. */
  time: { zone(name: string, at?: number): { zone: string; offsetMinutes: number; abbreviation: string } }
  app: { readonly id: string; readonly version: string; readonly apiVersion: string; readonly locale: string; settings: { (): Record<string, unknown>; set(values: Record<string, unknown>): Promise<unknown> }; context(): CmuxAppContext }
  /** The current user-gesture token, else null. On a command's ctx.cmux: the invocation's token while the command runs. On the global: the event token, only inside a user event handler before its first await; pass it as options.gesture later. */
  gesture(): string | null
  /** The app's string for key in the user's locale, else fallback; {name} placeholders. */
  t(key: string, fallbackOrParams?: string | Record<string, unknown>, params?: Record<string, unknown>): string
  /** The tone names color props accept (\`tint\`, \`tone\`, \`color\`, \`fill\`): drawn with the current theme, live. Never hard-code a color. */
  readonly theme: CmuxTheme
  /** A short notice from the app's own toast presenter; one slot per app (a new toast replaces the last). A string is the title. */
  toast(options: { title: string; message?: string; tone?: "success" | "warning" | "danger" } | string): Promise<null>
  /** A browser tab's page, drawn by the cmux app (WebKit or CEF). \`tab\` is a \`tab_…\` id; without it, the focused browser tab of the front window. */
  page: {
    /** \`page.read\` (read, scope \`page:read\`): the page's main text as reader-mode blocks, and its links. Text is capped (400 blocks, 500 links). */
    read: CmuxOp<{ tab?: string }, CmuxPageRead>
    /** \`page.hints\` (mutation, scope \`page:write\`, needs a gesture): \`show\` draws link-hint labels over the clickable elements in view (the built-in \`f\` labels) and lists them; \`clear\` removes them. A scroll removes them too. */
    hints: CmuxOp<{ tab?: string; action: "show" | "clear" }, { tab: string; hints: CmuxPageHint[] }>
    /** \`page.follow\` (mutation, scope \`page:write\`, needs a gesture): clicks the element of a shown hint, or with \`new_split\` opens its link in a new browser split (the built-in \`F\`), then clears the hints. \`followed\` is false when the label is not shown (any more), or \`new_split\` names a hint with no link. */
    follow: CmuxOp<{ tab?: string; label: string; new_split?: boolean }, { tab: string; followed: boolean; href: string | null }>
  }
  /** What plays in cmux, answered by the cmux app: the track the Now Playing card shows. To follow it live, \`cmux.watch("media.now_playing")\`. */
  media: {
    /** \`media.get\` (read, scope \`media:read\`): what plays now, or \`{track: null}\` while nothing does. */
    get: CmuxOp<Record<string, never>, CmuxSignalMap["media.now_playing"]["value"]>
    /** \`media.control\` (mutation, scope \`media:control\`, needs a gesture): play or pause, skip, or seek to \`seconds\` in. Throws CmuxError \`media.nothing_playing\` while nothing plays. */
    control: CmuxOp<{ command: "play_pause" | "previous" | "next" } | { command: "seek"; seconds: number }, null>
  }
  /** The person's system calendar, read by the cmux app on the Mac (EventKit). Not the Cloud's Google \`calendar.*\` ops. */
  system_calendar: {
    /** \`system_calendar.events\` (read, scope \`system_calendar:read\`): events from now (ones in progress too) through \`days\` (1-31, default 7), sorted by start, at most \`limit\` (1-50, default 20), from every calendar. Never prompts: without full access it answers the status and no events. */
    events: CmuxOp<{ days?: number; limit?: number }, CmuxCalendarEvents>
    /** \`system_calendar.request_access\` (mutation, scope \`system_calendar:read\`, needs a gesture): shows the system calendar prompt when the person has not answered it yet, and answers the access status. */
    request_access: CmuxOp<{}, { access: CmuxCalendarAccess }>
  }
  palette: CmuxPalette
  act: typeof act
  log(...parts: unknown[]): void
}
declare const cmux: CmuxGlobal

// Signals (cmux.watch). Generated from schema/v2/signals.json; the runtime's table is generated/signals.json.
interface CmuxSignalMap {
${signals.dts}
}
type CmuxSignalName = keyof CmuxSignalMap
/** loading: no value yet. fresh: the last read succeeded. stale: the value shown is being re-read, or the last re-read failed (error says why). error: no value and the read failed. */
type CmuxWatchStatus = "loading" | "fresh" | "stale" | "error"
interface CmuxWatchState<T> { readonly value: T | undefined; readonly status: CmuxWatchStatus; readonly error?: CmuxError; /** ms since the epoch of the last successful read, else null. */ readonly updatedAt: number | null }
/** Read it in a binding (\`() => prs().value\`), or one field at a time (\`prs.value\`) so only that field's readers re-run. */
interface CmuxWatch<T> {
  (): CmuxWatchState<T>
  value(): T | undefined
  status(): CmuxWatchStatus
  error(): CmuxError | undefined
  updatedAt(): number | null
  /** Re-reads now (coalesced with a read in flight); resolves with the state after it. */
  refresh(): Promise<CmuxWatchState<T>>
  /** Stops reading for this reader; automatic when the render or effect that called watch is disposed. */
  dispose(): void
}
interface CmuxWatchOptions { /** Poll this often while this reader is mounted; clamped up to the source's pollFloorSeconds. Ignored while a push is live. */ everySeconds?: number }
interface CmuxWatchFn {
  /** \`params\` may be a function: it is tracked, and the reader moves to the new (name, params) when its answer changes (a setting). */
  <N extends CmuxSignalName>(name: N, params?: CmuxSignalMap[N]["params"] | (() => CmuxSignalMap[N]["params"]), options?: CmuxWatchOptions): CmuxWatch<CmuxSignalMap[N]["value"]>
  /** Re-reads a source now for commands (a Refresh command); a section watching the same (name, params) shows the result. */
  refresh<N extends CmuxSignalName>(name: N, params?: CmuxSignalMap[N]["params"]): Promise<CmuxWatchState<CmuxSignalMap[N]["value"]>>
}
interface CmuxTheme {
  readonly accent: "accent"
  readonly text: { readonly primary: "primary"; readonly secondary: "secondary"; readonly tertiary: "tertiary" }
  readonly success: "success"; readonly warning: "warning"; readonly danger: "danger"
  readonly separator: "separator"; readonly hover: "hover"; readonly selected: "selected"
}

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
/** A gradient fill: 2 to 8 stops, each a color token or #RRGGBB[AA], spaced evenly; angle in degrees, the CSS way (0 up, 180 down, the default). */
type CmuxGradient = { linear: { colors: string[]; angle?: number } } | { radial: { colors: string[] } }
/** A color token, #RRGGBB[AA], or a gradient. */
type CmuxFill = string | CmuxGradient
interface CmuxView {
  font(v: Bindable<string | number>): this; weight(v: Bindable<string>): this; bold(): this; italic(): this; monospaced(): this
  /** The system font's design at the same type-scale size (heavy and rounded is the Lock Screen's time). */
  fontDesign(v: Bindable<"default" | "rounded" | "serif" | "monospaced">): this
  color(v: Bindable<string | null>): this; secondary(): this; lineLimit(v: Bindable<number>): this; truncation(v: Bindable<"head" | "middle" | "tail">): this
  strikethrough(v?: Bindable<boolean>): this; marquee(delaySeconds?: number): this; fade(width: Bindable<number>): this
  transition(v: "opacity" | "slide" | "scale" | "move"): this; contentTransition(v: "numericText" | "opacity"): this; animation(v?: "smooth" | "snappy" | "none"): this
  padding(v?: Bindable<number | Record<string, number>>): this; paddingHorizontal(v: Bindable<number>): this; paddingVertical(v: Bindable<number>): this
  frame(v: Bindable<Record<string, number | string>>): this; layoutPriority(v: Bindable<number>): this; fixedSize(axis?: "both" | "horizontal" | "vertical"): this
  background(v: Bindable<CmuxFill | null>): this; hoverBackground(v: Bindable<string | null>): this; glass(level?: Bindable<"chrome" | "popover" | "menu" | "chip" | null>): this; cornerRadius(v: Bindable<number>): this
  borderColor(v: Bindable<string | null>): this; borderWidth(v: Bindable<number>): this; opacity(v: Bindable<number>): this
  fill(v: Bindable<CmuxFill | null>): this; stroke(v: Bindable<string | null>): this; strokeWidth(v: Bindable<number>): this; size(v: Bindable<number>): this
  rotation(degrees: Bindable<number>): this
  /** SwiftUI's name for \`rotation\`: clockwise degrees about the node's center; animates only under \`.animation(...)\`. */
  rotationEffect(degrees: Bindable<number>): this
  /** Moves the drawing by \`{x, y}\` points, not the layout; a rotation turns the moved drawing about the node's center (a clock hand). */
  offset(v: Bindable<{ x?: number; y?: number }>): this
  /** In a ZStack: the node's center at \`{x, y}\` points, or with \`unit: "fraction"\` 0...1 of the stack (SwiftUI's \`.position\`); a placed child does not size the stack. */
  position(v: Bindable<{ x?: number; y?: number; unit?: "points" | "fraction" }>): this
  cursor(v: "pointer" | "default"): this; help(v: Bindable<string>): this
  fixed(): this; destructive(): this; disabled(v?: Bindable<boolean>): this; onTap(fn: () => unknown): this; contextMenu(items: CmuxView[] | (() => CmuxView[])): this
  /** How an Icon's layers take color, as SF Symbols draw them: monochrome (the default), hierarchical, palette (1 to 3 colors, in layer order) or multicolor (the symbol's own colors, the tint where it has none). */
  symbolRendering(mode: "monochrome" | "hierarchical" | "palette" | "multicolor", colors?: readonly string[]): this
}
type CmuxChildren = Array<CmuxView | (() => unknown) | null | undefined | false>
interface CmuxListSpec<T> { items: () => readonly T[] | null | undefined; key: (item: T, index: number) => string | number; onMove?: (id: string, index: number, extra: { side?: string; block?: boolean }) => unknown; onDragChange?: (state: unknown) => unknown; spacing?: number }
declare function VStack(propsOrChildren?: Record<string, unknown> | CmuxChildren, children?: CmuxChildren): CmuxView
declare function HStack(propsOrChildren?: Record<string, unknown> | CmuxChildren, children?: CmuxChildren): CmuxView
declare function ZStack(propsOrChildren?: Record<string, unknown> | CmuxChildren, children?: CmuxChildren): CmuxView
declare function LazyVStack(propsOrChildren?: Record<string, unknown> | CmuxChildren, children?: CmuxChildren): CmuxView
declare function Group(propsOrChildren?: Record<string, unknown> | CmuxChildren, children?: CmuxChildren): CmuxView
type CmuxDateTextStyle = "time" | "timer" | "relative" | "date" | "offset"
/** A Text the host formats and ticks itself, like SwiftUI's \`Text(date, style:)\` (no render or scene batch per tick).
 * \`date\` is Unix ms; \`time\` "9:41 AM", \`date\` "November 16, 2026", \`timer\` "4:05", \`relative\` "2 hr, 23 min",
 * \`offset\` "+2 hours". The page's locale and time zone; \`timeZone\` (IANA) overrides the zone. */
interface CmuxDateText { date: Bindable<number>; style?: Bindable<CmuxDateTextStyle>; timeZone?: Bindable<string> }
declare function Text(text: Bindable<string | number | null | undefined> | CmuxDateText): CmuxView
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
/** A stroke along its width: \`strokeWidth\` thick (1 by default) in \`stroke\` (the separator ink by default). */
declare function Line(props?: Record<string, unknown>): CmuxView
declare function ProgressView(value?: Bindable<number | null>): CmuxView
declare function TextField(value: Bindable<string>, options?: { placeholder?: string; autofocus?: boolean; onSubmit?: (t: string) => unknown; onEdit?: (t: string) => unknown; onCancel?: () => unknown }): CmuxView
declare function Row(props: { title: Bindable<string>; subtitle?: Bindable<string | null>; symbol?: Bindable<string | null>; badge?: Bindable<string | number | null>; unread?: Bindable<boolean>; selected?: Bindable<boolean>; tint?: Bindable<string | null>; accessory?: Bindable<string | null> }): CmuxView
/** A native switch, two-way bound: \`value\` is the state, \`onChange\` gets the new one. With a \`label\`, a settings row (label leading, switch trailing). */
declare function Toggle(value: Bindable<boolean>, options?: { label?: Bindable<string>; disabled?: Bindable<boolean>; onChange?: (on: boolean) => unknown }): CmuxView
/** A native slider over \`min...max\` (default 0...1), snapped to \`step\` (default a hundredth of the range). */
declare function Slider(value: Bindable<number>, options?: { min?: number; max?: number; step?: number; disabled?: Bindable<boolean>; onChange?: (v: number) => unknown }): CmuxView
/** The app's card surface with its padding and radius: \`glass\` (default, the sidebar cards' glass) or \`card\` (opaque), with an optional title. */
declare function Panel(propsOrChildren?: { title?: Bindable<string>; style?: "glass" | "card"; spacing?: number } | CmuxChildren, children?: CmuxChildren): CmuxView
declare function Badge(text: Bindable<string | number>, tone?: Bindable<string>): CmuxView
declare function EmptyState(props: { title: Bindable<string>; message?: Bindable<string>; symbol?: Bindable<string> }): CmuxView
declare function ForEach<T>(spec: CmuxListSpec<T>, template: (item: CmuxSignal<T>, key: string) => CmuxView): CmuxView
declare function Reorderable<T>(spec: CmuxListSpec<T>, template: (item: CmuxSignal<T>, key: string) => CmuxView): CmuxView
/** A linear gradient for .background(...) or a shape's .fill(...): 2 to 8 stops along angle degrees (0 up, 90 right, 180 down, the default). Throws on a bad stop or angle. */
declare function linearGradient(colors: readonly string[], angle?: number): CmuxGradient
/** A radial gradient: an ellipse from the center out to the box's edges, 2 to 8 stops. Throws on a bad stop. */
declare function radialGradient(colors: readonly string[]): CmuxGradient
`
  const scopesJson = JSON.stringify({ apiVersion: API_VERSION, ops: Object.fromEntries(Object.entries(scopes).sort(([a], [b]) => a.localeCompare(b))), never: never.sort() }, null, 2) + "\n"
  const opsJson = JSON.stringify({ apiVersion: API_VERSION, ops: Object.keys(scopes).sort() }, null, 2) + "\n"
  // Checked here, read where it is used: the SDKs read events.json with scopes.json (cmux-extension-sdk).
  const events = loadEvents(scopes)
  const reference = referenceMarkdown({
    apiVersion: API_VERSION,
    ops: Object.fromEntries(Object.entries(scopes).map(([n, o]) => [n, { ...o, docs: ops[n]?.docs }])),
    never,
    events,
    signals: JSON.parse(signals.json).signals
  })
  return {
    "cmux-app.d.ts": dts, "scopes.json": scopesJson, "ops.json": opsJson, "signals.json": signals.json, "REFERENCE.md": reference,
    // The merged schema directory (schema/merged), so drift in any of the four op sources fails --check.
    ...mergedFiles(ops, types, generics, actions)
  }
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
    } else { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, content) }
  }
  if (stale) process.exit(1)
  console.log(check ? "generated files up to date" : "generated files written")
}
