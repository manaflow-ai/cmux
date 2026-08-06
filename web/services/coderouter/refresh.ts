import {
  claimRefreshLease,
  completeRefreshLease,
  encryptedCredentialForAccount,
  failRefreshLease,
  releaseRefreshLease,
} from "./repository";
import {
  decryptCredential,
  encryptCredential,
  type EncryptedCredential,
} from "./encryption";
import type { CodeRouterCredential } from "./types";

const CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const OPENCODE_CLIENT_ID = "opencode-cli";
const REFRESH_SKEW_MS = 60_000;

export class CodeRouterRefreshBusy extends Error {
  readonly _tag = "CodeRouterRefreshBusy";
}

export class CodeRouterCredentialBroken extends Error {
  readonly _tag = "CodeRouterCredentialBroken";
}

export async function freshCredential(input: {
  readonly teamId: string;
  readonly accountId: string;
  readonly expectedRevision: number;
  readonly force?: boolean;
  readonly known?: EncryptedCredential;
}): Promise<CodeRouterCredential> {
  if (
    input.known &&
    input.expectedRevision > 0 &&
    input.known.credentialRevision !== input.expectedRevision
  ) {
    throw new CodeRouterRefreshBusy("credential revision changed");
  }
  const before = input.known
    ? {
      envelope: input.known,
      credential: await decryptCredential(input.known),
    }
    :
    await readCredential(input.teamId, input.accountId);
  if (!input.force && before.credential.expiresAt > Date.now() + REFRESH_SKEW_MS) {
    return before.credential;
  }

  const leaseId = await claimRefreshLease(input.accountId);
  if (!leaseId) throw new CodeRouterRefreshBusy("credential refresh already in progress");
  try {
    // The lease winner must re-read after claiming. Another request may have
    // refreshed and rotated the token immediately before this lease.
    const current = await readCredential(input.teamId, input.accountId);
    if (
      !input.force &&
      current.credential.expiresAt > Date.now() + REFRESH_SKEW_MS
    ) {
      await releaseRefreshLease(input.accountId, leaseId);
      return current.credential;
    }

    const refreshed = await refreshProviderCredential(current.credential);
    const encrypted = await encryptCredential({
      teamId: input.teamId,
      accountId: input.accountId,
      provider: refreshed.provider,
      credentialRevision: current.envelope.credentialRevision + 1,
      credential: refreshed,
    });
    await completeRefreshLease({
      accountId: input.accountId,
      leaseId,
      expectedRevision: current.envelope.credentialRevision,
      credential: refreshed,
      encrypted,
    });
    return refreshed;
  } catch (error) {
    const terminal = isTerminalRefreshError(error);
    await failRefreshLease(
      input.accountId,
      leaseId,
      terminal,
      refreshFailureCode(error),
    ).catch(() => undefined);
    if (terminal) {
      throw new CodeRouterCredentialBroken("provider refresh token is no longer usable");
    }
    throw error;
  }
}

async function readCredential(teamId: string, accountId: string) {
  const envelope = await encryptedCredentialForAccount(teamId, accountId);
  if (!envelope) {
    throw new CodeRouterCredentialBroken("encrypted credential not found");
  }
  return {
    envelope,
    credential: await decryptCredential(envelope),
  };
}

async function refreshProviderCredential(
  credential: CodeRouterCredential,
): Promise<CodeRouterCredential> {
  if (credential.provider === "codex") {
    const token = await postForm("https://auth.openai.com/oauth/token", {
      grant_type: "refresh_token",
      refresh_token: credential.refreshToken,
      client_id: CODEX_CLIENT_ID,
    });
    return {
      ...credential,
      accessToken: requiredString(token, "access_token"),
      refreshToken: optionalString(token, "refresh_token") ?? credential.refreshToken,
      idToken: optionalString(token, "id_token") ?? credential.idToken,
      expiresAt: Date.now() + optionalPositiveNumber(token, "expires_in", 3_600) * 1_000,
    };
  }

  const token = await postJson("https://console.opencode.ai/auth/device/token", {
    grant_type: "refresh_token",
    refresh_token: credential.refreshToken,
    client_id: OPENCODE_CLIENT_ID,
  });
  return {
    ...credential,
    accessToken: requiredString(token, "access_token"),
    refreshToken: optionalString(token, "refresh_token") ?? credential.refreshToken,
    expiresAt: Date.now() + optionalPositiveNumber(token, "expires_in", 3_600) * 1_000,
  };
}

class ProviderRefreshError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(`provider refresh failed: ${status} ${code}`);
  }
}

async function postForm(
  url: string,
  body: Record<string, string>,
): Promise<Record<string, unknown>> {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(body),
    cache: "no-store",
  });
  return await providerJson(response);
}

async function postJson(
  url: string,
  body: Record<string, string>,
): Promise<Record<string, unknown>> {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
    cache: "no-store",
  });
  return await providerJson(response);
}

async function providerJson(response: Response): Promise<Record<string, unknown>> {
  const value: unknown = await response.json().catch(() => ({}));
  const record = isRecord(value) ? value : {};
  if (!response.ok) {
    throw new ProviderRefreshError(
      response.status,
      optionalString(record, "code") ??
        providerErrorCode(record.error) ??
        "refresh_failed",
    );
  }
  return record;
}

function providerErrorCode(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (!isRecord(value)) return undefined;
  return optionalString(value, "code") ??
    optionalString(value, "type") ??
    optionalString(value, "error");
}

function isTerminalRefreshError(error: unknown): boolean {
  return error instanceof ProviderRefreshError &&
    (error.status === 400 || error.status === 401) &&
    /invalid|expired|reused|revoked|not_found/i.test(error.code);
}

function refreshFailureCode(error: unknown): string {
  return error instanceof ProviderRefreshError ? error.code : "refresh_unavailable";
}

function requiredString(record: Record<string, unknown>, key: string): string {
  const value = optionalString(record, key);
  if (!value) throw new Error(`provider response missing ${key}`);
  return value;
}

function optionalString(
  record: Record<string, unknown>,
  key: string,
): string | undefined {
  const value = record[key];
  return typeof value === "string" && value ? value : undefined;
}

function optionalPositiveNumber(
  record: Record<string, unknown>,
  key: string,
  fallback: number,
): number {
  const value = record[key];
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? value
    : fallback;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
