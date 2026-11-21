// `cmux ai-accounts` (macOS app `AIAccountsClient`) and the legacy dashboard
// call `/api/subrouter/accounts`. AI accounts are CodeRouter accounts now (the
// dashboard redirects `/dashboard/ai-accounts` to `/dashboard/coderouter`), and
// the hosted Subrouter those routes used to broker was retired, so every call
// failed with an upstream 502. These handlers keep the shipped wire contract
// and read and remove the team's CodeRouter accounts instead: the native
// provider accounts (`coderouter_accounts`) and the Claude upstream accounts.
import type { CoderouterAccountAccess } from "../coderouter/accountAccess";
import type { captureCoderouterEvent } from "../coderouter/analytics";
import type { ClaudeAccountDescription } from "../coderouter/claudeUpstream";
import type { CodeRouterAccountSummary } from "../coderouter/types";
import type { resolveCoderouterControlContext } from "../coderouter/requestContext";
import { jsonResponse } from "../vms/routeHelpers";

/** The account shape the shipped `ai-accounts` clients read. Never a secret. */
export type LegacyAiAccount = {
  readonly id: string;
  readonly kind: string;
  readonly label?: string;
  readonly createdAt?: string;
  readonly state: string;
  readonly health: { readonly ok: boolean };
};

export type LegacyAiAccountsDependencies = {
  readonly resolve: typeof resolveCoderouterControlContext;
  readonly listNative: (
    teamId: string,
    access: CoderouterAccountAccess,
  ) => Promise<readonly CodeRouterAccountSummary[]>;
  readonly listClaude: (
    teamId: string,
    access: CoderouterAccountAccess,
  ) => Promise<readonly ClaudeAccountDescription[]>;
  readonly removeNative: (input: {
    readonly teamId: string;
    readonly accountId: string;
    readonly stackUserId: string;
    readonly access: CoderouterAccountAccess;
  }) => Promise<{ readonly removed: boolean }>;
  readonly removeClaude: (
    teamId: string,
    accountId: string,
    access: CoderouterAccountAccess,
  ) => Promise<{ readonly removed: boolean }>;
  readonly capture: (event: Parameters<typeof captureCoderouterEvent>[0]) => void;
  readonly isViewOpen: (request: Request) => boolean;
  readonly report: (error: unknown, operation: string) => void;
};

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const AI_ACCOUNTS_UPLOAD_MOVED = {
  error: "ai_accounts_moved_to_coderouter",
  message:
    "AI accounts are CodeRouter accounts now. Add Codex with `cr add codex`, " +
    "Claude with `cmux coderouter claude add`, or use cmux.com/dashboard/coderouter.",
} as const;

export function legacyNativeAccount(account: CodeRouterAccountSummary): LegacyAiAccount {
  return {
    id: account.id,
    kind: account.provider,
    ...(account.label ? { label: account.label } : {}),
    state: account.state,
    health: { ok: account.state === "active" || account.state === "refreshing" },
  };
}

export function legacyClaudeAccount(account: ClaudeAccountDescription): LegacyAiAccount {
  return {
    id: account.id,
    kind: `claude-${account.kind}`,
    ...(account.label ? { label: account.label } : {}),
    createdAt: account.createdAt,
    state: account.state,
    health: { ok: account.state === "active" },
  };
}

export function makeLegacyAiAccountsHandlers(dependencies: LegacyAiAccountsDependencies) {
  async function GET(request: Request): Promise<Response> {
    const resolved = await dependencies.resolve(request);
    if (!resolved.ok) return resolved.response;
    const { team, access } = resolved.value;
    let accounts: LegacyAiAccount[];
    try {
      const [native, claude] = await Promise.all([
        dependencies.listNative(team.teamId, access),
        dependencies.listClaude(team.teamId, access),
      ]);
      accounts = [
        ...native.map(legacyNativeAccount),
        ...claude.map(legacyClaudeAccount),
      ];
    } catch (error) {
      dependencies.report(error, "legacy_list_ai_accounts");
      return unavailable("CodeRouter could not load this team's AI accounts. Retry shortly.");
    }
    if (dependencies.isViewOpen(request)) {
      dependencies.capture({
        event: "coderouter_account_status_viewed",
        teamId: team.teamId,
        properties: {
          source: "legacy_dashboard",
          account_count: accounts.length,
          account_error_count: accounts.filter((account) => !account.health.ok).length,
        },
      });
    }
    return jsonResponse({ teamId: team.teamId, accounts });
  }

  /** Uploads go through CodeRouter's own add flows; see AI_ACCOUNTS_UPLOAD_MOVED. */
  async function POST(request: Request): Promise<Response> {
    const resolved = await dependencies.resolve(request);
    if (!resolved.ok) return resolved.response;
    return jsonResponse(AI_ACCOUNTS_UPLOAD_MOVED, 410);
  }

  async function DELETE(
    request: Request,
    context: { params: Promise<{ accountId: string }> },
  ): Promise<Response> {
    const resolved = await dependencies.resolve(request);
    if (!resolved.ok) return resolved.response;
    const { team, user, access } = resolved.value;
    if (!team.manageAccounts) return jsonResponse({ error: "forbidden" }, 403);
    const { accountId } = await context.params;
    if (!UUID.test(accountId)) return jsonResponse({ error: "invalid_request" }, 400);
    let removed: boolean;
    try {
      // Account ids are random UUIDs in two tables; at most one row matches.
      removed = (await dependencies.removeNative({
        teamId: team.teamId,
        accountId,
        stackUserId: user.id,
        access,
      })).removed;
      if (!removed) {
        removed = (await dependencies.removeClaude(team.teamId, accountId, access)).removed;
      }
    } catch (error) {
      dependencies.report(error, "legacy_remove_ai_account");
      return unavailable("CodeRouter could not remove this account. Nothing was partially removed; retry shortly.");
    }
    if (!removed) {
      return jsonResponse({
        error: "not_found",
        message: "This team has no AI account with that id. List them with `cmux ai-accounts list`.",
      }, 404);
    }
    dependencies.capture({
      event: "coderouter_account_removed",
      userId: user.id,
      teamId: team.teamId,
      properties: { source: "legacy_dashboard" },
    });
    return jsonResponse({ ok: true, teamId: team.teamId });
  }

  return { GET, POST, DELETE };
}

function unavailable(message: string): Response {
  return jsonResponse({ error: "service_unavailable", message, retryable: true }, 503);
}
