// The sidebar section (summary, plus the setup checklist in that variant)
// and the status item (health dot and today's usage).

import * as act from "../actions.ts"
import type { Core } from "../data.ts"
import { t } from "../l10n.ts"
import { healthTone, healthWord, isHealthyAccount, usageSummary } from "../model.ts"
import { remaining } from "../onboarding.ts"
import { OP } from "../ops.ts"
import { onboard, progress, variant } from "../store.ts"
import { dot, loaded, noticeLine } from "./common.ts"
import { checklist, setupPending } from "./onboarding.ts"

function summary(d: Core) {
  return loaded(d.status, OP.status, (s) => {
    if (!s.signed_in) {
      const found = (d.detected() ?? []).filter((x) => x.status === "signed_in").length
      return VStack({ spacing: 0 }, [
        Row({ title: t("scope.local", "This Mac"), subtitle: t("local.foundCount", "{n} sign-ins found", { n: found }), symbol: "arrow.triangle.branch", tint: "secondary" }).onTap(() => act.openPane("dashboard")),
        Row({ title: t("problem.signedOut", "Sign in to cmux"), subtitle: t("local.signInSub", "to share accounts with your team"), symbol: "person.crop.circle", tint: "secondary" }).onTap(act.signIn)
      ])
    }
    const accounts = d.accounts() ?? []
    const healthy = accounts.filter(isHealthyAccount).length
    const shared = accounts.filter((a) => a.visibility === "team").length
    const keys = (d.keys() ?? []).filter((k) => !k.revoked).length
    return VStack({ spacing: 0 }, [
      Row({
        title: s.scope?.kind === "team" ? s.scope.team_name : t("scope.personal", "Personal"),
        subtitle: `${healthWord(s.health)} · ${usageSummary(s.usage_today)}`,
        symbol: "arrow.triangle.branch",
        tint: healthTone(s.health)
      })
        .onTap(() => act.openPane("dashboard"))
        .contextMenu([Button(t("action.runTest", "Run Test"), () => act.runTest()), Button(t("action.setUp", "Set Up CodeRouter"), () => onboard({ type: "restart" }, d.facts()))]),
      Row({
        title: accounts.length ? t("section.accountsCount", "{healthy} of {total} accounts ready", { healthy, total: accounts.length }) : t("section.noAccounts", "No accounts connected"),
        subtitle: s.scope?.kind === "team" && accounts.length ? t("section.sharedCount", "{n} shared with the team", { n: shared }) : null,
        symbol: healthy < accounts.length ? "exclamationmark.circle" : "person.crop.circle.badge.checkmark",
        tint: healthy < accounts.length ? "warning" : "secondary"
      }).onTap(() => act.openPane("dashboard")),
      keys ? Row({ title: t("section.keysCount", "{n} API keys", { n: keys }), symbol: "key", tint: "secondary" }).onTap(() => act.openPane("dashboard")) : null
    ])
  })
}

export function section(d: Core) {
  const pending = computed(() => setupPending(d))
  return VStack({ spacing: 4 }, [
    () => {
      if (!pending()) return null
      if (variant() === "checklist") return checklist(d)
      return Row({ title: t("section.finishSetup", "Finish setting up"), subtitle: () => t("checklist.left", "{n} left", { n: remaining(progress(), d.facts()) }), symbol: "sparkles", tint: "accent", accessory: "chevron" }).onTap(() =>
        act.openPane("onboarding")
      )
    },
    summary(d),
    () => (pending() && variant() === "checklist" ? null : noticeLine())
  ])
}

export function statusItem(d: Core) {
  const tone = () => (d.status.problem() ? "tertiary" : healthTone(d.status()?.health))
  const text = () => {
    const s = d.status()
    if (d.status.problem() || !s) return ""
    // Signed out is a normal local state, not an error: show nothing extra.
    if (!s.signed_in) return ""
    if (s.health === "down") return t("health.down", "Down")
    return cmux.app.settings().statusShowsUsage === false ? "" : usageSummary(s.usage_today)
  }
  return HStack({ spacing: 5 }, [dot(tone), Text(text).font("caption").monospaced()])
    .paddingHorizontal(6)
    .cornerRadius(6)
    .hoverBackground("hover")
    .help(() => `CodeRouter: ${healthWord(d.status()?.health)}`)
    .onTap(() => act.openPane("dashboard"))
    .contextMenu([
      Button(t("action.open", "Open CodeRouter"), () => act.openPane("dashboard")),
      Button(t("action.runTest", "Run Test"), () => act.runTest()),
      Button(t("action.setUp", "Set Up CodeRouter"), () => (onboard({ type: "restart" }, d.facts()), act.openPane("onboarding")))
    ])
}
