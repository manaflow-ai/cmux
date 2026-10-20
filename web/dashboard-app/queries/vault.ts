import { keepPreviousData, queryOptions } from "@tanstack/react-query";
import type { TranscriptMessage } from "@/services/vault/transcript";
import { isRefusal } from "../lib/refusal";
import { dashboardClient, rpc } from "../lib/rpc";

export { VAULT_SESSIONS_PAGE_SIZE } from "@/orpc/server/dashboard/vault-limits";

const USER_CODE_RE = /^[A-Z2-9]{8}$/;

/** The CLI user code in canonical form, or `""` when it is not a valid code. */
export function normalizeCliUserCode(code: string | undefined): string {
  const normalized = code?.trim().toUpperCase() ?? "";
  return USER_CODE_RE.test(normalized) ? normalized : "";
}

export const vaultSummaryQuery = rpc.vault.summary.queryOptions();

export type VaultSessionsFilter = {
  readonly q: string;
  /** First page cursor from a deep link (`?cursor=` or legacy `?before=`). */
  readonly cursor: string | null;
};

export function vaultSessionsQuery(filter: VaultSessionsFilter) {
  return rpc.vault.sessions.infiniteOptions({
    input: (cursor: string | null) => ({ q: filter.q, cursor }),
    initialPageParam: filter.cursor,
    getNextPageParam: (page): string | null => page.nextCursor ?? null,
    // A new search keeps the current rows on screen until its first page arrives.
    placeholderData: keepPreviousData,
  });
}

export type VaultSessionDetail = Awaited<ReturnType<typeof dashboardClient.vault.session>>;

export function vaultSessionQuery(id: string) {
  return rpc.vault.session.queryOptions({ input: { id } });
}

export type VaultTranscriptHead = {
  readonly messages: readonly TranscriptMessage[];
  readonly complete: boolean;
};

const EMPTY_HEAD: VaultTranscriptHead = { messages: [], complete: false };

/**
 * The first parsed batch of the transcript. A refused head is not fatal: the
 * viewer then streams the whole transcript from `/content`.
 */
export function vaultTranscriptHeadQuery(id: string) {
  return queryOptions({
    queryKey: rpc.vault.transcriptHead.queryKey({ input: { id } }),
    queryFn: async ({ signal }): Promise<VaultTranscriptHead> => {
      try {
        return await dashboardClient.vault.transcriptHead({ id }, { signal });
      } catch (error) {
        if (!isRefusal(error)) throw error;
        return EMPTY_HEAD;
      }
    },
    // The transcript is append-only and the viewer streams the rest; a
    // refetch would reset the viewer's streamed messages.
    staleTime: Infinity,
  });
}

/** Which client started the pending device flow for `code`. */
export function vaultCliAuthClientQuery(code: string) {
  return rpc.vault.cliAuthClient.queryOptions({ input: { code } });
}
