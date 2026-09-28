/**
 * Wire shape of `GET /api/dashboard/coderouter`. Shared by the route, the
 * server loader in `services/coderouter/dashboardOverview.ts`, and the SPA.
 * Imported as types only, so no server code reaches the client bundle.
 */
import type { ClaudeAccountDescription } from "@/services/coderouter/claudeUpstream";
import type { CoderouterTeamMetrics } from "@/services/coderouter/teamMetrics";
import type { CodeRouterAccountSummary } from "@/services/coderouter/types";
import type { TeamMachineUsage } from "@/services/coderouter/vmUsageContract";
import type { SubrouterAccount } from "@/services/subrouter/types";

/**
 * Every account the team routes through: the Claude upstream accounts stored
 * by the web app (Anthropic API key, Claude Code OAuth token, Bedrock), the
 * accounts `cr add` stores, and the shared accounts held by the hosted
 * subrouter (Codex and the CLI-added Claude accounts).
 */
export type ClaudeAccountsState =
  | { readonly kind: "ok"; readonly accounts: readonly ClaudeAccountDescription[] }
  | { readonly kind: "error" };

/** Accounts `cr add` stores: Codex and OpenCode Go sign-ins routed by coderouter. */
export type NativeAccountsState =
  | { readonly kind: "ok"; readonly accounts: readonly CodeRouterAccountSummary[] }
  | { readonly kind: "error" };

export type SharedAccountsState =
  | { readonly kind: "ok"; readonly accounts: readonly SubrouterAccount[] }
  | { readonly kind: "migrationPending" }
  | { readonly kind: "notConfigured" }
  | { readonly kind: "error" };

export type MachineUsage =
  | { readonly kind: "unavailable"; readonly periodDays: number }
  | {
      readonly kind: "ready";
      readonly periodDays: number;
      readonly machines: readonly TeamMachineUsage[];
    };

export type DashboardCoderouterTeam = {
  readonly id: string;
  readonly name: string;
  readonly use: boolean;
  readonly manageAccounts: boolean;
  readonly manageApiKeys: boolean;
  readonly personal: boolean;
};

/** A team the viewer can move a native account into. */
export type CoderouterTransferTeam = { readonly id: string; readonly name: string };

export type DashboardCoderouterResponse = {
  readonly selectedTeam: DashboardCoderouterTeam;
  readonly transferTeams: readonly CoderouterTransferTeam[];
  readonly viewerUserId: string;
  readonly metrics: CoderouterTeamMetrics;
  readonly machineUsage: MachineUsage;
  readonly claude: ClaudeAccountsState;
  readonly native: NativeAccountsState;
  readonly shared: SharedAccountsState;
};
