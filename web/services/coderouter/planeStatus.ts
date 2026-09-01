// What a machine may ask about its own model plane: which agents will work
// right now, and how to fix the ones that will not. Route-token scoped, so it
// exposes nothing a machine cannot already infer by trying — counts and
// kinds, never identifiers or credentials.
import { listAccounts } from "./repository";
import { activeProviderKinds } from "./opencodeProxy";
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
  /** An account of a usable kind is active and not cooling down. */
  readonly ready: boolean;
  /** Active account kinds backing this agent right now. */
  readonly kinds: readonly CodeRouterProvider[];
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
  const active = activeProviderKinds(accounts);
  const status = (agent: PlaneAgent): AgentPlaneStatus => {
    const kinds = AGENT_KINDS[agent].filter((kind) => active.has(kind));
    return { ready: kinds.length > 0, kinds, connect: CONNECT_HINTS[agent] };
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
    const status = planeStatusForAccounts(await dependencies.accounts(identity.teamId));
    return Response.json(status, { headers: { "cache-control": "no-store" } });
  };
}

export const planeStatus = createPlaneStatusHandler({
  authenticate: authenticateRouteToken,
  accounts: listAccounts,
});
