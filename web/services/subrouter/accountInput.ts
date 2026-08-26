import type { SubrouterAccountInput } from "./types";
import { readBoundedJsonRecord } from "./boundedJson";

const MAX_REQUEST_BYTES = 64 * 1024;
const MAX_LABEL_LENGTH = 120;

export async function readSubrouterAccountInput(
  request: Request,
): Promise<
  | { readonly ok: true; readonly value: SubrouterAccountInput }
  | { readonly ok: false; readonly status: number }
> {
  const parsed = await readBoundedJsonRecord(request, MAX_REQUEST_BYTES);
  if (!parsed.ok) return parsed;
  const value = validateAccountInput(parsed.value);
  return value
    ? { ok: true, value }
    : { ok: false, status: 400 };
}

function validateAccountInput(
  body: Record<string, unknown>,
): SubrouterAccountInput | null {
  const provider = body.provider;
  if (typeof provider !== "string") return null;
  const label = optionalLabel(body.label);
  if (label === false) return null;

  switch (provider) {
    case "claude": {
      const claudeAiOauth = body.claudeAiOauth;
      if (!isRecord(claudeAiOauth)) return null;
      if (
        !requiredString(claudeAiOauth.accessToken) ||
        !requiredString(claudeAiOauth.refreshToken)
      ) {
        return null;
      }
      const expiresAt = claudeAiOauth.expiresAt;
      if (
        typeof expiresAt !== "number" ||
        !Number.isFinite(expiresAt) ||
        expiresAt <= 0
      ) {
        return null;
      }
      return {
        provider,
        ...(label ? { label } : {}),
        claudeAiOauth: {
          accessToken: claudeAiOauth.accessToken.trim(),
          refreshToken: claudeAiOauth.refreshToken.trim(),
          expiresAt,
          ...optionalStringField(claudeAiOauth, "subscriptionType"),
          ...optionalStringField(claudeAiOauth, "rateLimitTier"),
        },
      };
    }
    case "anthropic-apikey": {
      const apiKey = trimmedString(body.apiKey);
      return apiKey.startsWith("sk-ant-")
        ? { provider, ...(label ? { label } : {}), apiKey }
        : null;
    }
    case "codex": {
      const tokens = body.tokens;
      if (!isRecord(tokens)) return null;
      if (
        !requiredString(tokens.accessToken) ||
        !requiredString(tokens.refreshToken) ||
        !requiredString(tokens.idToken) ||
        !requiredString(tokens.accountID)
      ) {
        return null;
      }
      return {
        provider,
        ...(label ? { label } : {}),
        tokens: {
          accessToken: tokens.accessToken.trim(),
          refreshToken: tokens.refreshToken.trim(),
          idToken: tokens.idToken.trim(),
          accountID: tokens.accountID.trim(),
        },
      };
    }
    case "openai-apikey": {
      const apiKey = trimmedString(body.apiKey);
      return apiKey.startsWith("sk-")
        ? { provider, ...(label ? { label } : {}), apiKey }
        : null;
    }
    default:
      return null;
  }
}

function optionalLabel(value: unknown): string | false | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") return false;
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  return trimmed.length <= MAX_LABEL_LENGTH ? trimmed : false;
}

function requiredString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function optionalStringField(
  record: Record<string, unknown>,
  key: string,
): Record<string, string> {
  const value = trimmedString(record[key]);
  return value ? { [key]: value } : {};
}

function trimmedString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
