// Sends planned threshold warnings through `notification.create`.

import type { Alert } from "./alerts.ts"
import { paceText, percentText, resetText, windowLabel } from "./format.ts"
import { t } from "./l10n.ts"
import { paceOf } from "./pace.ts"

export function alertMessage(alert: Alert, now: number): { title: string; body: string; level: "warning" | "error" } {
  const { account, window } = alert
  const title = t("alert.title", "{provider} {window} limit at {percent}", {
    provider: account.providerTitle,
    window: windowLabel(window),
    percent: percentText(alert.percent)
  })
  const reset = resetText(window, now) ?? ""
  const pace = paceText(paceOf(window, now), now)
  const capitalized = reset.charAt(0).toUpperCase() + reset.slice(1)
  const body = !reset
    ? (pace ?? "")
    : pace
      ? t("alert.body", "{reset}. At this pace it {pace}.", { reset: capitalized, pace })
      : t("alert.bodyNoPace", "{reset}.", { reset: capitalized })
  return { title, body, level: alert.top ? "error" : "warning" }
}

export async function notifyAlerts(alerts: readonly Alert[], now: number): Promise<void> {
  for (const alert of alerts) {
    const m = alertMessage(alert, now)
    const subtitle = alert.account.label ?? alert.account.plan ?? undefined
    try {
      await cmux.notification.create({ title: m.title, subtitle, body: m.body, level: m.level })
    } catch (e) {
      cmux.log("usage warning not sent:", String(e))
    }
  }
}
