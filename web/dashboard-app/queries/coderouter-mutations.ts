import type { QueryClient, UseMutationOptions } from "@tanstack/react-query";
import { z } from "zod";
import { dashboardFetch, isDashboardApiError } from "../lib/api";
import {
  CODEROUTER_REQUEST_TIMEOUT_MS,
  coderouterApiKeysQueryKey,
  coderouterQueryRoot,
} from "./coderouter";

/**
 * Writes behind the coderouter accounts section. Each factory returns the
 * options for `useMutation`; a success invalidates the coderouter queries,
 * which replaces Next's `router.refresh()`. Exported as factories so tests can
 * drive them with a bare QueryClient.
 */

const anyBody = z.unknown();

/** A write whose body the screen never reads (204, `{ ok: true }`, echoes). */
async function send(url: string, init: RequestInit & { readonly json?: unknown }): Promise<void> {
  await dashboardFetch(url, anyBody, init);
}

/** DELETE where 404 means the row is already gone, which is what the viewer wanted. */
async function sendDelete(url: string, init: RequestInit = {}): Promise<void> {
  try {
    await send(url, { ...init, method: "DELETE" });
  } catch (error) {
    if (!isDashboardApiError(error, 404)) throw error;
  }
}

function teamHeader(teamId: string): Record<string, string> {
  return { "x-cmux-team-id": teamId };
}

function teamQuery(teamId: string): string {
  return `teamId=${encodeURIComponent(teamId)}`;
}

function timeout(): AbortSignal {
  return AbortSignal.timeout(CODEROUTER_REQUEST_TIMEOUT_MS);
}

/** Options for a write that refreshes `queryKey` (default: every coderouter query) on success. */
function coderouterWrite<Variables, Result = void>(
  queryClient: QueryClient,
  mutationFn: (variables: Variables) => Promise<Result>,
  queryKey: readonly unknown[] = coderouterQueryRoot,
): UseMutationOptions<Result, Error, Variables> {
  return {
    mutationFn,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey });
    },
  };
}

// API keys

const issuedApiKeySchema = z.object({
  id: z.string().min(1),
  key: z.string().min(1),
  keyPrefix: z.string(),
  label: z.string(),
  createdAt: z.string(),
});

export type IssuedCoderouterApiKey = z.output<typeof issuedApiKeySchema>;

export function createApiKeyMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(
    queryClient,
    (label: string) =>
      dashboardFetch("/api/coderouter/api-keys", issuedApiKeySchema, {
        method: "POST",
        headers: teamHeader(teamId),
        json: { label },
        signal: timeout(),
      }),
    coderouterApiKeysQueryKey(teamId),
  );
}

export function apiKeyCreateErrorKey(error: unknown): "teamAccessError" | "apiKeyCreateError" {
  return isDashboardApiError(error, 403) ? "teamAccessError" : "apiKeyCreateError";
}

export function revokeApiKeyMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(
    queryClient,
    (keyId: string) =>
      send(`/api/coderouter/api-keys/${encodeURIComponent(keyId)}`, {
        method: "DELETE",
        headers: teamHeader(teamId),
        signal: timeout(),
      }),
    coderouterApiKeysQueryKey(teamId),
  );
}

// Accounts

export type AccountSharingVariables = {
  readonly accountId: string;
  readonly family: "native" | "claude";
  /** The visibility to switch to. */
  readonly visibility: "private" | "team";
};

export function accountSharingMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(queryClient, ({ accountId, family, visibility }: AccountSharingVariables) =>
    send(`/api/coderouter/accounts/${encodeURIComponent(accountId)}/sharing`, {
      method: "PATCH",
      headers: teamHeader(teamId),
      json: { family, visibility },
    }));
}

export function removeNativeAccountMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(queryClient, (accountId: string) =>
    sendDelete(`/api/coderouter/accounts/${encodeURIComponent(accountId)}`, { headers: teamHeader(teamId) }));
}

export type NativeAccountTransferVariables = {
  readonly accountId: string;
  readonly destinationTeamId: string;
};

/** Moves one native account from `teamId` to `destinationTeamId`. */
export function transferNativeAccountMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(queryClient, ({ accountId, destinationTeamId }: NativeAccountTransferVariables) =>
    send(`/api/coderouter/accounts/${encodeURIComponent(accountId)}/transfer`, {
      method: "POST",
      headers: teamHeader(teamId),
      json: { destinationTeamId },
      signal: timeout(),
    }));
}

const TRANSFER_ERROR_KEYS = {
  400: "validationError",
  403: "transferForbiddenError",
  404: "transferNotFoundError",
  409: "transferConflictError",
  503: "transferUnavailableError",
} as const;

export type TransferErrorKey =
  | "teamAccessError"
  | "transferError"
  | (typeof TRANSFER_ERROR_KEYS)[keyof typeof TRANSFER_ERROR_KEYS];

/** Message key for a failed transfer. The route answers 403 "forbidden" when
 * the viewer can no longer manage the source team, and 403
 * "destination_forbidden" when the destination refuses the account. */
export function transferErrorKey(status: number | null, error: string | null): TransferErrorKey {
  if (status === 403 && error === "forbidden") return "teamAccessError";
  const key = status === null ? undefined : TRANSFER_ERROR_KEYS[status as keyof typeof TRANSFER_ERROR_KEYS];
  return key ?? "transferError";
}

/** `transferErrorKey` for a rejected transfer mutation; a network failure has no status. */
export function transferErrorKeyFor(error: unknown): TransferErrorKey {
  if (!isDashboardApiError(error) || error.status === 0) return transferErrorKey(null, null);
  return transferErrorKey(error.status, error.code);
}

export type ClaudeAccountVariables =
  | { readonly accountId: string; readonly action: "setState"; readonly state: "active" | "disabled" }
  | { readonly accountId: string; readonly action: "remove" };

/** Enables, disables, or removes a Claude upstream account. The route reads the team from `?teamId=`. */
export function claudeAccountMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(queryClient, (variables: ClaudeAccountVariables) => {
    const url = `/api/coderouter/claude-upstream/${encodeURIComponent(variables.accountId)}?${teamQuery(teamId)}`;
    return variables.action === "remove"
      ? sendDelete(url)
      : send(url, { method: "PATCH", json: { state: variables.state } });
  });
}

/** Removes an account held by the hosted subrouter. 404 is a failure here: the subrouter owns the list. */
export function removeSharedAccountMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(queryClient, (accountId: string) =>
    send(`/api/subrouter/accounts/${encodeURIComponent(accountId)}?${teamQuery(teamId)}`, { method: "DELETE" }));
}

export type ApiKeyAccountVariables = {
  readonly provider: "openai-apikey" | "openrouter-apikey";
  readonly apiKey: string;
  readonly label: string;
};

export function addApiKeyAccountMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(queryClient, ({ provider, apiKey, label }: ApiKeyAccountVariables) =>
    send("/api/coderouter/accounts", {
      method: "POST",
      headers: teamHeader(teamId),
      json: { provider, apiKey, ...(label ? { label } : {}) },
    }));
}

/** The add-account body for one Claude upstream kind (`kind` plus that kind's credential fields). */
export type ClaudeUpstreamBody = Readonly<Record<string, string>>;

export function addClaudeUpstreamMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(queryClient, (body: ClaudeUpstreamBody) =>
    send(`/api/coderouter/claude-upstream?${teamQuery(teamId)}`, { method: "POST", json: body }));
}

/**
 * Message key for a failed account write: 400 and 403 have their own copy,
 * 503 uses `unavailable`, and anything else (network included) `fallback`.
 */
export function accountWriteErrorKey<Fallback extends string, Unavailable extends string = Fallback>(
  error: unknown,
  fallback: Fallback,
  unavailable?: Unavailable,
): "validationError" | "teamAccessError" | Fallback | Unavailable {
  const status = isDashboardApiError(error) ? error.status : 0;
  if (status === 400) return "validationError";
  if (status === 403) return "teamAccessError";
  if (status === 503) return unavailable ?? fallback;
  return fallback;
}
