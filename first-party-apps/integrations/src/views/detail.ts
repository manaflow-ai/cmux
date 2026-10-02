// One connection: health, account, sharing, team policy, actions, and its tools
// with per-tool policy. Every value shown comes from the owner's record.

import { t } from "../l10n.ts"
import { cancelRevoke, confirmingRevoke, reconnect, revoke, share } from "../model/actions.ts"
import { displayName, needsAttention, policySourceLabel, providerAllowed, providerOf, type Connection } from "../model/connections.ts"
import { providerInfo } from "../model/providers.ts"
import { findConnection, teamPolicy } from "../model/store.ts"
import { loadTools } from "../model/tools.ts"
import { aboutLine, header, noticeLine, sectionTitle, smallButton, statusBadge } from "./common.ts"
import { toolList } from "./policy.ts"

const line = (label: string, value: string | (() => string)) =>
  HStack({ spacing: 8 }, [Text(label).font("caption").color("secondary").frame({ width: 92 }), Text(value).font("caption").lineLimit(2), Spacer()]).padding({ top: 2, leading: 12, bottom: 2, trailing: 12 })

const sharingText = (c: Connection) => (c.sharing === "team" ? t("sharing.team", "Shared with team") : t("sharing.private", "Only you"))

function healthBlock(c: () => Connection) {
  return () => {
    const conn = c()
    if (!needsAttention(conn) && conn.status !== "expired") return null
    const why =
      conn.status_detail ??
      (conn.status === "needs_reauth"
        ? t("health.reauth", "The provider no longer accepts the stored sign-in. Agents and automations using it are paused.")
        : conn.status === "expired"
          ? t("health.expired", "Nobody approved this connection in time.")
          : t("health.error", "The last call to the provider failed."))
    // One padding per node (modifiers are props), so the outer margin is a wrapper.
    return HStack({ spacing: 0 }, [
      VStack({ spacing: 6 }, [
        Text(why).font("caption").color(conn.status === "error" ? "danger" : "warning").lineLimit(4).fixedSize("vertical"),
        conn.capabilities?.reauth === false ? null : smallButton(conn.status === "expired" ? t("action.tryAgain", "Try Again") : t("action.reconnect", "Sign In Again"), () => reconnect(c()))
      ])
        .padding(10)
        .background("hover")
        .cornerRadius(6)
    ]).padding({ top: 4, leading: 12, bottom: 6, trailing: 12 })
  }
}

function actions(c: () => Connection) {
  return () => {
    const conn = c()
    if (conn.status === "revoked") return null
    const arming = confirmingRevoke() === conn.id
    return HStack({ spacing: 8 }, [
      conn.capabilities?.share === false
        ? null
        : conn.sharing === "team"
          ? smallButton(t("action.makePrivate", "Make Private"), () => share(c(), "private"))
          : smallButton(t("action.shareTeam", "Share with Team"), () => share(c(), "team")),
      Spacer(),
      arming ? smallButton(t("action.cancel", "Cancel"), cancelRevoke) : null,
      conn.capabilities?.revoke === false ? null : smallButton(arming ? t("action.disconnectConfirm", "Disconnect?") : t("action.disconnect", "Disconnect"), () => revoke(c())).destructive()
    ]).padding({ top: 8, leading: 12, bottom: 4, trailing: 12 })
  }
}

function policyNote(c: () => Connection) {
  return () => {
    const p = teamPolicy()
    if (!p) return null
    const conn = c()
    const allowed = providerAllowed(p, conn.provider)
    const source = policySourceLabel(p)
    const text = allowed ? source : t("policy.providerBlocked", "Your team no longer allows {provider}; calls are refused.", { provider: providerInfo(conn.provider).name })
    if (!text) return null
    return Text(text)
      .font("caption")
      .color(allowed ? "tertiary" : "warning")
      .fixedSize("vertical")
      .padding({ top: 2, leading: 12, bottom: 2, trailing: 12 })
  }
}

export function detailView(id: string) {
  const c = () => findConnection(id)
  // Load the tool catalog once per screen; a list reload does not refetch it.
  const first = untrack(c)
  if (first) loadTools(first)
  const exists = computed(() => !!c())
  return VStack({ spacing: 0 }, [
    () => {
      const present = exists()
      return untrack(() => body(present))
    }
  ])
  function body(present: boolean) {
    if (!present) return VStack({ spacing: 0 }, [header(t("detail.missing", "Connection"), [], true), EmptyState({ title: t("detail.gone", "This connection is gone"), symbol: "questionmark.circle" })])
    const conn = c as () => Connection
    return VStack({ spacing: 0 }, [
      header(() => displayName(conn()), [], true),
      noticeLine(),
      HStack({ spacing: 8 }, [Icon(() => providerInfo(providerOf(conn())).symbol).color("secondary"), Text(() => providerInfo(providerOf(conn())).name).font("caption").color("secondary"), Spacer(), () => statusBadge(conn())]).padding({ top: 0, leading: 12, bottom: 6, trailing: 12 }),
      healthBlock(conn),
      () => (conn().account ? line(t("detail.account", "Account"), () => conn().account?.name ?? "") : null),
      () => (conn().catalog ? line(t("detail.api", "API"), () => `${conn().catalog!.title}${conn().catalog!.version ? ` ${conn().catalog!.version}` : ""}`) : null),
      () => (conn().catalog?.source_url ? line(t("detail.source", "Source"), () => conn().catalog?.source_url ?? "") : null),
      line(t("detail.sharing", "Sharing"), () => sharingText(conn())),
      () => (conn().scopes_granted.length ? line(t("detail.scopes", "Permissions"), () => conn().scopes_granted.join(", ")) : null),
      () => (conn().resources?.repos ? line(t("detail.repos", "Repositories"), () => t("detail.repoCount", "{n} repositories", { n: conn().resources?.repos?.length ?? 0 })) : null),
      policyNote(conn),
      actions(conn),
      Divider().padding({ top: 6, leading: 12, bottom: 0, trailing: 12 }),
      sectionTitle(t("detail.tools", "Tools and policy")),
      toolList(conn),
      () => (conn().catalog ? aboutLine() : null)
    ])
  }
}
