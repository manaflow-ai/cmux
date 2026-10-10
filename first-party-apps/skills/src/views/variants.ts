// The pane's three designs (DEV/NIGHTLY setting `variant`):
//   unified  one list of skills and MCP servers (same name across agents is one
//            row), kind and scope chips, the selected item's details below,
//            the planned change inline with context lines
//   byAgent  agent chips, then Skills and MCP Servers for that agent with
//            Turn On/Off per row; the change shows as a file summary and opens
//            in the Diffs app
//   byScope  Everywhere and This project sections, agents as text per row;
//            the change shows only its changed lines

import { agentName, AGENTS } from "../model/agents.ts"
import { type Group, groupByName, type Item, matches, needsAttention, worstTone } from "../model/items.ts"
import { t } from "../l10n.ts"
import { reviewIn } from "../settings.ts"
import { currentRoot, errors, filter, items, loaded, projectLabel, selected, setSelected } from "../store.ts"
import { reviewCard } from "./review.ts"
import { addFields, agentChips, agentsLine, itemMenu, kindChips, kindSymbol, loadErrors, onOffButton, requestChips, sandboxLine, sandboxText, scopeChips, sourceText, subtitleOf } from "./parts.ts"
import { remove, scopeText, toggle } from "../actions.ts"

const filtered = () => items().filter((i) => matches(i, filter()))

function header(extra: CmuxChildren) {
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 8 }, [Text(t("title", "Skills and MCP Servers")).font("headline"), Spacer()]),
    ...extra
  ]).padding({ top: 8, leading: 12, bottom: 6, trailing: 12 })
}

/** Loading, everything failed, or nothing at all. */
function gate() {
  if (!loaded()) return Text(t("loading", "Reading agent configuration…")).font("callout").secondary().padding(16)
  const e = errors()
  if (e.skills && e.mcp && !items().length) {
    const err = e.skills
    return EmptyState({
      title: err.missing ? t("error.missingTitle", "Skill and MCP management is not available yet") : t("error.title", "Cannot read agent configuration"),
      message: err.missing ? t("error.missingBoth", "This cmux does not provide skill.list and mcp_server.list.") : err.message,
      symbol: err.missing ? "puzzlepiece.extension" : "exclamationmark.triangle"
    })
  }
  if (!items().length) return EmptyState({ title: t("empty.title", "No skills or MCP servers yet"), message: t("empty.message", "Install a skill from a git URL or add an MCP server above."), symbol: "shippingbox" })
  return null
}

const reviewMode = (fallback: "full" | "compact" | "summary") => (reviewIn() === "diffs" ? "summary" : fallback)

// MARK: unified

function groupRow(g: () => Group) {
  const first = () => g().items[0]!
  const anyOn = () => g().items.some((i) => i.enabled)
  return Row({
    title: () => g().name,
    subtitle: () => `${agentsLine(g().items)} · ${scopeText(g().scope, g().root)}`,
    symbol: () => kindSymbol(first()),
    tint: () => (g().items.some(needsAttention) ? "warning" : anyOn() ? null : "tertiary"),
    badge: () => (anyOn() ? null : t("badge.off", "Off")),
    selected: () => selected() === g().key
  }).onTap(() => setSelected(g().key))
}

function agentLine(i: Item) {
  return HStack({ spacing: 8 }, [
    Icon(i.enabled ? "checkmark.circle.fill" : "circle").font("caption").color(i.enabled ? "success" : "tertiary"),
    Text(agentName(i.agent)).font("callout").frame({ width: 110 }),
    Text(i.path_label).font("caption").monospaced().secondary().lineLimit(1).truncation("head"),
    Spacer(),
    onOffButton(() => i)
  ]).contextMenu(itemMenu(() => i))
}

function detail() {
  return () => {
    const groups = groupByName(filtered())
    const g = groups.find((x) => x.key === selected()) ?? groups[0]
    if (!g) return null
    const first = g.items[0]!
    const requests = [...new Set(g.items.flatMap((i) => i.requests))]
    return VStack({ spacing: 6 }, [
      HStack({ spacing: 6 }, [Icon(kindSymbol(first)).secondary(), Text(g.name).font("headline"), Text(first.kind === "skill" ? t("kind.skill", "Skill") : t("kind.mcp", "MCP server")).font("caption").secondary()]),
      Text(subtitleOf(first)).font("callout").secondary().lineLimit(3),
      Text(sourceText(first)).font("caption").secondary(),
      requests.length ? requestChips(requests) : null,
      sandboxLine(first.sandbox),
      first.kind === "mcp" && first.env_keys.length ? Text(t("detail.env", "Secrets it reads: {keys}", { keys: first.env_keys.join(", ") })).font("caption").secondary().lineLimit(2) : null,
      Divider(),
      VStack({ spacing: 4 }, g.items.map(agentLine))
    ]).padding(12)
  }
}

export function unifiedView() {
  return VStack({ spacing: 0 }, [
    header([kindChips(), scopeChips(), addFields()]),
    reviewCard(reviewMode("full")),
    loadErrors(),
    Divider(),
    () =>
      gate() ??
      VStack({ spacing: 0 }, [
        ForEach({ items: () => groupByName(filtered()), key: (g) => g.key }, (g) => groupRow(g)),
        () => (groupByName(filtered()).length ? null : Text(t("filter.none", "Nothing matches these filters")).font("callout").secondary().padding(12)),
        Divider(),
        detail()
      ])
  ])
}

// MARK: byAgent

function agentItemRow(i: () => Item) {
  return HStack({ spacing: 10 }, [
    Icon(() => kindSymbol(i())).color(() => (i().enabled ? (needsAttention(i()) ? "warning" : "secondary") : "tertiary")),
    VStack({ spacing: 2 }, [
      HStack({ spacing: 6 }, [Text(() => i().name).font("body").weight("medium").color(() => (i().enabled ? null : "secondary")), Text(() => scopeText(i().scope, i().root)).font("caption").secondary()]),
      Text(() => subtitleOf(i())).font("caption").secondary().lineLimit(1).truncation("tail"),
      HStack({ spacing: 6 }, [Text(() => sourceText(i())).font("caption").color("tertiary"), Text("·").font("caption").color("tertiary"), Text(() => sandboxLabel(i())).font("caption").color(() => (i().sandbox === "none" ? "warning" : "tertiary"))])
    ]).frame({ maxWidth: "infinity" }),
    onOffButton(i)
  ])
    .padding({ top: 6, leading: 12, bottom: 6, trailing: 12 })
    .contextMenu(itemMenu(i))
}

const sandboxLabel = (i: Item) => sandboxText(i.sandbox)

function section(title: string, list: () => Item[]) {
  return () => {
    if (!list().length) return null
    return VStack({ spacing: 0 }, [
      Text(title).font("caption").weight("semibold").secondary().padding({ top: 8, leading: 12, bottom: 2, trailing: 12 }),
      ForEach({ items: list, key: (i) => i.id }, (i) => agentItemRow(i))
    ])
  }
}

const [shownAgent, setShownAgent] = signal<string>(AGENTS[0]!.id)

export function byAgentView() {
  const agentItems = () => items().filter((i) => matches(i, { ...filter(), agent: shownAgent(), kind: "all" }))
  return VStack({ spacing: 0 }, [
    header([agentChips(shownAgent, setShownAgent), addFields(() => [shownAgent()])]),
    reviewCard(reviewMode("summary")),
    loadErrors(),
    Divider(),
    () =>
      gate() ??
      VStack({ spacing: 0 }, [
        section(t("section.skills", "Skills"), () => agentItems().filter((i) => i.kind === "skill")),
        section(t("section.mcp", "MCP Servers"), () => agentItems().filter((i) => i.kind === "mcp")),
        () => (agentItems().length ? null : Text(t("agent.none", "{agent} has no skills or MCP servers here", { agent: agentName(shownAgent()) })).font("callout").secondary().padding(12))
      ])
  ])
}

// MARK: byScope

function scopeRow(g: () => Group) {
  const tone = () => worstTone(g().items.flatMap((i) => i.requests))
  return HStack({ spacing: 10 }, [
    Icon(() => kindSymbol(g())).secondary(),
    VStack({ spacing: 2 }, [
      Text(() => g().name).font("body").weight("medium"),
      Text(() => g().items.map((i) => `${agentName(i.agent)}${i.enabled ? "" : ` (${t("badge.off", "Off")})`}`).join(", ")).font("caption").secondary().lineLimit(1)
    ]).frame({ maxWidth: "infinity" }),
    () => (tone() === "secondary" ? null : Badge(tone() === "danger" ? t("badge.runs", "Runs commands") : t("badge.network", "Network or writes"), tone()))
  ])
    .padding({ top: 6, leading: 12, bottom: 6, trailing: 12 })
    .contextMenu(() => [
      ...g().items.map((i) => Button(i.enabled ? t("menu.offFor", "Turn Off for {agent}", { agent: agentName(i.agent) }) : t("menu.onFor", "Turn On for {agent}", { agent: agentName(i.agent) }), () => void toggle(i))),
      Divider(),
      ...g().items.map((i) => Button(t("menu.removeFrom", "Remove from {agent}…", { agent: agentName(i.agent) }), () => void remove(i)).destructive())
    ])
}

function scopeSection(title: () => string, scope: "user" | "project") {
  const groups = () => groupByName(filtered().filter((i) => i.scope === scope))
  return () => {
    if (!groups().length) return null
    return VStack({ spacing: 0 }, [
      HStack({ spacing: 6 }, [Icon(scope === "user" ? "person.crop.circle" : "folder").font("caption").secondary(), Text(title).font("callout").weight("semibold"), Spacer(), Text(String(groups().length)).font("caption").secondary()]).padding({
        top: 10,
        leading: 12,
        bottom: 4,
        trailing: 12
      }),
      ForEach({ items: groups, key: (g) => g.key }, (g) => scopeRow(g))
    ])
  }
}

export function byScopeView() {
  return VStack({ spacing: 0 }, [
    header([kindChips(), addFields()]),
    reviewCard(reviewMode("compact")),
    loadErrors(),
    Divider(),
    () =>
      gate() ??
      VStack({ spacing: 0 }, [
        scopeSection(() => t("scope.userTitle", "Everywhere"), "user"),
        Divider(),
        scopeSection(() => t("scope.projectTitle", "This project: {project}", { project: projectLabel(currentRoot()) ?? "" }), "project")
      ])
  ])
}
