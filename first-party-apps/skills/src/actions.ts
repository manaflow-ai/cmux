// Every change is planned first: the owner returns a diff resource with the
// exact edits to the agents' own files (dry_run). The user reviews it inline
// or in the Diffs app, then Apply accepts that diff from a tap. A file that an
// agent CLI changed in between makes the owner answer diff.stale; the app then
// plans the same intent again once and shows the new diff.

import type { Intent, Plan } from "./model/change.ts"
import { busyChange } from "./model/change.ts"
import { AGENTS, agentName } from "./model/agents.ts"
import type { Item, Scope } from "./model/items.ts"
import { parseServerLine, parseSource } from "./model/source.ts"
import { t } from "./l10n.ts"
import { call } from "./ops.ts"
import { gesture, withGesture } from "./runtime.ts"
import { change, currentRoot, dispatchChange, filter, loadItems, projectLabel, setNotice } from "./store.ts"

const target = (i: Pick<Item, "id" | "agent" | "scope" | "root" | "name">) => ({ id: i.id, agent: i.agent, scope: i.scope, ...(i.root ? { root: i.root } : {}), name: i.name })

export function scopeText(scope: Scope, root: string | null | undefined): string {
  return scope === "user" ? t("scope.user", "everywhere") : t("scope.project", "in {project}", { project: projectLabel(root) ?? t("scope.thisProject", "this project") })
}

/** Plans `intent` (dry run) and shows the review. */
export async function plan(intent: Intent): Promise<void> {
  dispatchChange({ type: "ask", intent })
  const r = await call<Plan>(intent.op, { ...intent.params, dry_run: true })
  if (r.ok) dispatchChange({ type: "planned", plan: r.value })
  else dispatchChange({ type: "error", code: r.error.code, message: r.error.message })
}

export function toggle(i: Item) {
  const op = `${i.kind === "skill" ? "skill" : "mcp_server"}.${i.enabled ? "disable" : "enable"}`
  const vars = { name: i.name, agent: agentName(i.agent), scope: scopeText(i.scope, i.root) }
  const title = i.enabled ? t("intent.disable", "Turn off {name} for {agent} {scope}", vars) : t("intent.enable", "Turn on {name} for {agent} {scope}", vars)
  return plan({ op, params: target(i), title })
}

export function remove(i: Item) {
  const op = `${i.kind === "skill" ? "skill" : "mcp_server"}.remove`
  return plan({ op, params: target(i), title: t("intent.remove", "Remove {name} from {agent} {scope}", { name: i.name, agent: agentName(i.agent), scope: scopeText(i.scope, i.root) }) })
}

const installScope = (): { scope: Scope; root?: string } => {
  const f = filter()
  const root = currentRoot()
  return f.scope === "project" && root ? { scope: "project", root } : { scope: "user" }
}

/** Install a skill from a git URL, owner/repo or store:id, for the filtered agent or every agent with skills. */
export function installSkill(text: string, only: string[] | null = null): boolean {
  const parsed = parseSource(text)
  if (!parsed.ok) {
    setNotice(parsed.reason === "scheme" ? t("install.scheme", "Only https and ssh git URLs can be installed") : t("install.shape", "Type a git URL, owner/repo or store:publisher/name"))
    return false
  }
  setNotice(null)
  const agents = only ?? (filter().agent ? [filter().agent!] : AGENTS.filter((a) => a.skills).map((a) => a.id))
  const where = installScope()
  void plan({ op: "skill.install", params: { source: parsed.source, agents, ...where }, title: t("intent.install", "Install {name} {scope}", { name: parsed.label, scope: scopeText(where.scope, where.root) }) })
  return true
}

/** Add an MCP server from "name command args…" or "name https://url". Secret values are never typed here. */
export function addServer(text: string, only: string[] | null = null): boolean {
  const parsed = parseServerLine(text)
  if (!parsed) {
    setNotice(t("add.shape", "Type a name, then a command or an https URL"))
    return false
  }
  setNotice(null)
  const agents = only ?? (filter().agent ? [filter().agent!] : AGENTS.map((a) => a.id))
  const where = installScope()
  const entry = parsed.transport === "http" ? { transport: "http", url: parsed.url, enabled: true } : { transport: "stdio", command: parsed.command, args: parsed.args, enabled: true }
  void plan({ op: "mcp_server.add", params: { agents, ...where, name: parsed.name, entry }, title: t("intent.add", "Add {name} {scope}", { name: parsed.name, scope: scopeText(where.scope, where.root) }) })
  return true
}

/** Apply: accept the planned diff from a tap (origin user). */
export async function apply(): Promise<void> {
  const s = change()
  if (s.phase !== "review") return
  const token = gesture()
  dispatchChange({ type: "apply" })
  const r = await call<{ applied: boolean }>("diff.decide", { diff: s.plan.diff, decisions: [{ decision: "accept" }] }, withGesture(token))
  if (r.ok) {
    dispatchChange({ type: "applied" })
    await loadItems()
    return
  }
  if (r.error.code === "diff.stale") {
    dispatchChange({ type: "stale" })
    const again = change()
    if (again.phase === "planning") {
      const p = await call<Plan>(again.intent.op, { ...again.intent.params, dry_run: true })
      dispatchChange(p.ok ? { type: "planned", plan: p.value } : { type: "error", code: p.error.code, message: p.error.message })
    }
    return
  }
  dispatchChange({ type: "error", code: r.error.code, message: r.error.message })
}

export function cancel() {
  if (!busyChange(change())) dispatchChange({ type: "cancel" })
}

/** Opens the planned diff in the user's diff renderer (the Diffs app by default). */
export async function openInDiffs(): Promise<void> {
  const s = change()
  if (s.phase !== "review") return
  const r = await call<unknown>("ui.open", { interface: "cmux.diff.renderer/1", props: { diff: s.plan.diff, layout: "unified" } }, withGesture(gesture()))
  if (!r.ok) setNotice(r.error.missing ? t("diffs.missing", "Opening the Diffs app needs ui.open, which this cmux does not have yet") : r.error.message)
}

export function openPane() {
  return call<unknown>("app.pane.open", { kind: "skillsHub" }, withGesture(gesture()))
}
