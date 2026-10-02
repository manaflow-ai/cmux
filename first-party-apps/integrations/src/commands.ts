// Command exports (palette, CLI `cmux apps run`, MCP). Every command goes
// through the same model functions as the pane's buttons.

import { t } from "./l10n.ts"
import { connect as connectProvider } from "./model/actions.ts"
import { submitImport } from "./model/importer.ts"
import { FIRST_CLASS } from "./model/providers.ts"
import { codeOf, open, reload } from "./model/store.ts"
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
  if (typeof provider !== "string" || !(FIRST_CLASS as readonly string[]).includes(provider)) throw invalid(t("command.connect.invalid", "provider must be one of: {list}", { list: FIRST_CLASS.join(", ") }))
  await connectProvider(provider)
  return { opened: await openPane() }
}

export async function importApi(args: { source?: string } = {}) {
  if (typeof args.source !== "string" || !args.source.trim()) throw invalid(t("command.import.invalid", "source must be a spec URL or JSON"))
  open({ screen: "import" })
  await submitImport(args.source)
  return { opened: await openPane() }
}

export async function cycleVariant() {
  return cycle()
}
