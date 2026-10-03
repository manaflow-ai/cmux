// Adding a generic integration (OpenAPI, GraphQL or MCP). Pasted JSON is
// ingested here with the core (adapted from executor, see LICENSE-executor), so
// the preview needs no network. A URL goes to the gateway's proposed
// `integration.catalog.preview`, which runs the same core server-side and can
// fetch private specs with a credential the app never sees.

import { importText, ImportError, type AuthMethod, type Catalog } from "@cmux/integrations-core"
import { t } from "../l10n.ts"
import type { Connection, Sharing } from "./connections.ts"
import { providerInfo } from "./providers.ts"
import { applyOwnerRecord, isMissing, open, problemOf, problemText, say, sayProblem } from "./store.ts"
import { rememberCatalog } from "./tools.ts"

export type ImportSource = { readonly url: string } | { readonly document: string }

export type ImportState =
  | { readonly phase: "idle" }
  | { readonly phase: "loading"; readonly source: ImportSource }
  | { readonly phase: "ready"; readonly source: ImportSource; readonly catalog: Catalog; readonly local: boolean }
  | { readonly phase: "error"; readonly text: string; readonly missing?: boolean }

const [importState, setImportState] = signal<ImportState>({ phase: "idle" })
const [authIndex, setAuthIndex] = signal(0)
export { importState, authIndex, setAuthIndex }

const importErrorText = (e: ImportError): string => {
  switch (e.code) {
    case "import.invalid_json":
      return t("import.error.json", "That is not valid JSON. Paste the whole document, or a URL.")
    case "import.swagger2":
      return t("import.error.swagger2", "Swagger 2.0 is not supported. Convert it to OpenAPI 3 first.")
    case "import.no_tools":
      return t("import.error.empty", "The document declares no operations.")
    default:
      return t("import.error.unknown", "Not an OpenAPI 3 document, a GraphQL introspection result or an MCP tool list.")
  }
}

const URL_RE = /^https?:\/\/\S+$/i

let generation = 0

/** Previews pasted JSON locally, or a URL through the gateway. */
export async function submitImport(text: string): Promise<void> {
  const value = text.trim()
  const mine = ++generation
  setAuthIndex(0)
  if (value === "") {
    setImportState({ phase: "idle" })
    return
  }
  if (value.startsWith("{")) {
    try {
      const catalog = importText(value)
      setImportState({ phase: "ready", source: { document: value }, catalog, local: true })
    } catch (e) {
      setImportState({ phase: "error", text: e instanceof ImportError ? importErrorText(e) : String(e) })
    }
    return
  }
  if (!URL_RE.test(value)) {
    setImportState({ phase: "error", text: t("import.hint", "Paste a spec URL, or the JSON of a spec, an introspection result or an MCP tool list.") })
    return
  }
  const source = { url: value }
  setImportState({ phase: "loading", source })
  try {
    const v = await cmux.call<{ catalog: Catalog }>("integration.catalog.preview", { source })
    if (mine === generation) setImportState({ phase: "ready", source, catalog: v.catalog, local: false })
  } catch (e) {
    const p = problemOf("integration.catalog.preview", e)
    if (mine === generation) setImportState({ phase: "error", text: problemText(p), missing: isMissing(p) })
  }
}

export const resetImport = () => {
  generation++
  setImportState({ phase: "idle" })
}

/** The auth method the user picked (the first declared one by default), or null for an API without auth. */
export const chosenAuth = (catalog: Catalog): AuthMethod | null => catalog.auth[authIndex()] ?? catalog.auth[0] ?? null

/**
 * Creates the generic connection. The owner re-ingests the source (the
 * preview is advisory) and the host collects the secret for the chosen method
 * in its own sheet, or opens the OAuth page; the app gets back a connection
 * whose credential is an opaque `cred_…` handle held by the gateway.
 */
export async function addImported(sharing: Sharing = "private"): Promise<void> {
  const s = importState()
  if (s.phase !== "ready") return
  const auth = chosenAuth(s.catalog)
  try {
    const r = await cmux.call<{ connection: Connection }>("integration.connect", {
      provider: s.catalog.kind,
      source: s.source,
      catalog: { digest: s.catalog.digest, namespace: s.catalog.namespace },
      ...(auth ? { auth: { kind: auth.kind, ...(auth.headers ? { headers: auth.headers } : {}), ...(auth.query ? { query: auth.query } : {}), ...(auth.flow ? { flow: auth.flow } : {}) } } : {}),
      sharing
    })
    rememberCatalog(s.catalog)
    applyOwnerRecord(r.connection)
    resetImport()
    open({ screen: "detail", id: r.connection.id })
    say(t("import.added", "Added {name}.", { name: s.catalog.title }), "success")
  } catch (e) {
    const p = problemOf("integration.connect", e)
    // Today's owner accepts only first-class providers and refuses the kind as invalid params.
    if (p.code === "validation.invalid" || p.code === "invalid_params") say(t("import.kindRefused", "This server cannot connect {kind} APIs yet.", { kind: providerInfo(s.catalog.kind).name }), "warning")
    else sayProblem(p)
  }
}
