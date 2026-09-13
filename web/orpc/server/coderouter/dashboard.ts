import { z } from "zod";

import { getStackServerApp } from "../../../app/lib/stack";
import { authorizedSubrouterTeams } from "../../../services/subrouter/routeHelpers";
import { verifySubrouterRequest, withSubrouterAuthorizationDeadline } from "../../../services/vms/auth";
import { hostedSubrouterCutoverReadyForTeam } from "../../../services/subrouter/cutover";
import { createHostedSubrouterClient } from "../../../services/subrouter/hostedClient";
import { listClaudeAccounts } from "../../../services/coderouter/claudeUpstream";
import { listAccounts as listNativeAccounts } from "../../../services/coderouter/repository";
import { loadCoderouterTeamMetrics } from "../../../services/coderouter/teamMetrics";
import { loadMachineUsage } from "../../../app/[locale]/dashboard/coderouter/machine-usage";
import { coderouterOrganizationFromCookieHeader } from "../../../services/coderouter/organizationScope";
import { os, requireAuth } from "../base";

const accountArray = z.array(z.unknown());
const dashboardSchema = z.object({
  kind: z.enum(["authorized", "missing", "noTeams", "unavailable"]),
  team: z.object({ id: z.string(), name: z.string(), manageAccounts: z.boolean(), personal: z.boolean() }).nullable(),
  claude: accountArray,
  native: accountArray,
  shared: accountArray,
  sharedState: z.enum(["ok", "migrationPending", "notConfigured", "error"]),
  metrics: z.unknown().nullable(),
  machineUsage: z.unknown().nullable(),
});

export const coderouterDashboardProcedure = os
  .route({
    method: "GET",
    path: "/dashboard/coderouter",
    operationId: "dashboard.coderouter.overview",
    summary: "Get the authenticated CodeRouter dashboard",
    tags: ["Dashboard"],
    successStatus: 200,
  })
  .input(z.object({ team: z.string().optional() }))
  .output(dashboardSchema)
  .use(requireAuth)
  .handler(async ({ context, input }) => {
    try {
      const user = await withSubrouterAuthorizationDeadline(
        (signal) => verifySubrouterRequest(context.request, signal, { allowCookie: true, listAllTeams: true }),
      );
      if (!user) return emptyDashboard("missing");
      // The outer oRPC context and the team resolver must identify the same
      // Stack user. This closes mixed-cookie/bearer requests before any team
      // or hosted tenant data is loaded.
      if (user.id !== context.user.id) return emptyDashboard("missing");
      const teams = authorizedSubrouterTeams(user);
      if (teams.length === 0) return emptyDashboard("noTeams");
      const requested = input.team?.trim();
      const scoped = coderouterOrganizationFromCookieHeader(context.request.headers.get("cookie"), user.id);
      const selected = teams.find((team) => team.teamId === requested) ??
        teams.find((team) => team.teamId === scoped) ??
        teams.find((team) => team.teamId === user.selectedTeamId) ??
        teams.find((team) => team.personal) ?? teams[0];
      if (!selected) return emptyDashboard("noTeams");

      const authJson = await getStackServerApp().getAuthJson({ tokenStore: context.request as unknown as { headers: Headers } });
      const accessToken = authJson?.accessToken;
      if (!accessToken) return emptyDashboard("missing");

      const [claude, native, sharedResult, metrics, machineUsage] = await Promise.all([
        listClaudeAccounts(selected.teamId).then((accounts) => ({ kind: "ok" as const, accounts })).catch(() => ({ kind: "error" as const, accounts: [] })),
        listNativeAccounts(selected.teamId).then((accounts) => ({ kind: "ok" as const, accounts })).catch(() => ({ kind: "error" as const, accounts: [] })),
        loadSharedAccounts(selected, accessToken),
        loadCoderouterTeamMetrics(selected.teamId).catch(() => ({ kind: "unavailable" as const })),
        loadMachineUsage(selected.teamId),
      ]);
      return {
        kind: "authorized" as const,
        team: { id: selected.teamId, name: selected.teamName, manageAccounts: selected.manageAccounts, personal: selected.personal },
        claude: [...claude.accounts],
        native: [...native.accounts],
        shared: sharedResult.kind === "ok" ? [...sharedResult.accounts] : [],
        sharedState: sharedResult.kind,
        metrics,
        machineUsage,
      };
    } catch {
      return emptyDashboard("unavailable");
    }
  });

async function loadSharedAccounts(
  team: { teamId: string; teamName: string; use: boolean; manageAccounts: boolean },
  accessToken: string,
) {
  if (!await hostedSubrouterCutoverReadyForTeam(team.teamId)) return { kind: "migrationPending" as const, accounts: [] };
  const client = createHostedSubrouterClient();
  if (!client.tenantControlConfigured) return { kind: "notConfigured" as const, accounts: [] };
  try {
    const tenant = await client.exchangeTeam(accessToken, {
      teamId: team.teamId,
      teamName: team.teamName,
      use: team.use,
      manageAccounts: team.manageAccounts,
    });
    return { kind: "ok" as const, accounts: await client.listAccounts(tenant.tenantKey) };
  } catch {
    return { kind: "error" as const, accounts: [] };
  }
}

function emptyDashboard(kind: "missing" | "noTeams" | "unavailable") {
  return { kind, team: null, claude: [], native: [], shared: [], sharedState: "error" as const, metrics: null, machineUsage: null };
}
