// Small pieces the variants share.

import { addServer, installSkill, remove, toggle } from "../actions.ts"
import { agentName, AGENTS } from "../model/agents.ts"
import { type Filter, type Item, requestTone, type Sandbox } from "../model/items.ts"
import { t } from "../l10n.ts"
import type { OpError } from "../ops.ts"
import { currentRoot, errors, filter, notice, projectLabel, setFilter } from "../store.ts"

export const kindSymbol = (i: Pick<Item, "kind">) => (i.kind === "skill" ? "book.closed" : "point.3.connected.trianglepath.dotted")

export function sandboxText(s: Sandbox | string): string {
  switch (s) {
    case "standard":
      return t("sandbox.standard", "Standard sandbox")
    case "contained":
      return t("sandbox.contained", "Contained sandbox")
    case "complete":
      return t("sandbox.complete", "Complete sandbox")
    default:
      return t("sandbox.none", "Not sandboxed")
  }
}

export const sandboxLine = (s: Sandbox | string) =>
  HStack({ spacing: 6 }, [Icon(s === "none" ? "shield.slash" : "shield.lefthalf.filled").font("caption").color(s === "none" ? "warning" : "secondary"), Text(sandboxText(s)).font("caption").secondary()])

export function sourceText(i: Item): string {
  switch (i.source.kind) {
    case "git":
      return t("source.git", "From {label}", { label: i.source.label + (i.source.ref ? `@${i.source.ref}` : "") })
    case "store":
      return t("source.store", "From the store: {label}", { label: i.source.label })
    case "agent":
      return t("source.agent", "Added by {label}", { label: i.source.label })
    default:
      return t("source.local", "Local folder")
  }
}

export const requestChips = (requests: readonly string[]) =>
  HStack(
    { spacing: 4 },
    requests.slice(0, 4).map((r) => Badge(r, requestTone(r) === "secondary" ? "secondary" : requestTone(r)))
  )

export function subtitleOf(i: Item): string {
  if (i.kind === "skill") return i.description
  return i.transport === "http" ? (i.url ?? "") : (i.command_label ?? "")
}

export function onOffButton(i: () => Item) {
  return Button(() => (i().enabled ? t("action.turnOff", "Turn Off") : t("action.turnOn", "Turn On")), () => void toggle(i())).font("caption")
}

export const itemMenu = (i: () => Item) => () => [
  Button(i().enabled ? t("action.turnOff", "Turn Off") : t("action.turnOn", "Turn On"), () => void toggle(i())),
  Divider(),
  Button(t("action.remove", "Remove…"), () => void remove(i())).destructive()
]

function chip(label: string, active: () => boolean, onTap: () => void) {
  return Text(label)
    .font("caption")
    .padding({ top: 3, leading: 8, bottom: 3, trailing: 8 })
    .background(() => (active() ? "selected" : null))
    .hoverBackground("hover")
    .cornerRadius(10)
    .onTap(onTap)
}

const patch = (p: Partial<Filter>) => setFilter((f) => ({ ...f, ...p }))

export function kindChips() {
  const kinds: Array<[Filter["kind"], string]> = [
    ["all", t("filter.all", "All")],
    ["skill", t("filter.skills", "Skills")],
    ["mcp", t("filter.mcp", "MCP Servers")],
    ["off", t("filter.off", "Off")]
  ]
  return HStack({ spacing: 4 }, kinds.map(([k, label]) => chip(label, () => filter().kind === k, () => patch({ kind: k }))))
}

export function scopeChips() {
  return HStack({ spacing: 4 }, [
    chip(t("filter.anyScope", "Everywhere and project"), () => filter().scope === "all", () => patch({ scope: "all" })),
    chip(t("filter.user", "Everywhere"), () => filter().scope === "user", () => patch({ scope: "user" })),
    () => (currentRoot() ? chip(projectLabel(currentRoot()) ?? t("scope.thisProject", "this project"), () => filter().scope === "project", () => patch({ scope: "project" })) : null)
  ])
}

/** Agent chips bound to a caller-owned selection (the byAgent design keeps its own). */
export function agentChips(current: () => string, select: (id: string) => void) {
  return HStack({ spacing: 4 }, AGENTS.map((a) => chip(a.name, () => current() === a.id, () => select(a.id))))
}

/** Install a skill and add a server, one line each; secrets are never typed here. */
export function addFields(only: () => string[] | null = () => null) {
  return VStack({ spacing: 4 }, [
    TextField("", { placeholder: t("install.placeholder", "Install skill: git URL, owner/repo or store:id"), onSubmit: (text) => void installSkill(text, only()) }),
    TextField("", { placeholder: t("add.placeholder", "Add MCP server: name command… or name https://…"), onSubmit: (text) => void addServer(text, only()) }),
    () => (notice() ? Text(notice()!).font("caption").color("warning").lineLimit(2) : null)
  ])
}

/** One line per list that failed; a missing op names itself. */
export function loadErrors() {
  return () => {
    const e = errors()
    const lines = [e.skills, e.mcp].filter((x): x is OpError => !!x)
    if (!lines.length) return null
    return VStack(
      { spacing: 2 },
      lines.map((err) =>
        Text(err.missing ? t("error.missingOp", "{op} is not available in this cmux yet.", { op: err.op }) : t("error.load", "Cannot load {op}: {message}", { op: err.op, message: err.message }))
          .font("caption")
          .color(err.missing ? "secondary" : "danger")
          .lineLimit(2)
      )
    ).padding({ top: 4, leading: 12, bottom: 4, trailing: 12 })
  }
}

export const agentsLine = (items: readonly Item[]) => items.map((i) => agentName(i.agent)).join(", ")
