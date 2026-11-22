// One connection: health, catalog changes, account, sharing, team policy, MCP
// exposure, actions, and its tools with per-tool policy. Every value shown
// comes from the owner's record.

import { MCP_ENDPOINT_PATH } from "@cmux/integrations-core"
import { t } from "../l10n.ts"
import { openFeedItem, reconnect, revoke, setMcpExposed, share } from "../model/actions.ts"
import { displayName, needsAttention, permissionsFor, policySourceLabel, providerAllowed, providerOf, type Connection } from "../model/connections.ts"
import { providerInfo } from "../model/providers.ts"
import { findConnection, list, teamPolicy } from "../model/store.ts"
import { loadTools, mcpNameMap } from "../model/tools.ts"
import { aboutLine, credentialKindText, dayText, header, noticeLine, onOffControl, sectionTitle, smallButton, statusBadge } from "./common.ts"
import { toolList } from "./policy.ts"

const line = (label: string, value: string | (() => string)) =>
  HStack({ spacing: 8 }, [Text(label).font("caption").color("secondary").frame({ width: 92 }), Text(value).font("caption").lineLimit(2), Spacer()]).padding({ top: 2, leading: 12, bottom: 2, trailing: 12 })

const note = (text: string, tone = "tertiary") => Text(text).font("caption2").color(tone).lineLimit(3).fixedSize("vertical").padding({ top: 2, leading: 12, bottom: 2, trailing: 12 })

const sharingText = (c: Connection) => (c.sharing === "team" ? t("sharing.team", "Shared with team") : t("sharing.private", "Only you"))

const perms = (c: Connection) => permissionsFor(c, list()?.viewer)

/** A box with one padding inside and the outer margin on a wrapper (modifiers are single props). */
const box = (children: Array<CmuxView | null>) => HStack({ spacing: 0 }, [VStack({ spacing: 6 }, children.filter((v): v is CmuxView => v !== null)).padding(10).background("hover").cornerRadius(6)]).padding({ top: 4, leading: 12, bottom: 6, trailing: 12 })

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
    const p = perms(conn)
    return box([
      Text(why).font("caption").color(conn.status === "error" ? "danger" : "warning").lineLimit(4).fixedSize("vertical"),
      p.reauth ? smallButton(conn.status === "expired" ? t("action.tryAgain", "Try Again") : t("action.reconnect", "Sign In Again"), () => reconnect(c())) : null,
      Text(p.reauth ? t("health.keeps", "Signing in again keeps this connection, its sharing and its tool rules.") : t("health.creatorOnly", "The person who connected it or a team admin can sign in again."))
        .font("caption2")
        .color("tertiary")
        .lineLimit(2)
        .fixedSize("vertical")
    ])
  }
}

/** The owner re-ingests catalogs daily and posts a feed notice when one changes; the record says so (no polling here). */
function catalogChanged(c: () => Connection) {
  return () => {
    const changed = c().catalog?.changed
    if (!changed) return null
    return box([
      Text(t("catalog.changed", "The API changed on {day}. New tools start at their defaults; your rules stay.", { day: dayText(changed.at) }))
        .font("caption")
        .color("warning")
        .lineLimit(3)
        .fixedSize("vertical"),
      smallButton(t("action.openFeed", "Open in Feed"), () => openFeedItem(changed.feed_item))
    ])
  }
}

function actions(c: () => Connection) {
  return () => {
    const conn = c()
    if (conn.status === "revoked") return null
    const p = perms(conn)
    const why = p.revoke === "team_admin" ? t("revoke.asAdmin", "You disconnect it as a team admin. The audit log records it.") : p.revoke === null ? t("revoke.needsAdmin", "Only the person who connected it or a team admin can disconnect it.") : null
    return VStack({ spacing: 0 }, [
      HStack({ spacing: 8 }, [
        !p.share ? null : conn.sharing === "team" ? smallButton(t("action.makePrivate", "Make Private"), () => share(c(), "private")) : smallButton(t("action.shareTeam", "Share with Team"), () => share(c(), "team")),
        Spacer(),
        p.revoke ? smallButton(t("action.disconnect", "Disconnect"), () => revoke(c())).destructive() : null
      ]).padding({ top: 8, leading: 12, bottom: 2, trailing: 12 }),
      why ? note(why) : null
    ])
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

/** Opt-in exposure on the principal's MCP endpoint. */
function mcpBlock(c: () => Connection) {
  const on = () => c().mcp_exposed === true
  return VStack({ spacing: 0 }, [
    HStack({ spacing: 8 }, [Text(t("mcp.title", "Agents over MCP")).font("caption").color("secondary"), Spacer(), onOffControl(on, (v) => setMcpExposed(c(), v))]).padding({ top: 6, leading: 12, bottom: 2, trailing: 12 }),
    () => {
      if (!on()) return note(t("mcp.off", "Off: agents do not see these tools at {path}.", { path: MCP_ENDPOINT_PATH }))
      const id = c().id
      const n = [...mcpNameMap().keys()].filter((k) => k.startsWith(`${id}|`)).length
      return note(t("mcp.on", "{n} tools at {path}. Block tools are hidden; Ask waits for approval in the feed or the agent.", { n, path: MCP_ENDPOINT_PATH }))
    }
  ])
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
      catalogChanged(conn),
      () => (conn().account ? line(t("detail.account", "Account"), () => conn().account?.name ?? "") : null),
      () => (conn().catalog ? line(t("detail.api", "API"), () => `${conn().catalog!.title}${conn().catalog!.version ? ` ${conn().catalog!.version}` : ""}`) : null),
      () => (conn().catalog?.source_url ? line(t("detail.source", "Source"), () => conn().catalog?.source_url ?? "") : null),
      () => (conn().auth ? line(t("detail.signIn", "Sign-in"), () => credentialKindText(conn().auth!.kind)) : null),
      line(t("detail.sharing", "Sharing"), () => sharingText(conn())),
      () => (conn().scopes_granted.length ? line(t("detail.scopes", "Permissions"), () => conn().scopes_granted.join(", ")) : null),
      () => (conn().resources?.repos ? line(t("detail.repos", "Repositories"), () => t("detail.repoCount", "{n} repositories", { n: conn().resources?.repos?.length ?? 0 })) : null),
      policyNote(conn),
      mcpBlock(conn),
      actions(conn),
      Divider().padding({ top: 6, leading: 12, bottom: 0, trailing: 12 }),
      sectionTitle(t("detail.tools", "Tools and policy")),
      toolList(conn),
      () => (conn().catalog ? aboutLine() : null)
    ])
  }
}
