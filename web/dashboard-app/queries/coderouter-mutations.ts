import type { QueryClient, UseMutationOptions } from "@tanstack/react-query";
import { dashboardRefusal } from "../lib/refusal";
import { dashboardClient } from "../lib/rpc";
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

const withTimeout = { context: { timeoutMs: CODEROUTER_REQUEST_TIMEOUT_MS } } as const;

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

export type { IssuedCoderouterApiKey } from "@/orpc/server/dashboard/schemas/coderouter";

export function createApiKeyMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(
    queryClient,
    (label: string) => dashboardClient.coderouter.createApiKey({ teamId, label }, withTimeout),
    coderouterApiKeysQueryKey(teamId),
  );
}

export function apiKeyCreateErrorKey(error: unknown): "teamAccessError" | "apiKeyCreateError" {
  return dashboardRefusal(error)?.status === 403 ? "teamAccessError" : "apiKeyCreateError";
}

export function revokeApiKeyMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(
    queryClient,
    async (keyId: string) => {
      await dashboardClient.coderouter.revokeApiKey({ teamId, keyId }, withTimeout);
    },
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
  return coderouterWrite(queryClient, async ({ accountId, family, visibility }: AccountSharingVariables) => {
    await dashboardClient.coderouter.setAccountVisibility({ teamId, accountId, family, visibility });
  });
}

export function removeNativeAccountMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(queryClient, async (accountId: string) => {
    await dashboardClient.coderouter.removeNativeAccount({ teamId, accountId });
  });
}

export type NativeAccountTransferVariables = {
  readonly accountId: string;
  readonly destinationTeamId: string;
};

/** Moves one native account from `teamId` to `destinationTeamId`. */
export function transferNativeAccountMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(queryClient, async ({ accountId, destinationTeamId }: NativeAccountTransferVariables) => {
    await dashboardClient.coderouter.transferNativeAccount({ teamId, accountId, destinationTeamId }, withTimeout);
  });
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
  const refusal = dashboardRefusal(error);
  if (!refusal) return transferErrorKey(null, null);
  return transferErrorKey(refusal.status, refusal.reason);
}

export type ClaudeAccountVariables =
  | { readonly accountId: string; readonly action: "setState"; readonly state: "active" | "disabled" }
  | { readonly accountId: string; readonly action: "remove" };

/** Enables, disables, or removes a Claude upstream account. */
export function claudeAccountMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(queryClient, async (variables: ClaudeAccountVariables) => {
    if (variables.action === "remove") {
      await dashboardClient.coderouter.removeClaudeAccount({ teamId, accountId: variables.accountId });
    } else {
      await dashboardClient.coderouter.setClaudeAccountState({
        teamId,
        accountId: variables.accountId,
        state: variables.state,
      });
    }
  });
}

/** Removes an account held by the hosted subrouter. 404 is a failure here: the subrouter owns the list. */
export function removeSharedAccountMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(queryClient, async (accountId: string) => {
    await dashboardClient.coderouter.removeSharedAccount({ teamId, accountId });
  });
}

export type ApiKeyAccountVariables = {
  readonly provider: "openai-apikey" | "openrouter-apikey";
  readonly apiKey: string;
  readonly label: string;
};

export function addApiKeyAccountMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(queryClient, async ({ provider, apiKey, label }: ApiKeyAccountVariables) => {
    await dashboardClient.coderouter.addApiKeyAccount({ teamId, provider, apiKey, label });
  });
}

/** The add-account body for one Claude upstream kind (`kind` plus that kind's credential fields). */
export type ClaudeUpstreamBody = Readonly<Record<string, string>>;

export function addClaudeUpstreamMutation(queryClient: QueryClient, teamId: string) {
  return coderouterWrite(queryClient, async (body: ClaudeUpstreamBody) => {
    await dashboardClient.coderouter.addClaudeUpstream({ teamId, body });
  });
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
  const status = dashboardRefusal(error)?.status ?? 0;
  if (status === 400) return "validationError";
  if (status === 403) return "teamAccessError";
  if (status === 503) return unavailable ?? fallback;
  return fallback;
}
