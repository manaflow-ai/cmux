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
import { addCoderouterBreadcrumb, reportCoderouterFailure } from "./observability";

const CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const OPENCODE_CLIENT_ID = "opencode-cli";
const REFRESH_SKEW_MS = 60_000;

export class CodeRouterRefreshBusy extends Error {
  readonly _tag = "CodeRouterRefreshBusy";
}

export class CodeRouterCredentialBroken extends Error {
  readonly _tag = "CodeRouterCredentialBroken";
}

export type FreshCredentialInput = {
  readonly teamId: string;
  readonly accountId: string;
  readonly expectedRevision: number;
  readonly force?: boolean;
  readonly known?: EncryptedCredential;
};

export type CredentialRefreshDependencies = {
  readonly read: typeof readCredential;
  readonly decrypt: typeof decryptCredential;
  readonly claim: typeof claimRefreshLease;
  readonly release: typeof releaseRefreshLease;
  readonly refresh: typeof refreshProviderCredential;
  readonly encrypt: typeof encryptCredential;
  readonly complete: typeof completeRefreshLease;
  readonly fail: typeof failRefreshLease;
  readonly isTerminal: typeof isTerminalRefreshError;
  readonly failureCode: typeof refreshFailureCode;
};

export function createCredentialRefresher(
  dependencies: CredentialRefreshDependencies,
): (input: FreshCredentialInput) => Promise<CodeRouterCredential> {
  return async (input) => {
  if (
    input.known &&
    input.expectedRevision > 0 &&
    input.known.credentialRevision !== input.expectedRevision
  ) {
    throw new CodeRouterRefreshBusy("credential revision changed");
  }
  let before;
  try {
    before = input.known
      ? {
        envelope: input.known,
        credential: await dependencies.decrypt(input.known),
      }
      :
      await dependencies.read(input.teamId, input.accountId);
  } catch (error) {
    reportCoderouterFailure("credential_decrypt", error);
    throw error;
  }
  if (!input.force && before.credential.expiresAt > Date.now() + REFRESH_SKEW_MS) {
    return before.credential;
  }

  const leaseId = await dependencies.claim(input.accountId);
  if (!leaseId) {
    addCoderouterBreadcrumb("refresh", "Credential refresh already in progress", {
      provider: currentProvider(before.credential),
    }, "warning");
    throw new CodeRouterRefreshBusy("credential refresh already in progress");
  }
  addCoderouterBreadcrumb("refresh", "Credential refresh lease acquired", {
    provider: currentProvider(before.credential),
    forced: input.force === true,
  });
  try {
    // The lease winner must re-read after claiming. Another request may have
    // refreshed and rotated the token immediately before this lease.
    const current = await dependencies.read(input.teamId, input.accountId);
    if (
      !input.force &&
      current.credential.expiresAt > Date.now() + REFRESH_SKEW_MS
    ) {
      await dependencies.release(input.accountId, leaseId);
      return current.credential;
    }

    const refreshed = await dependencies.refresh(current.credential);
    const encrypted = await dependencies.encrypt({
      teamId: input.teamId,
      accountId: input.accountId,
      provider: refreshed.provider,
      credentialRevision: current.envelope.credentialRevision + 1,
      credential: refreshed,
    });
    await dependencies.complete({
      accountId: input.accountId,
      leaseId,
      expectedRevision: current.envelope.credentialRevision,
      credential: refreshed,
      encrypted,
    });
    addCoderouterBreadcrumb("refresh", "Credential refresh completed", {
      provider: refreshed.provider,
    });
    return refreshed;
  } catch (error) {
    const terminal = dependencies.isTerminal(error);
    reportCoderouterFailure("provider_refresh", error, {
      provider: currentProvider(before.credential),
      terminal,
    });
    await dependencies.fail(
      input.accountId,
      leaseId,
      terminal,
      dependencies.failureCode(error),
    ).catch(() => undefined);
    if (terminal) {
      throw new CodeRouterCredentialBroken("provider refresh token is no longer usable");
    }
    throw error;
  }
  };
}

function currentProvider(credential: CodeRouterCredential): string {
  return credential.provider;
}

export const freshCredential = createCredentialRefresher({
  read: readCredential,
  decrypt: decryptCredential,
  claim: claimRefreshLease,
  release: releaseRefreshLease,
  refresh: refreshProviderCredential,
  encrypt: encryptCredential,
  complete: completeRefreshLease,
  fail: failRefreshLease,
  isTerminal: isTerminalRefreshError,
  failureCode: refreshFailureCode,
});

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

export async function refreshProviderCredential(
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
    signal: AbortSignal.timeout(10_000),
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
    signal: AbortSignal.timeout(10_000),
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

export function isTerminalRefreshError(error: unknown): boolean {
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
