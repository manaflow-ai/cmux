import { infiniteQueryOptions, queryOptions } from "@tanstack/react-query";
import { z } from "zod";
import type { VaultSummary } from "@/services/vault/summary";
import type {
  SerializedVaultSessionListPage,
  SerializedVaultSessionListRow,
} from "@/services/vault/sessionList";
import type { TranscriptMessage } from "@/services/vault/transcript";
import { dashboardFetch, isDashboardApiError } from "../lib/api";

/** Matches `VAULT_SESSION_LIST_PAGE_SIZE`; the service module imports Drizzle. */
export const VAULT_SESSIONS_PAGE_SIZE = 100;

const USER_CODE_RE = /^[A-Z2-9]{8}$/;

/** The CLI user code in canonical form, or `""` when it is not a valid code. */
export function normalizeCliUserCode(code: string | undefined): string {
  const normalized = code?.trim().toUpperCase() ?? "";
  return USER_CODE_RE.test(normalized) ? normalized : "";
}

const summarySchema = z.object({
  sessionCount: z.number(),
  rawBytes: z.number(),
  compressedBytes: z.number(),
  lastUploadedAt: z.string().nullable(),
  agents: z.array(z.object({ agent: z.string(), sessionCount: z.number() })),
}) satisfies z.ZodType<VaultSummary>;

export const vaultSummaryQuery = queryOptions({
  queryKey: ["vault", "summary"] as const,
  queryFn: ({ signal }) => dashboardFetch("/api/vault/summary", summarySchema, { signal }),
});

const sessionRowSchema = z.object({
  id: z.string(),
  agent: z.string(),
  agentSessionId: z.string(),
  relPath: z.string(),
  cwd: z.string().nullable(),
  latestSha256: z.string(),
  sizeBytes: z.number(),
  compressedSizeBytes: z.number().nullable(),
  snapshotCount: z.number(),
  firstUploadedAt: z.string(),
  lastUploadedAt: z.string(),
}) satisfies z.ZodType<SerializedVaultSessionListRow>;

const sessionPageSchema = z.object({
  sessions: z.array(sessionRowSchema),
  nextCursor: z.string().optional(),
}) satisfies z.ZodType<SerializedVaultSessionListPage>;

export type VaultSessionsFilter = {
  readonly q: string;
  /** First page cursor from a deep link (`?cursor=` or legacy `?before=`). */
  readonly cursor: string | null;
};

export function vaultSessionsQuery(filter: VaultSessionsFilter) {
  return infiniteQueryOptions({
    queryKey: ["vault", "sessions", filter.q, filter.cursor] as const,
    initialPageParam: filter.cursor,
    queryFn: ({ pageParam, signal }) => {
      const params = new URLSearchParams({ limit: String(VAULT_SESSIONS_PAGE_SIZE) });
      if (filter.q) params.set("q", filter.q);
      if (pageParam) params.set("cursor", pageParam);
      return dashboardFetch(`/api/vault/sessions?${params}`, sessionPageSchema, { signal });
    },
    getNextPageParam: (page): string | null => page.nextCursor ?? null,
  });
}

const snapshotSchema = z.object({
  sha256: z.string(),
  sizeBytes: z.number(),
  compressedSizeBytes: z.number().nullable(),
  uploadedAt: z.string(),
});

const sessionDetailSchema = z.object({
  id: z.string(),
  agent: z.string(),
  agentSessionId: z.string(),
  cwd: z.string().nullable(),
  sizeBytes: z.number(),
  compressedSizeBytes: z.number().nullable(),
  firstUploadedAt: z.string(),
  lastUploadedAt: z.string(),
  downloadUrl: z.string().nullable(),
  snapshots: z.array(snapshotSchema),
});

export type VaultSessionDetail = z.output<typeof sessionDetailSchema>;

export function vaultSessionQuery(id: string) {
  return queryOptions({
    queryKey: ["vault", "session", id] as const,
    queryFn: ({ signal }) =>
      dashboardFetch(`/api/vault/sessions/${encodeURIComponent(id)}`, sessionDetailSchema, { signal }),
  });
}

const transcriptHeadSchema = z.object({
  messages: z.array(z.object({ role: z.string(), text: z.string() })),
  complete: z.boolean(),
});

export type VaultTranscriptHead = {
  readonly messages: readonly TranscriptMessage[];
  readonly complete: boolean;
};

/**
 * The first parsed batch of the transcript. A failed head is not fatal: the
 * viewer then streams the whole transcript from `/content`.
 */
export function vaultTranscriptHeadQuery(id: string) {
  return queryOptions({
    queryKey: ["vault", "session", id, "head"] as const,
    queryFn: async ({ signal }): Promise<VaultTranscriptHead> => {
      try {
        return await dashboardFetch(
          `/api/vault/sessions/${encodeURIComponent(id)}/head`,
          transcriptHeadSchema,
          { signal },
        );
      } catch (error) {
        if (!isDashboardApiError(error)) throw error;
        return { messages: [], complete: false };
      }
    },
    // The transcript is append-only and the viewer streams the rest; a
    // refetch would reset the viewer's streamed messages.
    staleTime: Infinity,
  });
}

const cliAuthClientSchema = z.object({
  client: z.enum(["cmux-vault", "subrouter"]).nullable(),
});

/** Which client started the pending device flow for `code`. */
export function vaultCliAuthClientQuery(code: string) {
  return queryOptions({
    queryKey: ["vault", "cli-auth-client", code] as const,
    queryFn: ({ signal }) =>
      dashboardFetch(
        `/api/vault/cli/auth/client?${new URLSearchParams({ code })}`,
        cliAuthClientSchema,
        { signal },
      ),
  });
}

export const approveCliAuthResponseSchema = z.object({ ok: z.literal(true) });
