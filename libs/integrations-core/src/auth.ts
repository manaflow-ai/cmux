// Credential kinds of generic connections. cmux code (no upstream code).
//
// A connection records only the kind (`auth {kind}`). The host collects the
// secret in its own secure sheet, the gateway seals it and returns an opaque
// `cred_…` handle bound to (user, app id, host pattern); only the gateway
// resolves a handle. Nothing here holds a secret.

import type { AuthMethod, CatalogKind } from "./types.ts"

/**
 * `oauth2_code` is the authorization code flow with PKCE (and dynamic client
 * registration for MCP servers that support it); `oauth2_client_credentials`
 * is the client credentials flow.
 */
export type CredentialKind = "none" | "api_key" | "bearer" | "basic" | "headers" | "oauth2_code" | "oauth2_client_credentials"

export const CREDENTIAL_KINDS: ReadonlyArray<CredentialKind> = ["none", "api_key", "bearer", "basic", "headers", "oauth2_code", "oauth2_client_credentials"]

export const credentialKindOf = (m: AuthMethod): CredentialKind => (m.kind === "oauth2" ? (m.flow === "client_credentials" ? "oauth2_client_credentials" : "oauth2_code") : m.kind)

export interface AuthChoice {
  readonly kind: CredentialKind
  /** From the document: where the secret goes (header or query names, OAuth URLs and scopes). Absent for a kind the user picks by hand. */
  readonly method?: AuthMethod
  /** OAuth2 authorization code: the gateway registers a client dynamically (MCP servers). */
  readonly dynamic_registration?: boolean
}

const GENERIC_KINDS: Record<CatalogKind, ReadonlyArray<CredentialKind>> = {
  openapi: ["bearer", "api_key", "basic", "headers", "oauth2_code", "oauth2_client_credentials", "none"],
  graphql: ["bearer", "api_key", "basic", "headers", "oauth2_code", "oauth2_client_credentials", "none"],
  // Remote MCP servers over Streamable HTTP: OAuth with PKCE and dynamic client registration, or a static token or header.
  mcp: ["oauth2_code", "bearer", "headers", "none"]
}

/**
 * The auth kinds an add flow offers: the methods the document declares first
 * (in document order), then every other kind this catalog kind supports.
 */
export const authChoices = (kind: CatalogKind, declared: ReadonlyArray<AuthMethod>): AuthChoice[] => {
  const out: AuthChoice[] = declared.map((m) => ({ kind: credentialKindOf(m), method: m, ...(kind === "mcp" && m.kind === "oauth2" ? { dynamic_registration: true } : {}) }))
  for (const k of GENERIC_KINDS[kind]) {
    if (out.some((c) => c.kind === k)) continue
    out.push({ kind: k, ...(kind === "mcp" && k === "oauth2_code" ? { dynamic_registration: true } : {}) })
  }
  return out
}
