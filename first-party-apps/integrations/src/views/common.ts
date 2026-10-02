// Pieces every screen shares: the header, the notice line, status badges,
// connection rows, the policy control, error states and the credit line.

import type { ToolAction } from "../core/types.ts"
import { t } from "../l10n.ts"
import { displayName, needsAttention, statusLabel, statusTone, subtitle, type Connection } from "../model/connections.ts"
import { providerInfo } from "../model/providers.ts"
import { isMissing, notice, open, problemText, setNotice, type Problem } from "../model/store.ts"
import { actionLabel, actionTone } from "../model/tools.ts"
import { providerOf } from "../model/connections.ts"

/** Screen title with optional trailing buttons. */
export function header(title: string | (() => string), trailing: CmuxView[] = [], back = false) {
  return HStack({ spacing: 8 }, [
    back ? Icon("chevron.left").color("secondary").onTap(() => open({ screen: "home" })).help(t("nav.back", "Back")) : null,
    Text(title).font("headline").lineLimit(1),
    Spacer(),
    ...trailing
  ]).padding({ top: 10, leading: 12, bottom: 6, trailing: 12 })
}

export const smallButton = (label: string | (() => string), fn: () => unknown) => Button(label, fn).font("caption")

/** One dismissible line under the header for results and missing ops. */
export function noticeLine() {
  return () => {
    const n = notice()
    if (!n) return null
    return HStack({ spacing: 6 }, [
      Text(n.text).font("caption").color(n.tone).lineLimit(3).fixedSize("vertical").layoutPriority(1),
      Spacer(),
      Icon("xmark").font("caption2").color("tertiary").onTap(() => setNotice(null)).help(t("notice.dismiss", "Dismiss"))
    ]).padding({ top: 2, leading: 12, bottom: 6, trailing: 12 })
  }
}

/** Short status for badges (the detail line spells it out). */
const badgeText = (c: Connection) => (c.status === "pending" ? t("status.pendingShort", "Pending") : statusLabel(c.status))

export const statusBadge = (c: Connection) => Badge(badgeText(c), statusTone(c.status)).fixedSize()

/** A connection in a list: provider symbol, name, provider and sharing, status when it needs action. */
export function connectionRow(c: () => Connection, onTap: () => unknown) {
  return HStack({ spacing: 8 }, [
    Icon(() => providerInfo(providerOf(c())).symbol)
      .color(() => (needsAttention(c()) ? statusTone(c().status) : "secondary"))
      .frame({ width: 18 }),
    VStack({ spacing: 1 }, [Text(() => displayName(c())).lineLimit(1), Text(() => subtitle(c())).font("caption").color("secondary").lineLimit(1)]),
    Spacer(),
    () => (c().status === "active" ? null : statusBadge(c()))
  ])
    .padding({ top: 5, leading: 12, bottom: 5, trailing: 12 })
    .hoverBackground("hover")
    .cursor("pointer")
    .onTap(onTap)
}

/** Allow / Ask / Block: the selected action is tinted; tapping it again resets to the default. */
export function policyControl(current: () => ToolAction, isRule: () => boolean, set: (a: ToolAction | null) => unknown) {
  const segment = (a: ToolAction) =>
    Text(actionLabel(a))
      .font("caption")
      .weight(() => (current() === a ? "semibold" : "regular"))
      .color(() => (current() === a ? actionTone(a) : "tertiary"))
      .padding({ top: 2, leading: 6, bottom: 2, trailing: 6 })
      .background(() => (current() === a ? "selected" : null))
      .cornerRadius(4)
      .cursor("pointer")
      .onTap(() => set(current() === a && isRule() ? null : a))
  return HStack({ spacing: 2 }, [segment("allow"), segment("ask"), segment("block")])
    .padding(1)
    .borderColor("separator")
    .borderWidth(1)
    .cornerRadius(5)
    .fixedSize()
}

/** Empty or error panel. A missing proposed op names the op. */
export function problemState(p: Problem) {
  return EmptyState({ title: problemText(p), message: isMissing(p) ? t("error.missing.hint", "This screen needs a backend operation that is proposed, not built.") : "", symbol: isMissing(p) ? "puzzlepiece.extension" : "exclamationmark.triangle" })
}

export const sectionTitle = (text: string) => Text(text).font("caption").weight("semibold").color("secondary").padding({ top: 10, leading: 12, bottom: 4, trailing: 12 })

/** Credit for the reused generic-import code (MIT; README and LICENSE-executor). */
export const aboutLine = () =>
  Text(t("about.executor", "Generic API import adapted from executor (MIT License, © 2026 Rhys Sullivan)."))
    .font("caption2")
    .color("tertiary")
    .lineLimit(2)
    .padding({ top: 8, leading: 12, bottom: 10, trailing: 12 })

export const methodBadge = (method: string | undefined) => (method ? Text(method.toUpperCase()).font("caption2").monospaced().color("secondary").frame({ width: 52 }) : null)

export const providerName = (id: string) => providerInfo(id).name
