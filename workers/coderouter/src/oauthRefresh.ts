import type { Family } from "./types";

export interface OAuthChain {
  accessToken: string;
  refreshToken: string;
  idToken?: string;
  accountId?: string;
  expiresAt?: number;
}

export interface RefreshResult extends OAuthChain {
  provider: Family;
}

export interface RefreshFailure {
  error: string;
  refreshTokenFailure: boolean;
}

export type FetchLike = (input: Request | string | URL, init?: RequestInit) => Promise<Response>;

export function buildRefreshRequest(provider: Family, refreshToken: string): Request {
  if (provider === "openai") {
    return new Request("https://auth.openai.com/oauth/token", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        client_id: "app_EMoamEEZ73f0CkXaXp7hrann",
        grant_type: "refresh_token",
        refresh_token: refreshToken,
      }),
    });
  }
  return new Request("https://platform.claude.com/v1/oauth/token", {
    method: "POST",
    headers: { "content-type": "application/json", "anthropic-beta": "oauth-2025-04-20" },
    body: JSON.stringify({
      client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
      grant_type: "refresh_token",
      refresh_token: refreshToken,
    }),
  });
}

export async function refreshOAuthChain(
  provider: Family,
  chain: OAuthChain,
  fetcher: FetchLike = fetch,
  now = Date.now(),
): Promise<{ ok: true; chain: RefreshResult } | { ok: false; failure: RefreshFailure }> {
  const request = buildRefreshRequest(provider, chain.refreshToken);
  const response = await fetcher(request);
  const text = await response.text();
  let payload: unknown = null;
  try {
    payload = text ? JSON.parse(text) : null;
  } catch {
    payload = null;
  }
  if (!response.ok) {
    return {
      ok: false,
      failure: {
        error: "refresh_failed",
        refreshTokenFailure: response.status === 400 || response.status === 401 ? mentionsRefreshToken(text) : false,
      },
    };
  }
  const parsed = provider === "openai" ? parseOpenAiRefresh(payload, chain) : parseAnthropicRefresh(payload, chain, now);
  if (!parsed.ok) return { ok: false, failure: { error: parsed.error, refreshTokenFailure: false } };
  return { ok: true, chain: { provider, ...parsed.chain } };
}

export function tokenExpiresSoon(provider: Family, chain: OAuthChain, now = Date.now()): boolean {
  const expiresAt = provider === "openai" ? jwtExpiryMs(chain.accessToken) : chain.expiresAt;
  if (typeof expiresAt !== "number") return true;
  return expiresAt - now <= 60_000;
}

function parseOpenAiRefresh(
  payload: unknown,
  previous: OAuthChain,
): { ok: true; chain: OAuthChain } | { ok: false; error: string } {
  const record = asRecord(payload);
  const accessToken = stringValue(record?.access_token);
  const refreshToken = stringValue(record?.refresh_token);
  const idToken = stringValue(record?.id_token);
  if (!accessToken || !refreshToken || !idToken) return { ok: false, error: "invalid_refresh_response" };
  return {
    ok: true,
    chain: { ...previous, accessToken, refreshToken, idToken, expiresAt: jwtExpiryMs(accessToken) ?? previous.expiresAt },
  };
}

function parseAnthropicRefresh(
  payload: unknown,
  previous: OAuthChain,
  now: number,
): { ok: true; chain: OAuthChain } | { ok: false; error: string } {
  const record = asRecord(payload);
  const accessToken = stringValue(record?.access_token);
  const expiresIn = numberValue(record?.expires_in);
  if (!accessToken || expiresIn === null) return { ok: false, error: "invalid_refresh_response" };
  return {
    ok: true,
    chain: {
      ...previous,
      accessToken,
      refreshToken: stringValue(record?.refresh_token) ?? previous.refreshToken,
      expiresAt: now + expiresIn * 1000,
    },
  };
}

function jwtExpiryMs(token: string): number | null {
  const [, payload] = token.split(".");
  if (!payload) return null;
  try {
    const json = JSON.parse(atob(payload.replaceAll("-", "+").replaceAll("_", "/")));
    return typeof json.exp === "number" ? json.exp * 1000 : null;
  } catch {
    return null;
  }
}

function mentionsRefreshToken(text: string): boolean {
  return /refresh[_ -]?token|invalid_grant/i.test(text);
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}
