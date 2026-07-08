import type { NextRequest } from "next/server";

const STACK_ACCESS_COOKIE_NAMES = ["hexclave-access", "stack-access"] as const;
const STACK_COOKIE_PREFIXES = ["__Host-", "__Secure-", ""] as const;
const STACK_USER_API_URL = "https://api.stack-auth.com/api/v1/users/me";
// The verify call sits on the sign-in page request path; fail closed quickly
// (render the sign-in form) instead of stalling the page on a slow Stack API.
const STACK_USER_VERIFY_TIMEOUT_MS = 3000;

type CookieStoreLike = {
  getAll: () => { name: string; value: string }[];
};

type DecodedAccessCookie = {
  refreshToken?: string;
  accessToken?: string;
};

type StackAccessTokenPayload = {
  is_anonymous?: boolean;
  exp?: number;
};

export type StackSessionVerifyFetch = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

export type StackSessionUser = { isRestricted?: boolean };

export async function verifyStackSessionUser(
  request: NextRequest,
  verifyFetch: StackSessionVerifyFetch = fetch,
): Promise<StackSessionUser | null> {
  try {
    const accessToken = extractStackAccessToken(request.cookies);
    if (!accessToken) return null;

    const payload = decodeAccessTokenPayload(accessToken);
    if (!payload) return null;
    if (payload.is_anonymous === true) return null;
    if (typeof payload.exp !== "number" || payload.exp <= Date.now() / 1000) return null;

    const projectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID?.trim();
    const publishableClientKey = process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY?.trim();
    if (!projectId || !publishableClientKey) return null;

    const response = await verifyFetch(STACK_USER_API_URL, {
      headers: {
        "x-stack-access-type": "client",
        "x-stack-project-id": projectId,
        "x-stack-publishable-client-key": publishableClientKey,
        "x-stack-access-token": accessToken,
      },
      signal: AbortSignal.timeout(STACK_USER_VERIFY_TIMEOUT_MS),
    });
    if (!response.ok) return null;

    const data: unknown = await response.json();
    if (!isRecord(data)) return null;
    if (data.is_anonymous === true || data.is_restricted === true) return null;

    return { isRestricted: false };
  } catch {
    return null;
  }
}

export function extractStackAccessToken(cookieStore: CookieStoreLike): string | null {
  const rawAccessCookie = findStackCookie(cookieStore, STACK_ACCESS_COOKIE_NAMES);
  return decodeAccessCookie(rawAccessCookie).accessToken ?? null;
}

export function decodeAccessTokenPayload(accessToken: string): StackAccessTokenPayload | null {
  const payload = accessToken.split(".")[1];
  if (!payload) return null;

  try {
    const json = atob(base64UrlToBase64(payload));
    const data: unknown = JSON.parse(json);
    if (!isRecord(data)) return null;

    return {
      is_anonymous: typeof data.is_anonymous === "boolean" ? data.is_anonymous : undefined,
      exp: typeof data.exp === "number" ? data.exp : undefined,
    };
  } catch {
    return null;
  }
}

function findStackCookie(
  cookieStore: CookieStoreLike,
  baseNames: readonly string[],
): string | undefined {
  const all = cookieStore.getAll();
  for (const baseName of baseNames) {
    for (const prefix of STACK_COOKIE_PREFIXES) {
      const withBranch = all.find(
        (cookie) => cookie.name.startsWith(`${prefix}${baseName}--`) && cookie.value,
      );
      if (withBranch) return withBranch.value;

      const exact = all.find((cookie) => cookie.name === `${prefix}${baseName}` && cookie.value);
      if (exact) return exact.value;
    }
  }
  return undefined;
}

function decodeAccessCookie(value: string | undefined): DecodedAccessCookie {
  const decoded = decodeCookieValue(value);
  if (!decoded) return {};
  if (!decoded.startsWith("[")) return { accessToken: decoded };

  try {
    const data: unknown = JSON.parse(decoded);
    if (Array.isArray(data) && typeof data[1] === "string") {
      return {
        refreshToken: typeof data[0] === "string" ? data[0] : undefined,
        accessToken: data[1],
      };
    }
  } catch {}

  return {};
}

function decodeCookieValue(value: string | undefined): string | undefined {
  if (!value) return undefined;
  if (!value.includes("%")) return value;

  try {
    return decodeURIComponent(value);
  } catch {
    return undefined;
  }
}

function base64UrlToBase64(value: string): string {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/");
  const paddingLength = (4 - (base64.length % 4)) % 4;
  return `${base64}${"=".repeat(paddingLength)}`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
