// Command exports (palette, CLI `cmux apps run`, MCP). Every command goes
// through the same model functions as the pane's buttons.

import { t } from "./l10n.ts"
import { connect as connectProvider } from "./model/actions.ts"
import { submitImport } from "./model/importer.ts"
import { normalizeTeams, type LinearTeamsResult } from "./model/linear.ts"
import { CONNECTABLE } from "./model/providers.ts"
import { codeOf, findConnection, open, reload } from "./model/store.ts"
import { cycleVariant as cycle } from "./settings.ts"

type CmuxErrorConstructor = new (code: string, message: string) => CmuxError
/** A thrown CmuxError reaches CLI and MCP callers as {code, message}. */
const invalid = (message: string): CmuxError => new (CmuxError as unknown as CmuxErrorConstructor)("invalid_params", message)

/** Opens this app's pane (proposed `app.pane.open`, owner shell). Returns whether it opened. */
async function openPane(): Promise<boolean> {
  try {
    await cmux.call("app.pane.open", { kind: "pane" })
    return true
  } catch (e) {
    cmux.log("app.pane.open:", codeOf(e))
    return false
  }
}

export async function openIntegrations(args: { connection?: string } = {}) {
  open(typeof args.connection === "string" && args.connection ? { screen: "detail", id: args.connection } : { screen: "home" })
  await reload()
  return { opened: await openPane() }
}

export async function connect(args: { provider?: string } = {}) {
  const provider = args.provider
  if (typeof provider !== "string" || !(CONNECTABLE as readonly string[]).includes(provider)) throw invalid(t("command.connect.invalid", "provider must be one of: {list}", { list: CONNECTABLE.join(", ") }))
  await connectProvider(provider)
  return { opened: await openPane() }
}

export async function importApi(args: { source?: string } = {}) {
  if (typeof args.source !== "string" || !args.source.trim()) throw invalid(t("command.import.invalid", "source must be a spec URL or JSON"))
  open({ screen: "import" })
  await submitImport(args.source)
  return { opened: await openPane() }
}

/** Lists the teams on one active Linear connection without exposing provider fields. */
export async function linearTeams(args: { connection?: string } = {}): Promise<LinearTeamsResult & { connection: string; opened: boolean }> {
  if (typeof args.connection !== "string" || !args.connection.trim()) throw invalid(t("command.linearTeams.invalidConnection", "connection must be a non-empty id"))
  const connection = args.connection.trim()
  await reload()
  const record = findConnection(connection)
  if (!record) throw invalid(t("command.linearTeams.notFound", "connection {connection} was not found", { connection }))
  if (record.provider !== "linear") throw invalid(t("command.linearTeams.notLinear", "connection {connection} is not a Linear connection", { connection }))
  if (record.status !== "active") throw invalid(t("command.linearTeams.notActive", "connection {connection} is not active", { connection }))

  let result: LinearTeamsResult
  try {
    result = normalizeTeams(await cmux.call<unknown>("linear.teams.list", { connection }))
  } catch (error) {
    if (error instanceof TypeError && error.message.startsWith("Linear teams response")) throw invalid(t("command.linearTeams.invalidResponse", "Linear returned an invalid teams response"))
    throw error
  }
  open({ screen: "detail", id: connection })
  return { connection, ...result, opened: await openPane() }
}

export async function cycleVariant() {
  return cycle()
}
