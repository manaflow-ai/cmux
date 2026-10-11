// The per-tool policy list of one connection: each tool with its method, name,
// effective action and where that action comes from (spec default, your rule,
// team rule). Team rules cannot be loosened by a user rule; the owner enforces
// that, and the row says so.

import { matchPattern as matches, type ToolEntry } from "@cmux/integrations-core"
import { t } from "../l10n.ts"
import type { Connection } from "../model/connections.ts"
import { actionCounts, addressOf, effectiveOf, mcpNameMap, setToolAction, sourceLabel, toolsOf, untrackedTools, type ToolsState } from "../model/tools.ts"
import { methodBadge, policyControl, problemState } from "./common.ts"

const whyLine = (s: ToolsState, tool: ToolEntry): string => {
  const eff = effectiveOf(s, tool)
  if (eff.source === "team") return t("policy.why.team", "Set by your team")
  if (eff.source === "user") return t("policy.why.user", "Your rule")
  // A broad rule matched but cannot unblock a destructive tool (only an exact rule can).
  if (tool.default_action === "block" && s.rules.some((r) => r.action !== "block" && r.pattern !== addressOf(s, tool) && matches(r.pattern, addressOf(s, tool)))) return t("policy.why.destructiveExact", "Default: destructive; only a rule for this tool unblocks it")
  return tool.op_class === "read" ? t("policy.why.read", "Default: reads") : tool.op_class === "destructive" || tool.op_class === "money" ? t("policy.why.destructive", "Default: destructive") : t("policy.why.write", "Default: changes data")
}

function toolRow(c: () => Connection, tool: () => ToolEntry) {
  const state = () => toolsOf(c().id)
  const action = () => {
    const s = state()
    return s ? effectiveOf(s, tool()).action : tool().default_action
  }
  const isRule = () => {
    const s = state()
    return !!s && effectiveOf(s, tool()).source === "user"
  }
  const mcpName = () => {
    const s = state()
    const name = s ? mcpNameMap().get(`${c().id}|${addressOf(s, tool())}`) : undefined
    // Full width under the row: MCP names run up to 64 characters.
    return name ? Text(name).font("caption2").monospaced().color("tertiary").lineLimit(1).truncation("middle").help(t("policy.mcpName", "Name on the MCP endpoint")) : null
  }
  return VStack({ spacing: 1 }, [
    HStack({ spacing: 8 }, [
      () => methodBadge(tool().method),
      VStack({ spacing: 1 }, [
        Text(() => tool().title)
          .lineLimit(1)
          .opacity(() => (tool().deprecated ? 0.6 : 1)),
        Text(() => {
          const s = state()
          return s ? whyLine(s, tool()) : ""
        })
          .font("caption2")
          .color("tertiary")
          .lineLimit(2)
          .fixedSize("vertical")
      ])
        .frame({ maxWidth: "infinity" })
        .layoutPriority(1),
      policyControl(action, isRule, (a) => setToolAction(c(), tool(), a))
    ]),
    mcpName
  ])
    .padding({ top: 4, leading: 12, bottom: 4, trailing: 12 })
    .help(() => tool().target)
}

/** Summary such as "8 tools · 4 allowed · 3 ask · 1 blocked". */
export const countsLine = (s: ToolsState): string => {
  const n = actionCounts(s)
  if (s.tools.length === 1) return t("tools.counts.one", "1 tool · {allow} allowed · {ask} ask · {block} blocked", { allow: n.allow, ask: n.ask, block: n.block })
  return t("tools.counts", "{total} tools · {allow} allowed · {ask} ask · {block} blocked", { total: s.tools.length, allow: n.allow, ask: n.ask, block: n.block })
}

/** Tools of one connection, optionally filtered by a query over title, path and target. Toggles update rows in place. */
export function toolList(c: () => Connection, query: () => string = () => "", limit = 60) {
  // Rebuild only when the load phase or source changes, not on every rule edit.
  const shape = computed(() => {
    const s = toolsOf(c().id)
    return s ? `${s.phase}|${s.source}|${s.problem?.code ?? ""}` : "none"
  })
  const items = () => {
    const q = query().trim().toLowerCase()
    const now = toolsOf(c().id)?.tools ?? []
    return (q ? now.filter((tool) => `${tool.title} ${tool.path} ${tool.target}`.toLowerCase().includes(q)) : now).slice(0, limit)
  }
  return () => {
    shape()
    const id = untrack(() => c().id)
    const s = untrackedTools(id)
    if (!s || s.phase === "loading") return Text(t("tools.loading", "Loading tools")).font("caption").color("secondary").padding({ top: 6, leading: 12, bottom: 6, trailing: 12 })
    if (s.phase === "error" && s.problem) return problemState(s.problem)
    const note = sourceLabel(s)
    return VStack({ spacing: 0 }, [
      HStack({ spacing: 6 }, [
        Text(() => {
          const now = toolsOf(c().id)
          return now ? countsLine(now) : ""
        })
          .font("caption")
          .color("secondary")
          .lineLimit(2)
          .fixedSize("vertical")
          .layoutPriority(1),
        note ? Spacer() : null,
        note ? Text(note).font("caption2").color("tertiary").lineLimit(1) : null
      ]).padding({ top: 2, leading: 12, bottom: 4, trailing: 12 }),
      ForEach({ items, key: (tool) => tool.path }, (tool) => toolRow(c, tool)),
      () => {
        const n = (toolsOf(c().id)?.tools.length ?? 0) - limit
        return n > 0 && !query().trim() ? Text(t("tools.more", "{n} more tools: filter to find them", { n })).font("caption").color("tertiary").padding({ top: 4, leading: 12, bottom: 4, trailing: 12 }) : null
      }
    ])
  }
}
