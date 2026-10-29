import { createRoute, lazyRouteComponent, notFound } from "@tanstack/react-router";
import { z } from "zod";
import { DashboardSectionSkeleton, DashboardSkeleton } from "../components/dashboard-skeleton";
import { isRefusal } from "../lib/refusal";
import type { DashboardSessionResponse } from "../lib/session-types";
import {
  normalizeCliUserCode,
  vaultCliAuthClientQuery,
  vaultSessionQuery,
  vaultSessionsQuery,
  vaultSummaryQuery,
  vaultTranscriptHeadQuery,
} from "../queries/vault";
import { VaultOverviewFrame, VaultOverviewRouteError } from "../screens/vault/vault-frame";
import { shellRoute } from "./root";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Vault is release-gated: with the flag off its pages do not exist. */
function requireVault({ context }: { context: { session: DashboardSessionResponse } }) {
  if (!context.session.flags.vaultEnabled) throw notFound();
}

/** A 404 from the API is a missing page, not a crashed one. */
function notFoundOn404(error: unknown): never {
  if (isRefusal(error, 404)) throw notFound();
  throw error;
}

const vaultRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/vault",
  beforeLoad: requireVault,
  loader: ({ context }) =>
    context.queryClient.ensureQueryData(vaultSummaryQuery).catch(notFoundOn404),
  pendingComponent: () => (
    <VaultOverviewFrame>
      <DashboardSectionSkeleton variant="table" columns={4} rows={1} />
    </VaultOverviewFrame>
  ),
  errorComponent: VaultOverviewRouteError,
  component: lazyRouteComponent(() => import("../screens/vault/vault-overview"), "VaultOverview"),
});

const sessionsSearch = z.object({
  q: z.string().optional(),
  cursor: z.string().optional(),
  before: z.string().optional(),
});

export const vaultSessionsRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/vault/sessions",
  validateSearch: sessionsSearch,
  beforeLoad: requireVault,
  // Only the first visit waits on the list: the screen owns later filter
  // changes so typing never suspends the search box.
  pendingComponent: () => <DashboardSkeleton variant="table" columns={4} />,
  loader: ({ context, location }) => {
    const search = sessionsSearch.parse(location.search);
    return context.queryClient
      .ensureInfiniteQueryData(vaultSessionsQuery({
        q: search.q?.trim() ?? "",
        cursor: search.cursor ?? search.before ?? null,
      }))
      .catch(notFoundOn404);
  },
  component: lazyRouteComponent(() => import("../screens/vault/sessions-screen"), "VaultSessionsScreen"),
});

export const vaultSessionRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/vault/sessions/$id",
  beforeLoad: (options) => {
    requireVault(options);
    if (!UUID_RE.test(options.params.id)) throw notFound();
  },
  loader: async ({ context, params }) => {
    // The transcript head streams in behind the metadata.
    void context.queryClient.prefetchQuery(vaultTranscriptHeadQuery(params.id));
    await context.queryClient.ensureQueryData(vaultSessionQuery(params.id)).catch(notFoundOn404);
  },
  component: lazyRouteComponent(() => import("../screens/vault/session-screen"), "VaultSessionScreen"),
});

/**
 * Device-flow approval for `cmux-vault` and CodeRouter CLIs. CodeRouter
 * depends on it, so it is not gated by the Vault release flag.
 */
export const vaultCliAuthRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/vault/cli-auth",
  validateSearch: z.object({ code: z.string().optional() }),
  loaderDeps: ({ search }) => ({ code: normalizeCliUserCode(search.code) }),
  loader: async ({ context, deps }) => {
    if (deps.code) await context.queryClient.ensureQueryData(vaultCliAuthClientQuery(deps.code));
  },
  component: lazyRouteComponent(() => import("../screens/vault/cli-auth-screen"), "VaultCliAuthScreen"),
});

export const vaultRoutes = [vaultRoute, vaultSessionsRoute, vaultSessionRoute, vaultCliAuthRoute] as const;
