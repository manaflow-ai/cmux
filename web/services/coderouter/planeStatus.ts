// What a machine may ask about its own model plane: which agents will work
// right now, and how to fix the ones that will not. Route-token scoped, so it
// exposes nothing a machine cannot already infer by trying — counts and
// kinds, never identifiers or credentials. "Ready" means what placement
// means: an account is active and not cooling down this instant.
import { listAccounts, sweepExpiredRefreshLeases } from "./repository";
import { claimableAccounts } from "./opencodeProxy";
import { bearerToken } from "./codexProxy";
import { authenticateRouteToken } from "./repository";
import {
  CLAUDE_PLANE_PROVIDERS,
  CODEX_PLANE_PROVIDERS,
  type CodeRouterAccountSummary,
  type CodeRouterProvider,
} from "./types";

export const PLANE_AGENTS = ["claude", "codex", "pi", "opencode"] as const;
export type PlaneAgent = (typeof PLANE_AGENTS)[number];

export type AgentPlaneStatus = {
  /** A new session could be placed right now: an account of a usable kind is active and not cooling down. */
  readonly ready: boolean;
  /** Account kinds a session could be placed on right now. */
  readonly kinds: readonly CodeRouterProvider[];
  /** How many accounts a session could be placed on right now. */
  readonly accounts: number;
  /** Accounts mid-refresh: usable again in seconds, not claimable this instant. */
  readonly refreshing: number;
  /** The one-line fix on the user's Mac when not ready. */
  readonly connect: string;
};

export type PlaneStatus = {
  readonly agents: Readonly<Record<PlaneAgent, AgentPlaneStatus>>;
};

const CONNECT_HINTS: Readonly<Record<PlaneAgent, string>> = {
  claude: "cmux ai-accounts upload claude",
  codex: "cmux ai-accounts upload codex",
  pi: "cmux ai-accounts upload codex",
  opencode: "cmux ai-accounts upload claude",
};

/** Which account kinds each agent can route over (see agent-config.sh). */
const AGENT_KINDS: Readonly<Record<PlaneAgent, readonly CodeRouterProvider[]>> = {
  claude: CLAUDE_PLANE_PROVIDERS,
  codex: CODEX_PLANE_PROVIDERS,
  pi: CODEX_PLANE_PROVIDERS,
  opencode: [...CLAUDE_PLANE_PROVIDERS, ...CODEX_PLANE_PROVIDERS, "opencode-go"],
};

export function planeStatusForAccounts(
  accounts: readonly CodeRouterAccountSummary[],
): PlaneStatus {
  const claimable = claimableAccounts(accounts);
  const status = (agent: PlaneAgent): AgentPlaneStatus => {
    const usable = claimable.filter((account) => AGENT_KINDS[agent].includes(account.provider));
    const kinds = AGENT_KINDS[agent].filter((kind) => usable.some((account) => account.provider === kind));
    const refreshing = accounts.filter((account) =>
      account.state === "refreshing" && AGENT_KINDS[agent].includes(account.provider),
    ).length;
    return {
      ready: usable.length > 0,
      kinds,
      accounts: usable.length,
      refreshing,
      connect: CONNECT_HINTS[agent],
    };
  };
  return {
    agents: {
      claude: status("claude"),
      codex: status("codex"),
      pi: status("pi"),
      opencode: status("opencode"),
    },
  };
}

type PlaneStatusDependencies = {
  readonly authenticate: typeof authenticateRouteToken;
  /** The same expired-lease sweep routing runs, so a dead refresh worker's account counts as ready again here too. */
  readonly sweepLeases: typeof sweepExpiredRefreshLeases;
  readonly accounts: typeof listAccounts;
};

export function createPlaneStatusHandler(
  dependencies: PlaneStatusDependencies,
): (request: Request) => Promise<Response> {
  return async (request) => {
    const token = bearerToken(request);
    const identity = token ? await dependencies.authenticate(token) : null;
    if (!identity) {
      return Response.json(
        { error: "unauthorized" },
        { status: 401, headers: { "cache-control": "no-store" } },
      );
    }
    await dependencies.sweepLeases(identity.teamId);
    const status = planeStatusForAccounts(await dependencies.accounts(identity.teamId));
    return Response.json(status, { headers: { "cache-control": "no-store" } });
  };
}

export const planeStatus = createPlaneStatusHandler({
  authenticate: authenticateRouteToken,
  sweepLeases: sweepExpiredRefreshLeases,
  accounts: listAccounts,
});
