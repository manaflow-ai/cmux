import { coderouterControlRoute, spanned } from "@/services/coderouter/requestTelemetry";
// Which coding agents the caller's team can run through CodeRouter: the
// question a Cloud machine asks before it chooses, per launch, between the
// team's accounts and the user's own sign-in (images/devbox/agent-auth.sh).
// Each answer mirrors the proxy that would serve the agent, so `false` is
// exactly the case where that proxy refuses with "no account". Booleans only:
// no account names, counts, or identifiers.
import { listClaudeAccounts } from "../../../../services/coderouter/claudeUpstream";
import { hasConfiguredAccount } from "../../../../services/coderouter/repository";
import { RESPONSES_PROVIDERS } from "../../../../services/coderouter/types";
import { resolveCoderouterUsageTeam } from "../../../../services/coderouter/requestContext";
import { reportCoderouterFailure } from "../../../../services/coderouter/observability";

export type AgentAccessDependencies = {
  readonly resolveUsageTeam: typeof resolveCoderouterUsageTeam;
  readonly listClaude: typeof listClaudeAccounts;
  readonly hasConfigured: typeof hasConfiguredAccount;
};

const defaultDependencies: AgentAccessDependencies = {
  resolveUsageTeam: resolveCoderouterUsageTeam,
  listClaude: listClaudeAccounts,
  hasConfigured: hasConfiguredAccount,
};

export function makeAgentAccessHandler(dependencies: AgentAccessDependencies = defaultDependencies) {
  return async function GET(request: Request): Promise<Response> {
    const resolved = await dependencies.resolveUsageTeam(request);
    if (!resolved.ok) return resolved.response;
    const { teamId, access } = resolved;
    try {
      const [claude, codex, opencode] = await spanned("rds", () => Promise.all([
        // The Claude proxy serves only active accounts.
        dependencies.listClaude(teamId, access).then((accounts) => accounts.some((account) => account.state === "active")),
        // The Codex and OpenCode proxies refuse only when no account of their
        // family exists (codexProxy teamHasCodexAccount, opencodeProxy
        // noUsableOpenCodeAccount).
        dependencies.hasConfigured({ teamId, provider: RESPONSES_PROVIDERS, access }),
        dependencies.hasConfigured({ teamId, provider: "opencode-go", access }),
      ]));
      return Response.json(
        { teamId, agents: { claude, codex, opencode } },
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
