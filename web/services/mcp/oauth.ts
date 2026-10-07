// OAuth 2.1 authorization server for the cmux Cloud MCP server (`/api/mcp`).
//
// ChatGPT, Codex, Claude and other MCP hosts connect as public clients with
// PKCE (S256). A client identifies itself with a Client ID Metadata Document
// (an HTTPS URL as `client_id`, ChatGPT's preferred path) or registers through
// dynamic client registration. The user signs in with their cmux (Stack)
// account, picks the team whose plan pays for the machines, and approves the
// scopes. Tokens are opaque, stored only as SHA-256 digests, bound to the MCP
// resource, and accepted only by `/api/mcp`: `/api/vm` never sees them.
//
// This module holds the protocol rules. Persistence is behind `McpOauthStore`
// so the rules are tested without a database.

import { createHash, randomBytes } from "node:crypto";

export const MCP_RESOURCE_PATH = "/api/mcp";
export const MCP_AUTHORIZE_PATH = "/authorize/mcp";
export const MCP_TOKEN_PATH = "/api/oauth/token";
export const MCP_REGISTER_PATH = "/api/oauth/register";
export const MCP_REVOKE_PATH = "/api/oauth/revoke";
export const MCP_PROTECTED_RESOURCE_METADATA_PATH = "/.well-known/oauth-protected-resource";

export const MCP_SCOPES = [
  "machines:read",
  "machines:write",
  "terminals:read",
  "terminals:write",
  "agents:run",
] as const;
export type McpScope = (typeof MCP_SCOPES)[number];

export const ACCESS_TOKEN_TTL_MS = 60 * 60 * 1000;
export const REFRESH_TOKEN_TTL_MS = 60 * 24 * 60 * 60 * 1000;
export const AUTHORIZATION_CODE_TTL_MS = 5 * 60 * 1000;

const ACCESS_TOKEN_PREFIX = "cmux_mcp_at_";
const REFRESH_TOKEN_PREFIX = "cmux_mcp_rt_";
const CODE_PREFIX = "cmux_mcp_code_";
const DCR_CLIENT_PREFIX = "cmux_mcp_client_";
const MAX_REDIRECT_URIS = 8;
const MAX_URL_LENGTH = 2048;
const MAX_STATE_LENGTH = 2048;
const PKCE_CHALLENGE_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const PKCE_VERIFIER_PATTERN = /^[A-Za-z0-9._~-]{43,128}$/;

/** Hosts whose Client ID Metadata Documents the server fetches. Others must use DCR. */
const DEFAULT_CIMD_HOSTS = ["chatgpt.com", "claude.ai"];

export type McpOauthClient = {
  readonly clientId: string;
  readonly clientName: string | null;
  readonly redirectUris: readonly string[];
};

export type McpOauthGrant = {
  readonly id: string;
  readonly clientId: string;
  readonly clientName: string | null;
  readonly stackUserId: string;
  readonly teamId: string | null;
  readonly scopes: readonly McpScope[];
  readonly revokedAt: Date | null;
};

export type McpOauthTokenKind = "code" | "access" | "refresh";

export type McpOauthTokenRecord = {
  readonly tokenHash: string;
  readonly grantId: string;
  readonly kind: McpOauthTokenKind;
  readonly redirectUri: string | null;
  readonly codeChallenge: string | null;
  readonly expiresAt: Date;
  readonly consumedAt: Date | null;
};

export type McpOauthStore = {
  readonly insertClient: (client: McpOauthClient) => Promise<void>;
  readonly findClient: (clientId: string) => Promise<McpOauthClient | null>;
  readonly insertGrant: (grant: Omit<McpOauthGrant, "id" | "revokedAt">) => Promise<McpOauthGrant>;
  readonly findGrant: (grantId: string) => Promise<McpOauthGrant | null>;
  readonly revokeGrant: (grantId: string, at: Date) => Promise<void>;
  readonly touchGrant: (grantId: string, at: Date) => Promise<void>;
  readonly readGrantSettings: (grantId: string) => Promise<Record<string, unknown>>;
  readonly writeGrantSettings: (grantId: string, settings: Record<string, unknown>) => Promise<void>;
  readonly insertToken: (token: Omit<McpOauthTokenRecord, "consumedAt">) => Promise<void>;
  readonly findToken: (tokenHash: string) => Promise<McpOauthTokenRecord | null>;
  /** Marks an unconsumed token consumed; false when it was already consumed (a replay). */
  readonly consumeToken: (tokenHash: string, at: Date) => Promise<boolean>;
};

/** An OAuth error response body (RFC 6749 §5.2). */
export class McpOauthError extends Error {
  constructor(
    readonly error: string,
    readonly description: string,
    readonly status = 400,
  ) {
    super(description);
  }
}

export function hashToken(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function randomToken(prefix: string): string {
  return `${prefix}${randomBytes(32).toString("base64url")}`;
}

export function isMcpAccessToken(value: string): boolean {
  return value.startsWith(ACCESS_TOKEN_PREFIX);
}

/** The issuer and resource identifiers for one public origin, e.g. `https://cmux.com`. */
export function mcpOauthUrls(origin: string) {
  const base = origin.replace(/\/+$/, "");
  return {
    issuer: base,
    resource: `${base}${MCP_RESOURCE_PATH}`,
    authorizationEndpoint: `${base}${MCP_AUTHORIZE_PATH}`,
    tokenEndpoint: `${base}${MCP_TOKEN_PATH}`,
    registrationEndpoint: `${base}${MCP_REGISTER_PATH}`,
    revocationEndpoint: `${base}${MCP_REVOKE_PATH}`,
    protectedResourceMetadata: `${base}${MCP_PROTECTED_RESOURCE_METADATA_PATH}${MCP_RESOURCE_PATH}`,
  };
}

export function authorizationServerMetadata(origin: string) {
  const urls = mcpOauthUrls(origin);
  return {
    issuer: urls.issuer,
    authorization_endpoint: urls.authorizationEndpoint,
    token_endpoint: urls.tokenEndpoint,
    registration_endpoint: urls.registrationEndpoint,
    revocation_endpoint: urls.revocationEndpoint,
    response_types_supported: ["code"],
    response_modes_supported: ["query"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    code_challenge_methods_supported: ["S256"],
    token_endpoint_auth_methods_supported: ["none"],
    revocation_endpoint_auth_methods_supported: ["none"],
    client_id_metadata_document_supported: true,
    authorization_response_iss_parameter_supported: true,
    scopes_supported: [...MCP_SCOPES],
    service_documentation: "https://cmux.com/docs/cloud",
  };
}

export function protectedResourceMetadata(origin: string) {
  const urls = mcpOauthUrls(origin);
  return {
    resource: urls.resource,
    authorization_servers: [urls.issuer],
    scopes_supported: [...MCP_SCOPES],
    bearer_methods_supported: ["header"],
    resource_name: "cmux Cloud",
    resource_documentation: "https://cmux.com/docs/cloud",
    resource_policy_uri: "https://cmux.com/privacy-policy",
    resource_tos_uri: "https://cmux.com/terms-of-service",
  };
}

/** `WWW-Authenticate` for a 401 from the MCP resource (RFC 9728 §5.1). */
export function bearerChallenge(
  origin: string,
  error?: "invalid_token" | "insufficient_scope",
  scope?: string,
  description?: string,
): string {
  const parts = [`resource_metadata="${mcpOauthUrls(origin).protectedResourceMetadata}"`];
  if (error) parts.push(`error="${error}"`);
  if (description) parts.push(`error_description="${description.replace(/["\\]/g, "")}"`);
  if (scope) parts.push(`scope="${scope}"`);
  return `Bearer ${parts.join(", ")}`;
}

export function parseScopes(raw: string | null | undefined): McpScope[] {
  if (!raw || !raw.trim()) return [...MCP_SCOPES];
  const requested = [...new Set(raw.trim().split(/\s+/))];
  const unknown = requested.filter((scope) => !(MCP_SCOPES as readonly string[]).includes(scope));
  if (unknown.length > 0) {
    throw new McpOauthError("invalid_scope", `Unknown scope: ${unknown.join(" ")}`);
  }
  return MCP_SCOPES.filter((scope) => requested.includes(scope));
}

function isLoopbackHost(hostname: string): boolean {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]";
}

/** Redirect URIs are HTTPS, or HTTP on loopback for local clients (RFC 8252 §7.3). No fragments. */
export function validRedirectUri(raw: unknown): raw is string {
  if (typeof raw !== "string" || raw.length > MAX_URL_LENGTH) return false;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return false;
  }
  if (url.hash || url.username || url.password) return false;
  if (url.protocol === "https:") return true;
  return url.protocol === "http:" && isLoopbackHost(url.hostname);
}

function cimdHosts(env: Record<string, string | undefined>): readonly string[] {
  const extra = (env.CMUX_MCP_OAUTH_CIMD_HOSTS ?? "").split(",").map((host) => host.trim().toLowerCase()).filter(Boolean);
  return [...DEFAULT_CIMD_HOSTS, ...extra];
}

/** Whether `clientId` is a metadata document URL this server will fetch. */
export function isCimdClientId(clientId: string, env: Record<string, string | undefined> = process.env): boolean {
  let url: URL;
  try {
    url = new URL(clientId);
  } catch {
    return false;
  }
  if (url.protocol !== "https:" || url.username || url.password || url.hash || url.port) return false;
  if (url.pathname === "/" || clientId.length > MAX_URL_LENGTH) return false;
  return cimdHosts(env).includes(url.hostname.toLowerCase());
}

export type CimdFetcher = (url: string) => Promise<unknown>;

const CIMD_CACHE_TTL_MS = 5 * 60 * 1000;
const cimdCache = new Map<string, { client: McpOauthClient; expiresAt: number }>();

/** Fetches a Client ID Metadata Document with a short deadline and a size cap. */
export const fetchCimdDocument: CimdFetcher = async (url) => {
  const response = await fetch(url, {
    headers: { accept: "application/json" },
    redirect: "error",
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new McpOauthError("invalid_client", `The client metadata document returned HTTP ${response.status}.`);
  const text = await response.text();
  if (text.length > 64 * 1024) throw new McpOauthError("invalid_client", "The client metadata document is too large.");
  return JSON.parse(text) as unknown;
};

export function clientFromCimdDocument(clientId: string, document: unknown): McpOauthClient {
  if (!document || typeof document !== "object") {
    throw new McpOauthError("invalid_client", "The client metadata document is not a JSON object.");
  }
  const record = document as Record<string, unknown>;
  if (record.client_id !== clientId) {
    throw new McpOauthError("invalid_client", "The client metadata document names a different client_id.");
  }
  const redirectUris = Array.isArray(record.redirect_uris) ? record.redirect_uris.filter(validRedirectUri) : [];
  if (redirectUris.length === 0) {
    throw new McpOauthError("invalid_client", "The client metadata document has no usable redirect_uris.");
  }
  return {
    clientId,
    clientName: typeof record.client_name === "string" ? record.client_name.slice(0, 120) : null,
    redirectUris,
  };
}

export async function resolveClient(
  store: McpOauthStore,
  clientId: string,
  options: { readonly fetchCimd?: CimdFetcher; readonly env?: Record<string, string | undefined>; readonly now?: number } = {},
): Promise<McpOauthClient> {
  const env = options.env ?? process.env;
  if (isCimdClientId(clientId, env)) {
    const now = options.now ?? Date.now();
    const cached = cimdCache.get(clientId);
    if (cached && cached.expiresAt > now) return cached.client;
    const client = clientFromCimdDocument(clientId, await (options.fetchCimd ?? fetchCimdDocument)(clientId));
    cimdCache.set(clientId, { client, expiresAt: now + CIMD_CACHE_TTL_MS });
    return client;
  }
  if (!clientId.startsWith(DCR_CLIENT_PREFIX)) {
    throw new McpOauthError("invalid_client", "Unknown client_id. Register the client or use a supported client metadata document.");
  }
  const client = await store.findClient(clientId);
  if (!client) throw new McpOauthError("invalid_client", "Unknown client_id.");
  return client;
}

export function clearCimdCacheForTests(): void {
  cimdCache.clear();
}

/** RFC 7591 registration for a public client. */
export async function registerClient(store: McpOauthStore, body: unknown): Promise<Record<string, unknown>> {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new McpOauthError("invalid_client_metadata", "Expected a JSON object.");
  }
  const record = body as Record<string, unknown>;
  const redirectUris = record.redirect_uris;
  if (!Array.isArray(redirectUris) || redirectUris.length === 0 || redirectUris.length > MAX_REDIRECT_URIS) {
    throw new McpOauthError("invalid_redirect_uri", `redirect_uris must list 1 to ${MAX_REDIRECT_URIS} URIs.`);
  }
  if (!redirectUris.every(validRedirectUri)) {
    throw new McpOauthError("invalid_redirect_uri", "Each redirect URI must be HTTPS, or HTTP on a loopback host, without a fragment.");
  }
  const authMethod = record.token_endpoint_auth_method ?? "none";
  if (authMethod !== "none") {
    throw new McpOauthError("invalid_client_metadata", "Only public clients (token_endpoint_auth_method none) are supported.");
  }
  const grantTypes = record.grant_types ?? ["authorization_code", "refresh_token"];
  if (!Array.isArray(grantTypes) || grantTypes.some((grant) => grant !== "authorization_code" && grant !== "refresh_token")) {
    throw new McpOauthError("invalid_client_metadata", "grant_types may contain only authorization_code and refresh_token.");
  }
  const clientName = typeof record.client_name === "string" ? record.client_name.trim().slice(0, 120) || null : null;
  const client: McpOauthClient = { clientId: randomToken(DCR_CLIENT_PREFIX), clientName, redirectUris };
  await store.insertClient(client);
  return {
    client_id: client.clientId,
    client_id_issued_at: Math.floor(Date.now() / 1000),
    client_name: clientName ?? undefined,
    redirect_uris: redirectUris,
    token_endpoint_auth_method: "none",
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
  };
}

export type AuthorizationRequest = {
  readonly client: McpOauthClient;
  readonly redirectUri: string;
  readonly state: string | null;
  readonly codeChallenge: string;
  readonly scopes: readonly McpScope[];
  readonly resource: string;
};

/**
 * Validates the authorization request. Errors before the redirect URI is known
 * to belong to the client are shown on the page (`redirectable: false`); later
 * errors go back to the client as `error` on the redirect URI.
 */
export async function validateAuthorizationRequest(
  store: McpOauthStore,
  params: URLSearchParams,
  origin: string,
  options: { readonly fetchCimd?: CimdFetcher; readonly env?: Record<string, string | undefined> } = {},
): Promise<{ ok: true; request: AuthorizationRequest } | { ok: false; redirectable: boolean; error: McpOauthError; redirectUri?: string; state?: string | null }> {
  const clientId = params.get("client_id");
  if (!clientId) return { ok: false, redirectable: false, error: new McpOauthError("invalid_request", "client_id is required.") };
  let client: McpOauthClient;
  try {
    client = await resolveClient(store, clientId, options);
  } catch (error) {
    const oauthError = error instanceof McpOauthError ? error : new McpOauthError("invalid_client", "The client metadata document could not be read.");
    return { ok: false, redirectable: false, error: oauthError };
  }
  const redirectUri = params.get("redirect_uri") ?? (client.redirectUris.length === 1 ? client.redirectUris[0] : null);
  if (!redirectUri || !client.redirectUris.includes(redirectUri)) {
    return { ok: false, redirectable: false, error: new McpOauthError("invalid_request", "redirect_uri is not registered for this client.") };
  }
  const state = params.get("state");
  const checked = checkAuthorizationParams(params, origin);
  if (!checked.ok) return { ok: false, redirectable: true, error: checked.error, redirectUri, state };
  return { ok: true, request: { client, redirectUri, state, ...checked.value } };
}

function checkAuthorizationParams(
  params: URLSearchParams,
  origin: string,
): { ok: true; value: { codeChallenge: string; scopes: McpScope[]; resource: string } } | { ok: false; error: McpOauthError } {
  const fail = (error: string, description: string) => ({ ok: false as const, error: new McpOauthError(error, description) });
  const state = params.get("state");
  if (state && state.length > MAX_STATE_LENGTH) return fail("invalid_request", "state is too long.");
  if (params.get("response_type") !== "code") return fail("unsupported_response_type", "response_type must be code.");
  const codeChallenge = params.get("code_challenge");
  if (params.get("code_challenge_method") !== "S256" || !codeChallenge || !PKCE_CHALLENGE_PATTERN.test(codeChallenge)) {
    return fail("invalid_request", "PKCE with code_challenge_method S256 is required.");
  }
  const expectedResource = mcpOauthUrls(origin).resource;
  const resource = params.get("resource") ?? expectedResource;
  if (resource !== expectedResource) return fail("invalid_target", `resource must be ${expectedResource}.`);
  try {
    return { ok: true, value: { codeChallenge, scopes: parseScopes(params.get("scope")), resource } };
  } catch (error) {
    return fail("invalid_scope", (error as Error).message);
  }
}

/** The redirect back to the client, with `iss` on every response (RFC 9207). */
export function authorizationRedirect(
  redirectUri: string,
  origin: string,
  values: Record<string, string | null | undefined>,
): string {
  const url = new URL(redirectUri);
  for (const [key, value] of Object.entries(values)) {
    if (value !== null && value !== undefined) url.searchParams.set(key, value);
  }
  url.searchParams.set("iss", mcpOauthUrls(origin).issuer);
  return url.toString();
}

/** Records the user's consent and returns a one-time authorization code. */
export async function issueAuthorizationCode(
  store: McpOauthStore,
  request: AuthorizationRequest,
  consent: { readonly stackUserId: string; readonly teamId: string | null; readonly scopes: readonly McpScope[] },
  now = new Date(),
): Promise<string> {
  const scopes = consent.scopes.filter((scope) => request.scopes.includes(scope));
  if (scopes.length === 0) throw new McpOauthError("access_denied", "No scopes were approved.");
  const grant = await store.insertGrant({
    clientId: request.client.clientId,
    clientName: request.client.clientName,
    stackUserId: consent.stackUserId,
    teamId: consent.teamId,
    scopes,
  });
  const code = randomToken(CODE_PREFIX);
  await store.insertToken({
    tokenHash: hashToken(code),
    grantId: grant.id,
    kind: "code",
    redirectUri: request.redirectUri,
    codeChallenge: request.codeChallenge,
    expiresAt: new Date(now.getTime() + AUTHORIZATION_CODE_TTL_MS),
  });
  return code;
}

function pkceChallengeFor(verifier: string): string {
  return createHash("sha256").update(verifier, "ascii").digest("base64url");
}

async function issueTokenPair(store: McpOauthStore, grant: McpOauthGrant, now: Date): Promise<Record<string, unknown>> {
  const accessToken = randomToken(ACCESS_TOKEN_PREFIX);
  const refreshToken = randomToken(REFRESH_TOKEN_PREFIX);
  await store.insertToken({
    tokenHash: hashToken(accessToken),
    grantId: grant.id,
    kind: "access",
    redirectUri: null,
    codeChallenge: null,
    expiresAt: new Date(now.getTime() + ACCESS_TOKEN_TTL_MS),
  });
  await store.insertToken({
    tokenHash: hashToken(refreshToken),
    grantId: grant.id,
    kind: "refresh",
    redirectUri: null,
    codeChallenge: null,
    expiresAt: new Date(now.getTime() + REFRESH_TOKEN_TTL_MS),
  });
  return {
    access_token: accessToken,
    token_type: "Bearer",
    expires_in: Math.floor(ACCESS_TOKEN_TTL_MS / 1000),
    refresh_token: refreshToken,
    scope: grant.scopes.join(" "),
  };
}

async function liveGrantFor(store: McpOauthStore, record: McpOauthTokenRecord, clientId: string): Promise<McpOauthGrant> {
  const grant = await store.findGrant(record.grantId);
  if (!grant || grant.revokedAt) throw new McpOauthError("invalid_grant", "The grant was revoked.");
  if (grant.clientId !== clientId) throw new McpOauthError("invalid_grant", "The grant belongs to a different client.");
  return grant;
}

async function exchangeAuthorizationCode(
  store: McpOauthStore,
  form: URLSearchParams,
  clientId: string,
  now: Date,
): Promise<Record<string, unknown>> {
  const code = form.get("code");
  const verifier = form.get("code_verifier");
  if (!code || !verifier) throw new McpOauthError("invalid_request", "code and code_verifier are required.");
  if (!PKCE_VERIFIER_PATTERN.test(verifier)) throw new McpOauthError("invalid_grant", "code_verifier is malformed.");
  const record = await store.findToken(hashToken(code));
  if (!record || record.kind !== "code" || record.expiresAt <= now) {
    throw new McpOauthError("invalid_grant", "The authorization code is invalid or expired.");
  }
  const grant = await liveGrantFor(store, record, clientId);
  if (record.consumedAt || !(await store.consumeToken(record.tokenHash, now))) {
    // A replayed code may mean it leaked: end everything issued from it.
    await store.revokeGrant(grant.id, now);
    throw new McpOauthError("invalid_grant", "The authorization code was already used.");
  }
  const redirectUri = form.get("redirect_uri");
  if (redirectUri !== null && redirectUri !== record.redirectUri) {
    throw new McpOauthError("invalid_grant", "redirect_uri does not match the authorization request.");
  }
  if (pkceChallengeFor(verifier) !== record.codeChallenge) {
    throw new McpOauthError("invalid_grant", "code_verifier does not match the code challenge.");
  }
  return issueTokenPair(store, grant, now);
}

async function exchangeRefreshToken(
  store: McpOauthStore,
  form: URLSearchParams,
  clientId: string,
  now: Date,
): Promise<Record<string, unknown>> {
  const refreshToken = form.get("refresh_token");
  if (!refreshToken) throw new McpOauthError("invalid_request", "refresh_token is required.");
  const record = await store.findToken(hashToken(refreshToken));
  if (!record || record.kind !== "refresh" || record.expiresAt <= now) {
    throw new McpOauthError("invalid_grant", "The refresh token is invalid or expired.");
  }
  const grant = await liveGrantFor(store, record, clientId);
  if (record.consumedAt || !(await store.consumeToken(record.tokenHash, now))) {
    await store.revokeGrant(grant.id, now);
    throw new McpOauthError("invalid_grant", "The refresh token was already used; the connection was revoked.");
  }
  const requested = form.get("scope");
  if (requested && parseScopes(requested).some((scope) => !grant.scopes.includes(scope))) {
    throw new McpOauthError("invalid_scope", "A refresh cannot add scopes.");
  }
  return issueTokenPair(store, grant, now);
}

/** The token endpoint: `authorization_code` and `refresh_token` grants for public clients. */
export async function exchangeToken(
  store: McpOauthStore,
  form: URLSearchParams,
  origin: string,
  now = new Date(),
): Promise<Record<string, unknown>> {
  if (form.get("client_secret") || form.get("client_assertion")) {
    throw new McpOauthError("invalid_client", "This server accepts only public clients (token_endpoint_auth_method none).", 401);
  }
  const clientId = form.get("client_id");
  if (!clientId) throw new McpOauthError("invalid_request", "client_id is required.");
  const resource = form.get("resource");
  if (resource !== null && resource !== mcpOauthUrls(origin).resource) {
    throw new McpOauthError("invalid_target", `resource must be ${mcpOauthUrls(origin).resource}.`);
  }
  const grantType = form.get("grant_type");
  if (grantType === "authorization_code") return exchangeAuthorizationCode(store, form, clientId, now);
  if (grantType === "refresh_token") return exchangeRefreshToken(store, form, clientId, now);
  throw new McpOauthError("unsupported_grant_type", "grant_type must be authorization_code or refresh_token.");
}

/** RFC 7009: revoking any token of a grant ends the grant. Unknown tokens are not an error. */
export async function revokeToken(store: McpOauthStore, form: URLSearchParams, now = new Date()): Promise<void> {
  const token = form.get("token");
  if (!token) throw new McpOauthError("invalid_request", "token is required.");
  const record = await store.findToken(hashToken(token));
  if (!record || record.kind === "code") return;
  const clientId = form.get("client_id");
  const grant = await store.findGrant(record.grantId);
  if (!grant || (clientId && grant.clientId !== clientId)) return;
  await store.revokeGrant(grant.id, now);
}

/** The grant behind a bearer access token, or null when the token is not live. */
export async function grantForAccessToken(store: McpOauthStore, accessToken: string, now = new Date()): Promise<McpOauthGrant | null> {
  if (!isMcpAccessToken(accessToken)) return null;
  const record = await store.findToken(hashToken(accessToken));
  if (!record || record.kind !== "access" || record.expiresAt <= now) return null;
  const grant = await store.findGrant(record.grantId);
  if (!grant || grant.revokedAt) return null;
  return grant;
}

export function oauthErrorResponse(error: McpOauthError): Response {
  return new Response(JSON.stringify({ error: error.error, error_description: error.description }), {
    status: error.status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

export function oauthJsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}
