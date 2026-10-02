// The provider gallery: first-class apps with a Connect button, and the
// generic kinds (OpenAPI, GraphQL, MCP) that open the importer. Each card says
// why it cannot connect when the team policy or the server prevents it.

import { t } from "../l10n.ts"
import { connect } from "../model/actions.ts"
import { providerAllowed, providerConfigured } from "../model/connections.ts"
import { FIRST_CLASS, GENERIC, providerBlurb, providerInfo } from "../model/providers.ts"
import { list, open, teamPolicy } from "../model/store.ts"
import { sectionTitle, smallButton } from "./common.ts"

const connectedCount = (provider: string) => (list()?.connections ?? []).filter((c) => c.status === "active" && (c.catalog?.kind ?? c.provider) === provider).length

function trailing(provider: string, generic: boolean) {
  return () => {
    if (!providerAllowed(teamPolicy(), provider)) return Text(t("gallery.blocked", "Blocked by team")).font("caption").color("tertiary")
    if (generic) return smallButton(t("action.add", "Add"), () => open({ screen: "import", kind: provider as "openapi" | "graphql" | "mcp" }))
    if (!providerConfigured(list(), provider)) return Text(t("gallery.notConfigured", "Not set up yet")).font("caption").color("tertiary")
    return smallButton(connectedCount(provider) > 0 ? t("action.connectAnother", "Add Account") : t("action.connect", "Connect"), () => connect(provider))
  }
}

export function providerCard(provider: string, generic: boolean) {
  const info = providerInfo(provider)
  return HStack({ spacing: 10 }, [
    Icon(info.symbol).font("title3").color("secondary").frame({ width: 26 }),
    VStack({ spacing: 1 }, [
      HStack({ spacing: 6 }, [
        Text(info.name).weight("medium"),
        () => {
          const n = connectedCount(provider)
          return n > 0 ? Badge(t("gallery.connected", "{n} connected", { n }), "success").fixedSize() : null
        }
      ]),
      Text(providerBlurb(provider)).font("caption").color("secondary").lineLimit(2)
    ]),
    Spacer(),
    trailing(provider, generic)
  ]).padding({ top: 7, leading: 12, bottom: 7, trailing: 12 })
}

/** Both groups; `compact` drops the generic group's heading for narrow places. */
export function gallery() {
  return VStack({ spacing: 0 }, [
    sectionTitle(t("gallery.apps", "Apps")),
    ...FIRST_CLASS.map((p) => providerCard(p, false)),
    sectionTitle(t("gallery.anyApi", "Any API")),
    ...GENERIC.map((k) => providerCard(k, true))
  ])
}
