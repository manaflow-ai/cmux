import { coderouterControlRoute, spanned } from "@/services/coderouter/requestTelemetry";
// Which coding agents the caller's team can run through CodeRouter: the
// question a Cloud machine asks before it chooses, per launch, between the
// team's accounts and the user's own sign-in (images/devbox/agent-auth.sh).
// `false` means the team has no account the agent could use: for Codex and
// OpenCode exactly the case where their proxy refuses with "no account"; for
// Claude Code also a team whose accounts are all disabled, which the Claude
// proxy would only ever answer with a retryable "exhausted". Booleans only:
// no account names or counts. Every Cloud machine asks about once a minute
// before a launch, so each answer is a metadata read (nothing is decrypted).
//
// `gatewayFallback`: whether a machine whose agent was set to its own
// sign-in, and has no credential at all, uses the team's gateway instead of
// stopping at "Not logged in" (agent-auth.sh `gateway-fallback`). Off unless
// this deployment sets CMUX_GATEWAY_FALLBACK (Leo, 2026-11-10: off "until the
// founders turn billing on").
import { hasActiveClaudeAccount } from "../../../../services/coderouter/claudeUpstream";
import { hasConfiguredAccount } from "../../../../services/coderouter/repository";
import { RESPONSES_PROVIDERS } from "../../../../services/coderouter/types";
import { resolveCoderouterUsageTeam } from "../../../../services/coderouter/requestContext";
import { reportCoderouterFailure } from "../../../../services/coderouter/observability";

export type AgentAccessDependencies = {
  readonly resolveUsageTeam: typeof resolveCoderouterUsageTeam;
  readonly hasActiveClaude: typeof hasActiveClaudeAccount;
  readonly hasConfigured: typeof hasConfiguredAccount;
  /** The raw CMUX_GATEWAY_FALLBACK value; read by {@link gatewayFallbackEnabled}. */
  readonly gatewayFallbackEnv?: () => string | undefined;
};

export const GATEWAY_FALLBACK_ENV = "CMUX_GATEWAY_FALLBACK";

/** The gateway fallback switch: on only for an explicit 1, true, yes or on; off when unset. */
export function gatewayFallbackEnabled(raw: string | undefined): boolean {
  return ["1", "true", "yes", "on"].includes(raw?.trim().toLowerCase() ?? "");
}

const defaultDependencies: AgentAccessDependencies = {
  resolveUsageTeam: resolveCoderouterUsageTeam,
  hasActiveClaude: hasActiveClaudeAccount,
  hasConfigured: hasConfiguredAccount,
  gatewayFallbackEnv: () => process.env[GATEWAY_FALLBACK_ENV],
};

export function makeAgentAccessHandler(dependencies: AgentAccessDependencies = defaultDependencies) {
  return async function GET(request: Request): Promise<Response> {
    const resolved = await dependencies.resolveUsageTeam(request);
    if (!resolved.ok) return resolved.response;
    const { teamId, access } = resolved;
    try {
      const [claude, codex, opencode] = await spanned("rds", () => Promise.all([
        // The Claude proxy serves only active accounts.
        dependencies.hasActiveClaude(teamId, access),
        // The Codex and OpenCode proxies refuse only when no account of their
        // family exists (codexProxy teamHasCodexAccount, opencodeProxy
        // noUsableOpenCodeAccount).
        dependencies.hasConfigured({ teamId, provider: RESPONSES_PROVIDERS, access }),
        dependencies.hasConfigured({ teamId, provider: "opencode-go", access }),
      ]));
      return Response.json(
        {
          teamId,
          agents: { claude, codex, opencode },
          gatewayFallback: gatewayFallbackEnabled(dependencies.gatewayFallbackEnv?.()),
        },
        { headers: { "cache-control": "no-store" } },
      );
    } catch (error) {
      reportCoderouterFailure("rds", error, { operation: "agent_access" });
      return Response.json(
        { error: "unavailable", message: "coderouter could not check the team's accounts. Retry shortly.", retryable: true },
        { status: 503, headers: { "cache-control": "no-store", "retry-after": "5" } },
      );
    }
  };
}

export const GET = coderouterControlRoute("accounts", "/api/coderouter/agent-access", makeAgentAccessHandler());
