// Adding a generic integration (OpenAPI, GraphQL or MCP over Streamable HTTP).
// Pasted JSON is ingested here with the core (adapted from executor, see
// LICENSE-executor), so the preview needs no network. A URL is pre-checked with
// the core's egress rules and the team's `generic_hosts`, then goes to the
// gateway's `integration.catalog.preview`, which fetches it with the real SSRF
// guard (DNS, redirects, 10 MB, 30 s) and runs the same core server-side.

import {
  authChoices,
  checkDocumentSize,
  checkEgressUrl,
  importText,
  ImportError,
  isCommandLine,
  isPrivateHost,
  parseHttpUrl,
  type AuthChoice,
  type Catalog,
  type EgressErrorCode
} from "@cmux/integrations-core"
import { t } from "../l10n.ts"
import { genericHostAllowed, providerAllowed, type Connection, type Sharing } from "./connections.ts"
import { providerInfo } from "./providers.ts"
import { refuseAtLimit } from "./actions.ts"
import { applyOwnerRecord, egressText, isMissing, open, problemOf, problemText, say, sayProblem, teamPolicy } from "./store.ts"
import { rememberCatalog } from "./tools.ts"

export type ImportSource = { readonly url: string } | { readonly document: string }

/** Why a previewed catalog cannot be added here: its target host is private or outside the team's `generic_hosts`. */
export interface Blocked {
  readonly code: EgressErrorCode | "policy.denied"
  readonly host?: string
}

export type ImportState =
  | { readonly phase: "idle" }
  | { readonly phase: "loading"; readonly source: ImportSource }
  | { readonly phase: "ready"; readonly source: ImportSource; readonly catalog: Catalog; readonly local: boolean; readonly blocked: Blocked | null }
  | { readonly phase: "error"; readonly text: string; readonly missing?: boolean; readonly code?: string }

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
    case "import.mcp_stdio":
    case "catalog.too_large":
      return egressText(e.code) ?? e.message
    default:
      return t("import.error.unknown", "Not an OpenAPI 3 document, a GraphQL introspection result or an MCP tool list.")
  }
}

const fail = (code: string, host?: string) => setImportState({ phase: "error", code, text: egressText(code, host) ?? code })

/** The host a generic connection would call: the API's base URL, else the URL it came from. */
export const targetHost = (catalog: Catalog, source: ImportSource): string | null => {
  const base = catalog.base_url && /^https?:\/\//i.test(catalog.base_url) ? catalog.base_url : "url" in source ? source.url : null
  return base ? (parseHttpUrl(base)?.host ?? null) : null
}

/** The add flow's pre-check of the target (the owner enforces for real): team kind allowlist, private hosts, `generic_hosts`. */
export const blockedReason = (catalog: Catalog, source: ImportSource): Blocked | null => {
  const policy = teamPolicy()
  if (!providerAllowed(policy, catalog.kind)) return { code: "policy.denied" }
  const host = targetHost(catalog, source)
  if (!host) return null
  if (isPrivateHost(host)) return { code: "egress.private_target", host }
  if (!genericHostAllowed(policy, host)) return { code: "egress.host_not_allowed", host }
  return null
}

let generation = 0

const ready = (source: ImportSource, catalog: Catalog, local: boolean) => setImportState({ phase: "ready", source, catalog, local, blocked: blockedReason(catalog, source) })

/** Previews pasted JSON locally, or a URL through the gateway after the egress pre-checks. */
export async function submitImport(text: string): Promise<void> {
  const value = text.trim()
  const mine = ++generation
  setAuthIndex(0)
  if (value === "") {
    setImportState({ phase: "idle" })
    return
  }
  if (value.startsWith("{")) {
    const tooLarge = checkDocumentSize(value)
    if (tooLarge && !tooLarge.ok) return fail(tooLarge.code)
    try {
      ready({ document: value }, importText(value), true)
    } catch (e) {
      setImportState({ phase: "error", text: e instanceof ImportError ? importErrorText(e) : String(e), ...(e instanceof ImportError ? { code: e.code } : {}) })
    }
    return
  }
  if (isCommandLine(value)) return fail("import.mcp_stdio")
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(value)) {
    setImportState({ phase: "error", text: t("import.hint", "Paste a spec URL, or the JSON of a spec, an introspection result or an MCP tool list.") })
    return
  }
  const pre = checkEgressUrl(value)
  if (!pre.ok) return fail(pre.code, pre.host)
  if (!genericHostAllowed(teamPolicy(), pre.host)) return fail("egress.host_not_allowed", pre.host)
  const source = { url: value }
  setImportState({ phase: "loading", source })
  try {
    const v = await cmux.call<{ catalog: Catalog }>("integration.catalog.preview", { source })
    if (mine === generation) ready(source, v.catalog, false)
  } catch (e) {
    const p = problemOf("integration.catalog.preview", e)
    if (mine === generation) setImportState({ phase: "error", text: problemText(p), missing: isMissing(p), code: p.code })
  }
}

export const resetImport = () => {
  generation++
  setImportState({ phase: "idle" })
}

/** Auth kinds the add flow offers for a catalog: declared methods first, then the other kinds. */
export const choicesFor = (catalog: Catalog): AuthChoice[] => authChoices(catalog.kind, catalog.auth)

/** The auth kind the user picked (the first offered one by default). */
export const chosenAuth = (catalog: Catalog): AuthChoice | null => {
  const choices = choicesFor(catalog)
  return choices[authIndex()] ?? choices[0] ?? null
}

/** Connect params for the chosen auth kind: where the secret goes, never the secret. */
const authParams = (c: AuthChoice) => {
  const m = c.method
  return {
    kind: c.kind,
    ...(m?.headers ? { headers: m.headers } : {}),
    ...(m?.query ? { query: m.query } : {}),
    ...(m?.scopes?.length ? { scopes: m.scopes } : {}),
    ...(c.dynamic_registration ? { dynamic_registration: true } : {})
  }
}

/**
 * Creates the generic connection. The owner re-ingests the source (the
 * preview is advisory). For any kind but `none` the host opens its own secure
 * sheet (or the OAuth page) before forwarding the call; the gateway seals the
 * secret behind a `cred_…` handle the app never sees. A cancelled sheet
 * answers `user.cancelled`.
 */
export async function addImported(sharing: Sharing = "private"): Promise<void> {
  const s = importState()
  if (s.phase !== "ready" || s.blocked) return
  if (refuseAtLimit()) return
  const auth = chosenAuth(s.catalog)
  try {
    const r = await cmux.call<{ connection: Connection; authorize_url?: string; opened?: boolean }>("integration.connect", {
      provider: s.catalog.kind,
      source: s.source,
      catalog: { digest: s.catalog.digest, namespace: s.catalog.namespace },
      auth: auth ? authParams(auth) : { kind: "none" },
      sharing
    })
    rememberCatalog(s.catalog)
    applyOwnerRecord(r.connection)
    resetImport()
    open({ screen: "detail", id: r.connection.id })
    say(t("import.added", "Added {name}.", { name: s.catalog.title }), "success")
  } catch (e) {
    const p = problemOf("integration.connect", e)
    // An owner without generic kinds refuses the kind as invalid params.
    if (p.code === "validation.invalid" || p.code === "invalid_params") say(t("import.kindRefused", "This server cannot connect {kind} APIs yet.", { kind: providerInfo(s.catalog.kind).name }), "warning")
    else sayProblem(p)
  }
}
