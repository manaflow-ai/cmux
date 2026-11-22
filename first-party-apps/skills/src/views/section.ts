// Sidebar section "Skills": counts for this project and everywhere, items that
// need attention (unsandboxed and running commands), and a pending change.

import { openPane } from "../actions.ts"
import { needsAttention } from "../model/items.ts"
import { t } from "../l10n.ts"
import { change, errors, items, loaded } from "../store.ts"
import { kindSymbol } from "./parts.ts"

export function skillsSection() {
  return VStack({ spacing: 0 }, [
    () => {
      if (!loaded()) return Text(t("loading", "Reading agent configuration…")).font("caption").secondary().padding(8)
      const e = errors()
      if (e.skills && e.mcp && !items().length) {
        return EmptyState({ title: e.skills.missing ? t("error.missingTitle", "Skill and MCP management is not available yet") : t("error.title", "Cannot read agent configuration"), symbol: "puzzlepiece.extension" }).onTap(() => void openPane())
      }
      const all = items()
      const skills = all.filter((i) => i.kind === "skill").length
      const servers = all.length - skills
      const flagged = all.filter(needsAttention)
      const pending = change().phase === "review"
      return VStack({ spacing: 0 }, [
        Row({ title: t("section.skills", "Skills"), subtitle: null, symbol: "book.closed", badge: skills || null }).onTap(() => void openPane()),
        Row({ title: t("section.mcp", "MCP Servers"), subtitle: null, symbol: "point.3.connected.trianglepath.dotted", badge: servers || null }).onTap(() => void openPane()),
        ...flagged.slice(0, 3).map((i) => Row({ title: i.name, subtitle: t("section.unsandboxed", "Runs commands without a sandbox"), symbol: kindSymbol(i), tint: "warning" }).onTap(() => void openPane())),
        pending ? Row({ title: t("section.pending", "1 change to review"), subtitle: null, symbol: "doc.badge.ellipsis", tint: "warning" }).onTap(() => void openPane()) : null
      ])
    }
  ])
}
