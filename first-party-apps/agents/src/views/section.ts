// Sidebar section "Agents": the CLIs on this machine, one native row each.
// Tap opens the hub pane; the context menu has Update and Sign In.

import { openPane, signIn, update } from "../actions.ts"
import { type CliEntry, needsSignIn, statusOf, summarize } from "../model/entries.ts"
import { t } from "../l10n.ts"
import { loaded, localMachine, setSelected, stateOf } from "../store.ts"
import { errorState, nameOf, statusSymbol, statusTone, versionLine } from "./common.ts"

export function summaryText(lists: readonly (readonly CliEntry[])[]): string {
  const s = summarize(lists)
  if (!s.installed) return t("summary.none", "No agent CLIs found")
  const parts: string[] = []
  if (s.updates) parts.push(s.updates === 1 ? t("summary.update1", "1 update") : t("summary.updates", "{n} updates", { n: s.updates }))
  if (s.missingSignIns) parts.push(t("summary.signIn", "{n} need sign-in", { n: s.missingSignIns }))
  return parts.length ? parts.join(" · ") : t("summary.current", "All up to date")
}

function row(machine: string, e: () => CliEntry) {
  return Row({
    title: () => nameOf(e()),
    subtitle: () => versionLine(e()),
    symbol: () => statusSymbol(statusOf(e())),
    tint: () => statusTone(statusOf(e())),
    badge: () => (statusOf(e()) === "update" ? t("badge.update", "Update") : needsSignIn(e()) ? t("badge.signIn", "Sign In") : null)
  })
    .onTap(() => {
      setSelected({ machine, cli: e().cli })
      void openPane()
    })
    .contextMenu(() => [
      Button(t("action.update", "Update"), () => void update(machine, e().cli)).disabled(statusOf(e()) !== "update" || !e().updatable),
      Button(t("action.signIn", "Sign In…"), () => void signIn(machine, e().cli)).disabled(!e().installed),
      Button(t("action.open", "Open Agent CLIs"), () => void openPane())
    ])
}

export function agentsSection() {
  return VStack({ spacing: 2 }, [
    () => {
      const m = localMachine()
      const st = stateOf(m.id)
      if (!loaded() && st.loading) return Text(t("loading", "Looking for agent CLIs…")).font("caption").secondary().padding(8)
      if (st.error && !st.entries.length) return errorState(st.error)
      const installed = st.entries.filter((e) => e.installed)
      const missing = st.entries.length - installed.length
      if (!installed.length) {
        return EmptyState({ title: t("empty.title", "No agent CLIs on this machine"), message: t("empty.message", "Open Agent CLIs to install one."), symbol: "terminal" }).onTap(() => void openPane())
      }
      return VStack({ spacing: 0 }, [
        ForEach({ items: () => stateOf(m.id).entries.filter((e) => e.installed), key: (e) => e.cli }, (e) => row(m.id, e)),
        missing
          ? Text(t("section.more", "{n} more you can install", { n: missing }))
              .font("caption")
              .secondary()
              .padding({ top: 4, leading: 10, bottom: 4, trailing: 10 })
              .onTap(() => void openPane())
          : null
      ])
    }
  ])
}
