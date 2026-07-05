import { randomBytes } from "node:crypto";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { CoderouterConfigurationError, CoderouterConnectError } from "./errors";
import { timingSafeEqualString } from "./keys";
import type { Family, SeedOauth } from "./types";

const ANTHROPIC_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const ANTHROPIC_REDIRECT_URI = "https://console.anthropic.com/oauth/code/callback";
const OPENAI_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const STATE_TTL_MS = 10 * 60 * 1000;
const encoder = new TextEncoder();

export type AnthropicStart = {
  readonly authorizeUrl: string;
  readonly state: string;
  readonly cookie: string;
};

export type OpenAIStart = {
  readonly deviceCode: string;
  readonly userCode: string;
  readonly verificationUri: string;
  readonly expiresIn?: number;
  readonly interval?: number;
};

export type OpenAIPollResult =
  | { readonly status: "pending" }
  | { readonly status: "complete"; readonly chain: ImportedOauthChain };

export type ImportedOauthChain = {
  readonly provider: Family;
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly idToken?: string;
  readonly accountId?: string;
  readonly email?: string;
  readonly expiresAt?: number;
};

export type CoderouterOAuthConnectShape = {
  readonly startAnthropic: () => Effect.Effect<AnthropicStart, CoderouterConfigurationError>;
  readonly completeAnthropic: (input: {
    readonly pastedCode: string;
    readonly stateCookie: string | null;
  }) => Effect.Effect<ImportedOauthChain, CoderouterConfigurationError | CoderouterConnectError>;
  readonly startOpenAI: () => Effect.Effect<OpenAIStart, CoderouterConnectError>;
  readonly pollOpenAI: (deviceCode: string) => Effect.Effect<OpenAIPollResult, CoderouterConnectError>;
};

export class CoderouterOAuthConnect extends Context.Tag("cmux/CoderouterOAuthConnect")<
  CoderouterOAuthConnect,
  CoderouterOAuthConnectShape
>() {}

export const CoderouterOAuthConnectLive = Layer.succeed(
  CoderouterOAuthConnect,
  makeCoderouterOAuthConnect(process.env, fetch),
);

export function makeCoderouterOAuthConnect(
  env: Record<string, string | undefined>,
  fetchFn: typeof fetch,
): CoderouterOAuthConnectShape {
  return {
    startAnthropic: () =>
      Effect.tryPromise({
        try: async () => {
          const secret = stateSigningSecret(env);
          const verifier = randomToken(48);
          const state = randomToken(32);
          const challenge = await pkceChallenge(verifier);
          const cookie = await signStateCookie({ state, verifier, exp: Date.now() + STATE_TTL_MS }, secret);
          const authorize = new URL("https://claude.ai/oauth/authorize");
          authorize.searchParams.set("code", "true");
          authorize.searchParams.set("client_id", ANTHROPIC_CLIENT_ID);
          authorize.searchParams.set("response_type", "code");
          authorize.searchParams.set("redirect_uri", ANTHROPIC_REDIRECT_URI);
          authorize.searchParams.set("scope", "org:create_api_key user:profile user:inference");
          authorize.searchParams.set("code_challenge", challenge);
          authorize.searchParams.set("code_challenge_method", "S256");
          authorize.searchParams.set("state", state);
          return { authorizeUrl: authorize.toString(), state, cookie };
        },
        catch: (cause) =>
          cause instanceof CoderouterConfigurationError
            ? cause
            : new CoderouterConfigurationError("startAnthropic", "Could not create OAuth state."),
      }),

    completeAnthropic: (input) =>
      Effect.tryPromise({
        try: async () => {
          const secret = stateSigningSecret(env);
          const parsed = splitPastedCode(input.pastedCode);
          const state = await verifyStateCookie(input.stateCookie, secret);
          if (!state || state.state !== parsed.state) {
            throw new CoderouterConnectError("invalid_state", "OAuth state did not match.");
          }
          const response = await fetchFn("https://platform.claude.com/v1/oauth/token", {
            method: "POST",
            headers: {
              "content-type": "application/json",
              "anthropic-beta": "oauth-2025-04-20",
            },
            body: JSON.stringify({
              grant_type: "authorization_code",
              code: parsed.code,
              state: parsed.state,
              client_id: ANTHROPIC_CLIENT_ID,
              redirect_uri: ANTHROPIC_REDIRECT_URI,
              code_verifier: state.verifier,
            }),
          });
          if (!response.ok) {
            throw new CoderouterConnectError("provider_rejected", "Provider rejected the pasted code.");
          }
          const token = await response.json();
          return anthropicChainFromToken(token);
        },
        catch: (cause) => {
          if (cause instanceof CoderouterConfigurationError || cause instanceof CoderouterConnectError) return cause;
          return new CoderouterConnectError("provider_rejected", "Provider token exchange failed.");
        },
      }),

    startOpenAI: () =>
      Effect.tryPromise({
        try: async () => {
          const response = await fetchFn("https://auth.openai.com/oauth/device/authorization", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              client_id: OPENAI_CLIENT_ID,
              scope: "openid profile email offline_access",
            }),
          });
          if (!response.ok) {
            throw new CoderouterConnectError("connect_unsupported", "Device flow is not available; use import instead.");
          }
          const body = await response.json();
          return openAIStartFromResponse(body);
        },
        catch: (cause) =>
          cause instanceof CoderouterConnectError
            ? cause
            : new CoderouterConnectError("connect_unsupported", "Device flow is not available; use import instead."),
      }),

    pollOpenAI: (deviceCode) =>
      Effect.tryPromise({
        try: async () => {
          const response = await fetchFn("https://auth.openai.com/oauth/token", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              grant_type: "urn:ietf:params:oauth:grant-type:device_code",
              device_code: deviceCode,
              client_id: OPENAI_CLIENT_ID,
            }),
          });
          const body = await response.json().catch(() => ({}));
          if (!response.ok) {
            const error = typeof body?.error === "string" ? body.error : "";
            if (error === "authorization_pending" || error === "slow_down") return { status: "pending" as const };
            throw new CoderouterConnectError("provider_rejected", "Provider rejected the device flow request.");
          }
          return { status: "complete" as const, chain: openAIChainFromToken(body) };
        },
        catch: (cause) =>
          cause instanceof CoderouterConnectError
            ? cause
            : new CoderouterConnectError("provider_rejected", "Device flow polling failed."),
      }),
  };
}

export function seedOauthFromImportedChain(credentialId: string, chain: ImportedOauthChain): SeedOauth {
  return {
    credentialId,
    provider: chain.provider,
    accessToken: chain.accessToken,
    refreshToken: chain.refreshToken,
    ...(chain.idToken ? { idToken: chain.idToken } : {}),
    ...(chain.accountId ? { accountId: chain.accountId } : {}),
    ...(chain.expiresAt ? { expiresAt: chain.expiresAt } : {}),
  };
}

function stateSigningSecret(env: Record<string, string | undefined>): string {
  const secret = env.CODEROUTER_KEY_SIGNING_SECRET?.trim();
  if (!secret) {
    throw new CoderouterConfigurationError("oauthState", "CODEROUTER_KEY_SIGNING_SECRET is not configured.");
  }
  return secret;
}

function randomToken(bytes: number): string {
  return randomBytes(bytes).toString("base64url");
}

async function pkceChallenge(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(verifier));
  return Buffer.from(digest).toString("base64url");
}

async function signStateCookie(payload: { state: string; verifier: string; exp: number }, secret: string): Promise<string> {
  const value = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const signature = await hmac(value, secret);
  return `${value}.${signature}`;
}

async function verifyStateCookie(cookie: string | null, secret: string): Promise<{ state: string; verifier: string } | null> {
  if (!cookie) return null;
  const [value, signature] = cookie.split(".");
  if (!value || !signature) return null;
  const expected = await hmac(value, secret);
  if (!timingSafeEqualString(signature, expected)) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object") return null;
  const record = parsed as Record<string, unknown>;
  if (typeof record.state !== "string" || typeof record.verifier !== "string" || typeof record.exp !== "number") {
    return null;
  }
  if (record.exp < Date.now()) return null;
  return { state: record.state, verifier: record.verifier };
}

async function hmac(input: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(input));
  return Buffer.from(signature).toString("base64url");
}

function splitPastedCode(value: string): { code: string; state: string } {
  const idx = value.indexOf("#");
  if (idx <= 0 || idx === value.length - 1) {
    throw new CoderouterConnectError("invalid_state", "Pasted code must include state.");
  }
  return { code: value.slice(0, idx), state: value.slice(idx + 1) };
}

function anthropicChainFromToken(value: unknown): ImportedOauthChain {
  const record = requireRecord(value);
  const accessToken = stringField(record, "access_token");
  const refreshToken = stringField(record, "refresh_token");
  const expiresIn = numberField(record, "expires_in");
  return {
    provider: "anthropic",
    accessToken,
    refreshToken,
    expiresAt: Date.now() + expiresIn * 1000,
  };
}

function openAIStartFromResponse(value: unknown): OpenAIStart {
  const record = requireRecord(value);
  return {
    deviceCode: stringField(record, "device_code"),
    userCode: stringField(record, "user_code"),
    verificationUri: stringField(record, "verification_uri"),
    expiresIn: optionalNumberField(record, "expires_in"),
    interval: optionalNumberField(record, "interval"),
  };
}

function openAIChainFromToken(value: unknown): ImportedOauthChain {
  const record = requireRecord(value);
  const accessToken = stringField(record, "access_token");
  const refreshToken = stringField(record, "refresh_token");
  const idToken = stringField(record, "id_token");
  const claims = jwtClaims(idToken);
  return {
    provider: "openai",
    accessToken,
    refreshToken,
    idToken,
    email: stringClaim(claims, "https://api.openai.com/profile", "email") ?? stringClaim(claims, "email"),
    accountId: stringClaim(claims, "https://api.openai.com/auth", "chatgpt_account_id"),
  };
}

function jwtClaims(jwt: string): Record<string, unknown> {
  const [, payload] = jwt.split(".");
  if (!payload) return {};
  try {
    const parsed = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    return parsed && typeof parsed === "object" ? parsed as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

function stringClaim(claims: Record<string, unknown>, key: string, nested?: string): string | undefined {
  const value = claims[key];
  if (!nested) return typeof value === "string" ? value : undefined;
  if (!value || typeof value !== "object") return undefined;
  const nestedValue = (value as Record<string, unknown>)[nested];
  return typeof nestedValue === "string" ? nestedValue : undefined;
}

function requireRecord(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new CoderouterConnectError("provider_rejected", "Provider returned an invalid response.");
  }
  return value as Record<string, unknown>;
}

function stringField(record: Record<string, unknown>, key: string): string {
  const value = record[key];
  if (typeof value !== "string" || !value) {
    throw new CoderouterConnectError("provider_rejected", `Provider response is missing ${key}.`);
  }
  return value;
}

function numberField(record: Record<string, unknown>, key: string): number {
  const value = record[key];
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new CoderouterConnectError("provider_rejected", `Provider response is missing ${key}.`);
  }
  return value;
}

function optionalNumberField(record: Record<string, unknown>, key: string): number | undefined {
  const value = record[key];
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}
