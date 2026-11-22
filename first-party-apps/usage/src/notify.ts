// Sends planned warnings through `notification.create`.

import type { Alert } from "./alerts.ts"
import { providerTitle } from "./format.ts"
import { t } from "./l10n.ts"

export function alertMessage(alert: Alert): { title: string; body: string; level: "warning" | "error" } {
  return {
    title: t("alert.title", "No usable {provider} account", { provider: providerTitle(alert.provider) }),
    body: t("alert.body", "All {total} accounts are used up, cooling or failing.", { total: alert.total }),
    level: "error"
  }
}

export async function notifyAlerts(alerts: readonly Alert[]): Promise<void> {
  for (const alert of alerts) {
    const m = alertMessage(alert)
    try {
      await cmux.notification.create({ title: m.title, body: m.body, level: m.level })
    } catch (e) {
      cmux.log("usage warning not sent:", String(e))
    }
  }
}
