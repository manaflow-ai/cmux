import { getStackServerApp } from "@/app/lib/stack";
import type {
  ClaudeAccountsState,
  DashboardCoderouterResponse,
  DashboardCoderouterTeam,
  MachineUsage,
  NativeAccountsState,
  SharedAccountsState,
} from "@/dashboard-app/lib/coderouter-types";
import { withStackAuthSpan } from "@/services/auth/stackTelemetry";
import { listClaudeAccounts } from "@/services/coderouter/claudeUpstream";
import { reportCoderouterFailure } from "@/services/coderouter/observability";
import { authorizedCoderouterTeams } from "@/services/coderouter/permissions";
import { listAccounts as listNativeAccounts } from "@/services/coderouter/repository";
import { listTeamMachines } from "@/services/coderouter/teamMachines";
import { loadCoderouterTeamMetrics } from "@/services/coderouter/teamMetrics";
import { loadCoderouterTeamMachineMetrics } from "@/services/coderouter/vmMetrics";
import { teamMachineUsage } from "@/services/coderouter/vmUsageContract";
import { hostedSubrouterCutoverReadyForTeam } from "@/services/subrouter/cutover";
import { createHostedSubrouterClient, HostedSubrouterError, HostedSubrouterUnreachableError } from "@/services/subrouter/hostedClient";
import type { SubrouterAccount } from "@/services/subrouter/types";
import { withPrioritySpan } from "@/services/telemetry";
import {
  isSubrouterAuthorizationError,
  SubrouterAuthorizationUnavailableError,
  verifySubrouterRequest,
  withSubrouterAuthorizationDeadline,
} from "@/services/vms/auth";

const SERVICE = "cmux-coderouter-dashboard";
const MACHINE_PERIOD_DAYS = 30;

export type CoderouterDashboardResult =
  | { readonly kind: "ok"; readonly body: DashboardCoderouterResponse }
  | { readonly kind: "missing" }
  | { readonly kind: "noTeams" }
  | { readonly kind: "unavailable" };

type CoderouterAuthorization = {
  readonly selectedTeam: DashboardCoderouterTeam;
  /** Every team the viewer can open here, the selected one included. */
  readonly teams: readonly DashboardCoderouterTeam[];
  readonly accessToken: string;
  readonly userId: string;
};

type CoderouterAuthorizationResult =
  | { readonly kind: "authorized"; readonly value: CoderouterAuthorization }
  | { readonly kind: "missing" }
  | { readonly kind: "noTeams" }
  | { readonly kind: "unavailable" };

/**
 * Everything the coderouter dashboard shows for one team. Team grants and the
 * Stack access token are resolved on every call, so a revoked membership stops
 * returning team data on the next request. The access token and the hosted
 * tenant key stay on the server; the response carries only display data.
 */
export async function loadCoderouterDashboard(
  request: Request,
  requestedTeamId: string | undefined,
): Promise<CoderouterDashboardResult> {
  const authorization = await withPrioritySpan(
    SERVICE,
    "cmux.coderouter.auth",
    { "http.route": "/api/dashboard/coderouter" },
    () => resolveCoderouterAuthorization(request, requestedTeamId),
  );
  if (authorization.kind !== "authorized") return authorization;

  const { selectedTeam, teams, accessToken, userId } = authorization.value;
  // The transfer route accepts only another team where the viewer manages
  // accounts, so the destination list uses the same rule.
  const transferTeams = teams
    .filter((candidate) => candidate.id !== selectedTeam.id && candidate.manageAccounts)
    .map((candidate) => ({ id: candidate.id, name: candidate.name }));
  const selected = { "cmux.team_scope": "selected" };
  const [shared, metrics, claude, native, machineUsage] = await Promise.all([
    withPrioritySpan(SERVICE, "cmux.coderouter.accounts", selected, () =>
      loadSharedAccounts(selectedTeam, accessToken)),
    withPrioritySpan(SERVICE, "cmux.coderouter.team_metrics", selected, () =>
      loadCoderouterTeamMetrics(selectedTeam.id)),
    withPrioritySpan(SERVICE, "cmux.coderouter.claude_upstream", selected, () =>
      loadClaudeAccounts(selectedTeam.id, userId)),
    withPrioritySpan(SERVICE, "cmux.coderouter.native_accounts", selected, () =>
      loadNativeAccounts(selectedTeam.id, userId)),
    withPrioritySpan(SERVICE, "cmux.coderouter.machine_usage", selected, () =>
      loadMachineUsage(selectedTeam.id)),
  ]);

  return {
    kind: "ok",
    body: {
      selectedTeam,
      transferTeams,
      viewerUserId: userId,
      metrics,
      machineUsage,
      claude,
      native,
      shared,
    },
  };
}

async function resolveCoderouterAuthorization(
  request: Request,
  requestedTeamId: string | undefined,
): Promise<CoderouterAuthorizationResult> {
  try {
    const authenticated = await withSubrouterAuthorizationDeadline(async (signal) => {
      const user = await verifySubrouterRequest(request, signal, {
        allowCookie: true,
        listAllTeams: true,
      });
      if (!user) return null;
      const [authorized, authJson] = await Promise.all([
        authorizedCoderouterTeams(user),
        withStackAuthSpan(
          "get_auth_json",
          () => getStackServerApp().getAuthJson({
            tokenStore: { headers: { get: (name: string) => request.headers.get(name) } },
          }),
          { "cmux.auth.flow": "coderouter_dashboard" },
        ).catch(() => {
          throw new SubrouterAuthorizationUnavailableError("Stack session refresh unavailable");
        }),
      ]);
      return { user, authorized, accessToken: authJson?.accessToken ?? null };
    });
    if (!authenticated) return { kind: "missing" };

    const teams = authenticated.authorized
      .filter((candidate) => candidate.use || candidate.manageAccounts)
      .map((candidate) => ({
        id: candidate.teamId,
        name: candidate.teamName,
        use: candidate.use,
        manageAccounts: candidate.manageAccounts,
        manageApiKeys: candidate.manageApiKeys,
        personal: candidate.personal,
      }));
    if (teams.length === 0) return { kind: "noTeams" };
    const accessToken = authenticated.accessToken;
    if (!accessToken) return { kind: "missing" };
    return {
      kind: "authorized",
      value: {
        selectedTeam: selectCoderouterTeam(teams, requestedTeamId, authenticated.user.selectedTeamId),
        teams,
        accessToken,
        userId: authenticated.user.id,
      },
    };
  } catch (error) {
    if (!isSubrouterAuthorizationError(error)) throw error;
    return { kind: "unavailable" };
  }
}

/**
 * An explicit `?team=` wins, then the Stack-selected team, then the personal
 * team, then the first authorized team.
 */
export function selectCoderouterTeam(
  teams: readonly DashboardCoderouterTeam[],
  requestedTeamId: string | undefined,
  selectedTeamId: string | null,
): DashboardCoderouterTeam {
  const requested = requestedTeamId?.trim();
  const byRequest = requested ? teams.find((team) => team.id === requested) : undefined;
  if (byRequest) return byRequest;
  const bySelection = selectedTeamId ? teams.find((team) => team.id === selectedTeamId) : undefined;
  if (bySelection) return bySelection;
  return teams.find((team) => team.personal) ?? teams[0];
}

async function loadSharedAccounts(
  team: DashboardCoderouterTeam,
  accessToken: string,
): Promise<SharedAccountsState> {
  try {
    if (!await hostedSubrouterCutoverReadyForTeam(team.id)) {
      return { kind: "migrationPending" };
    }
    const client = createHostedSubrouterClient();
    if (!client.tenantControlConfigured) return { kind: "notConfigured" };
    const tenant = await client.exchangeTeam(accessToken, {
      teamId: team.id,
      teamName: team.name,
      use: team.use,
      manageAccounts: team.manageAccounts,
    });
    const accounts = await client.listAccounts(tenant.tenantKey);
    return { kind: "ok", accounts: accounts.map(publicSharedAccount) };
  } catch (error) {
    console.error("coderouter shared accounts failed", failureFields(error));
    return sharedAccountsFailureState(error);
  }
}

/** An unreachable hosted service is its own state; any other failure is a load error. */
export function sharedAccountsFailureState(error: unknown): SharedAccountsState {
  return error instanceof HostedSubrouterUnreachableError ? { kind: "unavailable" } : { kind: "error" };
}

/** What a failed account source logs: the error class and HTTP status, never its message. */
function failureFields(error: unknown): { readonly errorType: string; readonly status?: number } {
  const errorType = error instanceof Error ? error.name : typeof error;
  return error instanceof HostedSubrouterError ? { errorType, status: error.status } : { errorType };
}

/** The hosted response may carry more than the row shows; forward only that. */
function publicSharedAccount(account: SubrouterAccount): SubrouterAccount {
  return {
    id: account.id,
    kind: account.kind,
    ...(account.label === undefined ? {} : { label: account.label }),
    ...(account.createdAt === undefined ? {} : { createdAt: account.createdAt }),
    ...(account.health === undefined
      ? {}
      : {
        health: {
          ok: account.health.ok,
          ...(account.health.message === undefined ? {} : { message: account.health.message }),
        },
      }),
  };
}

async function loadNativeAccounts(teamId: string, userId: string): Promise<NativeAccountsState> {
  try {
    return { kind: "ok", accounts: await listNativeAccounts(teamId, { kind: "user", userId }) };
  } catch (error) {
    console.error("coderouter native accounts failed", failureFields(error));
    return { kind: "error" };
  }
}

async function loadClaudeAccounts(teamId: string, userId: string): Promise<ClaudeAccountsState> {
  try {
    return { kind: "ok", accounts: await listClaudeAccounts(teamId, { kind: "user", userId }) };
  } catch (error) {
    console.error("coderouter claude accounts failed", failureFields(error));
    return { kind: "error" };
  }
}

/** The Machines card. Fails closed to "unavailable". */
export async function loadMachineUsage(teamId: string): Promise<MachineUsage> {
  let owned;
  try {
    owned = await listTeamMachines(teamId);
  } catch (error) {
    reportCoderouterFailure("rds", error, { operation: "list_team_machines" });
    return { kind: "unavailable", periodDays: MACHINE_PERIOD_DAYS };
  }
  const metrics = await loadCoderouterTeamMachineMetrics(teamId, "dashboard");
  if (metrics.kind === "unavailable") {
    return { kind: "unavailable", periodDays: MACHINE_PERIOD_DAYS };
  }
  return {
    kind: "ready",
    periodDays: metrics.periodDays,
    machines: teamMachineUsage(metrics, owned),
  };
}
