// Adapted from executor (https://github.com/UsefulSoftwareCo/executor), MIT License, Copyright (c) 2026 Rhys Sullivan
// Upstream: packages/plugins/openapi/src/sdk/preview.ts (extractFlows,
// extractSecuritySchemes, buildHeaderPresets, buildOAuth2Presets and the
// strategy fallback in previewSpecText).
// Changes for cmux: plain TypeScript; header and OAuth2 presets become cmux
// `AuthMethod`s (api_key, bearer, basic, headers, oauth2) that name where a
// secret goes but never hold it; the host turns a method into a `cred_…` handle.

import type { DocResolver } from "./openapi.ts"
import { isRecord, type AuthMethod } from "./types.ts"

interface SecurityScheme {
  readonly name: string
  readonly type: "http" | "apiKey" | "oauth2" | "openIdConnect"
  readonly scheme?: string
  readonly in?: string
  readonly paramName?: string
  readonly flows?: { authorizationCode?: Flow; clientCredentials?: Flow }
}

interface Flow {
  readonly authorizationUrl?: string
  readonly tokenUrl: string
  readonly scopes: string[]
}

const TYPES = new Set(["http", "apiKey", "oauth2", "openIdConnect"])

const scopesOf = (v: unknown): string[] => (isRecord(v) ? Object.keys(v) : [])

const extractFlows = (rawFlows: unknown): SecurityScheme["flows"] => {
  if (!isRecord(rawFlows)) return undefined
  const out: { authorizationCode?: Flow; clientCredentials?: Flow } = {}
  const ac = rawFlows.authorizationCode
  if (isRecord(ac) && typeof ac.authorizationUrl === "string" && typeof ac.tokenUrl === "string") {
    out.authorizationCode = { authorizationUrl: ac.authorizationUrl, tokenUrl: ac.tokenUrl, scopes: scopesOf(ac.scopes) }
  }
  const cc = rawFlows.clientCredentials
  if (isRecord(cc) && typeof cc.tokenUrl === "string") out.clientCredentials = { tokenUrl: cc.tokenUrl, scopes: scopesOf(cc.scopes) }
  return out.authorizationCode || out.clientCredentials ? out : undefined
}

const extractSecuritySchemes = (raw: unknown, resolver: DocResolver): SecurityScheme[] =>
  Object.entries(isRecord(raw) ? raw : {}).flatMap(([name, schemeOrRef]) => {
    const scheme = resolver.resolve<Record<string, unknown>>(schemeOrRef)
    if (!isRecord(scheme) || typeof scheme.type !== "string" || !TYPES.has(scheme.type)) return []
    const type = scheme.type as SecurityScheme["type"]
    return [
      {
        name,
        type,
        ...(typeof scheme.scheme === "string" ? { scheme: scheme.scheme.toLowerCase() } : {}),
        ...(typeof scheme.in === "string" ? { in: scheme.in } : {}),
        ...(typeof scheme.name === "string" ? { paramName: scheme.name } : {}),
        ...(type === "oauth2" ? { flows: extractFlows(scheme.flows) } : {})
      }
    ]
  })

/**
 * Secret-header methods from security strategies (one requirement object =
 * schemes required together). OAuth2 strategies are handled separately; cookie
 * API keys are skipped (usually the vendor console's own session).
 */
const buildHeaderMethods = (schemes: readonly SecurityScheme[], strategies: ReadonlyArray<readonly string[]>): AuthMethod[] => {
  const byName = new Map(schemes.map((s) => [s.name, s]))
  return strategies.flatMap((strategy): AuthMethod[] => {
    const resolved = strategy.map((n) => byName.get(n)).filter((s): s is SecurityScheme => !!s)
    if (resolved.length === 0) return []
    const headers: string[] = []
    const query: string[] = []
    const labels: string[] = []
    let kind: AuthMethod["kind"] = "headers"
    for (const scheme of resolved) {
      if (scheme.type === "http" && scheme.scheme === "bearer") {
        headers.push("Authorization")
        labels.push("Bearer token")
        kind = "bearer"
      } else if (scheme.type === "http" && scheme.scheme === "basic") {
        headers.push("Authorization")
        labels.push("Basic auth")
        kind = "basic"
      } else if (scheme.type === "apiKey" && scheme.in === "header") {
        headers.push(scheme.paramName ?? scheme.name)
        labels.push(scheme.name)
        kind = "api_key"
      } else if (scheme.type === "apiKey" && scheme.in === "query") {
        query.push(scheme.paramName ?? scheme.name)
        labels.push(`${scheme.name} (query)`)
        kind = "api_key"
      } else if (scheme.type === "oauth2" || scheme.type === "openIdConnect") {
        return []
      }
    }
    if (headers.length === 0 && query.length === 0) return []
    // Several schemes required together are a custom header set, whatever their kinds.
    const finalKind: AuthMethod["kind"] = headers.length + query.length > 1 ? "headers" : kind
    return [{ kind: finalKind, label: labels.join(" + "), ...(headers.length ? { headers } : {}), ...(query.length ? { query } : {}) }]
  })
}

const buildOAuth2Methods = (schemes: readonly SecurityScheme[]): AuthMethod[] =>
  schemes.flatMap((scheme): AuthMethod[] => {
    if (scheme.type !== "oauth2" || !scheme.flows) return []
    const out: AuthMethod[] = []
    const ac = scheme.flows.authorizationCode
    if (ac) out.push({ kind: "oauth2", flow: "authorization_code", label: `OAuth2 · ${scheme.name}`, authorization_url: ac.authorizationUrl!, token_url: ac.tokenUrl, scopes: ac.scopes })
    const cc = scheme.flows.clientCredentials
    if (cc) out.push({ kind: "oauth2", flow: "client_credentials", label: `OAuth2 client credentials · ${scheme.name}`, token_url: cc.tokenUrl, scopes: cc.scopes })
    return out
  })

/** Every way the document says it can be authenticated; empty when it declares no security. */
export const authMethodsFromOpenApi = (doc: Record<string, unknown>, resolver: DocResolver): AuthMethod[] => {
  const components = isRecord(doc.components) ? doc.components : {}
  const schemes = extractSecuritySchemes(components.securitySchemes, resolver)
  const declared = (Array.isArray(doc.security) ? doc.security : []).filter(isRecord).map((entry) => Object.keys(entry))
  // Fall back to one strategy per scheme when the document declares schemes but no top-level security.
  const strategies = declared.length > 0 ? declared : schemes.map((s) => [s.name])
  return [...buildHeaderMethods(schemes, strategies), ...buildOAuth2Methods(schemes)]
}
