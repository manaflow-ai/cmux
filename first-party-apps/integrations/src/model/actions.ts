// User actions on connections. Each runs one owner op as its first call, so a
// tap's gesture token goes with it (origin user). Results come back from the
// owner and are shown at once; the change event then reloads the list.

import { t } from "../l10n.ts"
import type { Connection, Sharing } from "./connections.ts"
import { providerInfo } from "./providers.ts"
import { applyOwnerRecord, open, problemOf, reload, say, sayProblem } from "./store.ts"

const [confirmingRevoke, setConfirmingRevoke] = signal<string | null>(null)
export { confirmingRevoke }

interface ConnectResult {
  readonly connection: Connection
  readonly authorize_url?: string
  /** Proposed host behavior: the host opens authorize_url for an app call made with a gesture and adds `opened`. */
  readonly opened?: boolean
}

/** Today's host does not open the approval page for an app; say so instead of claiming it opened. */
function approvalNotice(r: ConnectResult, provider: string) {
  const name = providerInfo(provider).name
  if (r.opened === true) say(t("connect.browser", "Approve {provider} in your browser.", { provider: name }))
  else say(t("connect.notOpened", "This cmux cannot open the {provider} approval page from an app yet.", { provider: name }), "warning")
}

/**
 * Starts connecting a first-class provider. The owner returns a pending
 * connection; approval happens in the browser (the dashboard finishes it with
 * the user's own session), so the app never touches a token.
 */
export async function connect(provider: string, sharing: Sharing = "private"): Promise<void> {
  try {
    const r = await cmux.call<ConnectResult>("integration.connect", { provider, sharing })
    applyOwnerRecord(r.connection)
    open({ screen: "detail", id: r.connection.id })
    approvalNotice(r, provider)
  } catch (e) {
    sayProblem(problemOf("integration.connect", e))
  }
}

/** Signs in again for a connection that needs it; the connection keeps its id, sharing and tool rules. */
export async function reconnect(c: Connection): Promise<void> {
  try {
    const r = await cmux.call<ConnectResult>("integration.reauth", { connection: c.id })
    applyOwnerRecord(r.connection)
    approvalNotice(r, c.provider)
  } catch (e) {
    sayProblem(problemOf("integration.reauth", e))
  }
}

/** Shares with the team or makes private again (the creator only; the owner checks). */
export async function share(c: Connection, sharing: Sharing): Promise<void> {
  try {
    const r = await cmux.call<Connection>("integration.share", { connection: c.id, sharing })
    applyOwnerRecord(r)
    say(sharing === "team" ? t("share.done", "Shared with your team.") : t("share.private", "Only you can use it now."), "success")
  } catch (e) {
    sayProblem(problemOf("integration.share", e))
  }
}

/** First tap arms, second tap disconnects: the owner deletes the stored credential at once. */
export async function revoke(c: Connection): Promise<void> {
  if (confirmingRevoke() !== c.id) {
    setConfirmingRevoke(c.id)
    return
  }
  setConfirmingRevoke(null)
  try {
    const r = await cmux.call<Connection>("integration.revoke", { connection: c.id })
    applyOwnerRecord(r)
    open({ screen: "home" })
    say(t("revoke.done", "Disconnected {name}.", { name: c.account?.name ?? providerInfo(c.provider).name }))
  } catch (e) {
    sayProblem(problemOf("integration.revoke", e))
  }
}

export const cancelRevoke = () => setConfirmingRevoke(null)

/** Reload on demand (the Refresh button); change events reload on their own. */
export const refresh = () => reload()
