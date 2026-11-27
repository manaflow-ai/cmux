// Sidebar section "Integrations": connections that need action first, then a
// one-line summary. Rows open the pane (proposed `app.pane.open`).

import { t } from "../l10n.ts"
import { counts, displayName, needsAttention, statusLabel, statusTone, type Connection } from "../model/connections.ts"
import { providerInfo } from "../model/providers.ts"
import { connections, loading, loadProblem, problemText } from "../model/store.ts"
import { providerOf } from "../model/connections.ts"

const MAX_ROWS = 5

export function sectionView(openPane: (detail?: string) => unknown) {
  const attention = () => connections().filter(needsAttention).slice(0, MAX_ROWS)
  const shape = computed(() => (loading() ? "loading" : loadProblem() ? "problem" : connections().length === 0 ? "empty" : "list"))
  return VStack({ spacing: 0 }, [
    () => {
      switch (shape()) {
        case "loading":
          return null
        case "problem":
          return Row({ title: () => problemText(loadProblem()!), symbol: "puzzlepiece.extension", tint: "secondary" })
        case "empty":
          return Row({ title: t("section.empty", "Connect an app"), subtitle: t("section.empty.sub", "GitHub, Linear, Slack or any API"), symbol: "plus.circle", tint: "secondary" }).onTap(() => openPane())
        default:
          return VStack({ spacing: 0 }, [
            ForEach({ items: attention, key: (c: Connection) => c.id }, (c) =>
              Row({ title: () => displayName(c()), subtitle: () => statusLabel(c().status), symbol: () => providerInfo(providerOf(c())).symbol, tint: () => statusTone(c().status) }).onTap(() => openPane(c().id))
            ),
            Row({
              title: () => {
                const n = counts(connections())
                return t("section.summary", "{n} connected", { n: n.total - n.attention - n.pending })
              },
              subtitle: () => {
                const n = counts(connections())
                return n.pending > 0 ? t("section.pending", "{n} waiting for approval", { n: n.pending }) : null
              },
              symbol: "puzzlepiece.extension",
              tint: "secondary"
            }).onTap(() => openPane())
          ])
      }
    }
  ])
}
