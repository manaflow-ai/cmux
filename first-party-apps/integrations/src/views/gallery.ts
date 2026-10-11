// The provider gallery: first-class apps with a Connect button, and the
// generic kinds (OpenAPI, GraphQL, MCP over Streamable HTTP) that open the
// importer. Each card says why it cannot connect: coming soon, not set up on
// this server, blocked by the team policy, or the team is at its connection
// limit. The team's host allowlist for generic APIs is shown above them.

import { t } from "../l10n.ts"
import { connect } from "../model/actions.ts"
import { atLimit, connectionUsage, providerAllowed, providerConfigured } from "../model/connections.ts"
import { FIRST_CLASS, GENERIC, providerBlurb, providerInfo } from "../model/providers.ts"
import { list, open, teamPolicy } from "../model/store.ts"
import { sectionTitle, smallButton } from "./common.ts"

const connectedCount = (provider: string) => (list()?.connections ?? []).filter((c) => c.status === "active" && (c.catalog?.kind ?? c.provider) === provider).length

const muted = (text: string) => Text(text).font("caption").color("tertiary")

function trailing(provider: string, generic: boolean) {
  return () => {
    const info = providerInfo(provider)
    if (info.availability === "coming") return Badge(t("gallery.coming", "Coming"), "secondary").fixedSize()
    if (!providerAllowed(teamPolicy(), provider)) return muted(t("gallery.blocked", "Blocked by team"))
    if (!generic && !providerConfigured(list(), provider)) return muted(t("gallery.notConfigured", "Not set up yet"))
    const full = atLimit(list())
    const label = generic ? t("action.add", "Add") : connectedCount(provider) > 0 ? t("action.connectAnother", "Add Account") : t("action.connect", "Connect")
    return smallButton(label, () => (generic ? open({ screen: "import", kind: provider as "openapi" | "graphql" | "mcp" }) : connect(provider))).disabled(full)
  }
}

export function providerCard(provider: string, generic: boolean) {
  const info = providerInfo(provider)
  return HStack({ spacing: 10 }, [
    Icon(info.symbol).font("title3").color("secondary").frame({ width: 26 }),
    VStack({ spacing: 1 }, [
      HStack({ spacing: 6 }, [
        Text(info.name).weight("medium").lineLimit(1).fixedSize(),
        () => {
          const n = connectedCount(provider)
          return n > 0 ? Badge(t("gallery.connected", "{n} connected", { n }), "success").fixedSize() : null
        }
      ]),
      Text(providerBlurb(provider)).font("caption").color("secondary").lineLimit(2)
    ])
      .frame({ maxWidth: "infinity" })
      .layoutPriority(1),
    trailing(provider, generic)
  ]).padding({ top: 7, leading: 12, bottom: 7, trailing: 12 })
}

/** "12 of 50 connections", and why Connect is off at the limit. */
export function usageLine() {
  return () => {
    const u = connectionUsage(list())
    const full = u.used >= u.max
    return Text(full ? t("usage.full", "{used} of {max} connections: disconnect one to add another.", u) : t("usage.line", "{used} of {max} connections", u))
      .font("caption2")
      .color(full ? "warning" : "tertiary")
      .lineLimit(2)
      .padding({ top: 2, leading: 12, bottom: 4, trailing: 12 })
  }
}

/** The team's `generic_hosts` allowlist, when it has one. */
export function hostsLine() {
  return () => {
    const hosts = teamPolicy()?.generic_hosts
    if (!hosts) return null
    return Text(hosts.length === 0 ? t("hosts.none", "Your team allows no hosts for generic APIs.") : t("hosts.list", "Your team allows APIs on: {hosts}", { hosts: hosts.join(", ") }))
      .font("caption2")
      .color("tertiary")
      .lineLimit(3)
      .fixedSize("vertical")
      .padding({ top: 0, leading: 12, bottom: 2, trailing: 12 })
  }
}

/** Both groups. */
export function gallery() {
  return VStack({ spacing: 0 }, [
    usageLine(),
    sectionTitle(t("gallery.apps", "Apps")),
    ...FIRST_CLASS.map((p) => providerCard(p, false)),
    sectionTitle(t("gallery.anyApi", "Any API")),
    hostsLine(),
    ...GENERIC.map((k) => providerCard(k, true))
  ])
}
