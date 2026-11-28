// User actions on connections. Each runs one owner op as its first call, so a
// tap's gesture token goes with it (origin user). Results come back from the
// owner and are shown at once; the change event then reloads the list.

import { t } from "../l10n.ts"
import { atLimit, displayName, type Connection, type Sharing } from "./connections.ts"
import { providerInfo } from "./providers.ts"
import { applyOwnerRecord, list, open, problemOf, problemText, reload, say, sayProblem } from "./store.ts"

interface ConnectResult {
  readonly connection: Connection
  readonly authorize_url?: string
  /** Host behavior: the host opens authorize_url for an app call made with a gesture and adds `opened`. */
  readonly opened?: boolean
}

/** Today's host does not open the approval page for an app; say so instead of claiming it opened. */
function approvalNotice(r: ConnectResult, name: string) {
  if (!r.authorize_url && r.connection.status === "active") return
  if (r.opened === true) say(t("connect.browser", "Approve {provider} in your browser.", { provider: name }))
  else say(t("connect.notOpened", "This cmux cannot open the {provider} approval page from an app yet.", { provider: name }), "warning")
}

/** The add flow refuses at the limit before asking the owner; the owner refuses for real (`integration.limit`). */
export function refuseAtLimit(): boolean {
  if (!atLimit(list())) return false
  sayProblem({ op: "integration.connect", code: "integration.limit", message: "" })
  return true
}

/**
 * Starts connecting a first-class provider. The owner returns a pending
 * connection; approval happens in the browser (the dashboard finishes it with
 * the user's own session), so the app never touches a token.
 */
export async function connect(provider: string, sharing: Sharing = "private"): Promise<void> {
  const info = providerInfo(provider)
  if (info.availability === "coming") {
    say(t("connect.coming", "{provider} is coming soon.", { provider: info.name }))
    return
  }
  if (refuseAtLimit()) return
  try {
    const r = await cmux.call<ConnectResult>("integration.connect", { provider, sharing })
    applyOwnerRecord(r.connection)
    open({ screen: "detail", id: r.connection.id })
    approvalNotice(r, info.name)
  } catch (e) {
    sayProblem(problemOf("integration.connect", e))
  }
}

/** Signs in again: the owner keeps the connection's id, sharing and tool rules and replaces only the sealed credential. */
export async function reconnect(c: Connection): Promise<void> {
  try {
    const r = await cmux.call<ConnectResult>("integration.reauth", { connection: c.id })
    applyOwnerRecord(r.connection)
    approvalNotice(r, displayName(c))
  } catch (e) {
    sayProblem(problemOf("integration.reauth", e))
  }
}

/** Shares with the team or makes private again (the creator or a team admin; the owner checks). */
export async function share(c: Connection, sharing: Sharing): Promise<void> {
  try {
    const r = await cmux.call<Connection>("integration.share", { connection: c.id, sharing })
    applyOwnerRecord(r)
    say(sharing === "team" ? t("share.done", "Shared with your team.") : t("share.private", "Only you can use it now."), "success")
  } catch (e) {
    sayProblem(problemOf("integration.share", e))
  }
}

/**
 * Disconnects. The tap's gesture token goes with the call; the shell shows its
 * own confirmation sheet before it forwards the call to the owner, which
 * deletes the sealed credential at once (and audits an admin's revoke). A
 * cancelled sheet answers `user.cancelled`.
 */
export async function revoke(c: Connection): Promise<void> {
  try {
    const r = await cmux.call<Connection>("integration.revoke", { connection: c.id })
    applyOwnerRecord(r)
    open({ screen: "home" })
    say(t("revoke.done", "Disconnected {name}.", { name: displayName(c) }))
  } catch (e) {
    const p = problemOf("integration.revoke", e)
    if (p.code === "user.cancelled") say(t("revoke.kept", "{name} stays connected.", { name: displayName(c) }))
    else sayProblem(p)
  }
}

/** Opts a connection in to (or out of) the `/v1/mcp` endpoint. The owner answers with the record. */
export async function setMcpExposed(c: Connection, exposed: boolean): Promise<void> {
  try {
    const r = await cmux.call<Connection>("integration.mcp.set", { connection: c.id, exposed })
    applyOwnerRecord(r)
  } catch (e) {
    sayProblem(problemOf("integration.mcp.set", e))
  }
}

/** Opens the feed notice the owner posted about a catalog change (the app does not poll for changes). */
export async function openFeedItem(item: string): Promise<void> {
  try {
    await cmux.call("ui.open", { interface: "cmux.feed/1", target: { item } })
  } catch (e) {
    say(problemText(problemOf("ui.open", e)))
  }
}

/** Reload on demand (the Refresh button); change events reload on their own. */
export const refresh = () => reload()
