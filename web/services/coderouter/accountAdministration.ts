import type { CoderouterAccountAccess } from "./accountAccess";

/**
 * Who may change which coderouter accounts.
 *
 * Account administration is the Stack team permission `$manage_api_keys`
 * (personal scopes always have it; see permissions.ts). A team member without
 * it may still add a private account, and change or remove the private
 * accounts they imported: no other member or machine can use those, so they
 * are the member's own. Everything that reaches past them needs account
 * administration:
 *
 * - adding an account shared with the team, or changing an account's sharing
 * - changing or removing a shared account, or removing every account
 * - moving an account to another team
 * - creating or revoking a coderouter API key
 *
 * #12771 made every write need the permission, which refused private imports
 * too (#14111). A VM-bound route token keeps its own rules (requestContext.ts):
 * it imports shared accounts into its pool and never reaches this check.
 */
export const CODEROUTER_ADMIN_PERMISSION = "$manage_api_keys";

export type CoderouterAdminAction =
  | "share_account"
  | "change_shared_account"
  | "remove_all_accounts"
  | "transfer_account"
  | "manage_api_keys";

type TeamPermissionOption = {
  readonly kind: "private" | "switch_team" | "ask_admin";
  readonly message: string;
  readonly command?: string;
};

const NEEDED_FOR: Record<CoderouterAdminAction, string> = {
  share_account: "share accounts with the team",
  change_shared_account: "change or remove accounts shared with the team",
  remove_all_accounts: "remove every account in the team",
  transfer_account: "move accounts between teams",
  manage_api_keys: "create or revoke coderouter API keys",
};

/** Raised when a member's import matches a shared account it may not overwrite. */
export class CoderouterSharedAccountError extends Error {
  constructor() {
    super("account is shared with the team and needs account administration to change");
    this.name = "CoderouterSharedAccountError";
  }
}

/**
 * The access a write runs under. An administrator writes with their normal
 * access; a member without account administration writes only their own
 * private accounts. Machine principals keep theirs.
 */
type WriteContext = {
  readonly user: { readonly id: string };
  readonly team: { readonly manageAccounts: boolean };
  readonly access?: CoderouterAccountAccess;
};
export function accountWriteAccess(context: WriteContext & { readonly access: CoderouterAccountAccess }): CoderouterAccountAccess;
export function accountWriteAccess(context: WriteContext): CoderouterAccountAccess | undefined;
export function accountWriteAccess(context: WriteContext): CoderouterAccountAccess | undefined {
  if (context.team.manageAccounts) return context.access;
  if (context.access && context.access.kind !== "user") return context.access;
  return { kind: "own-private", userId: context.user.id };
}

/**
 * The 403 for an action that needs account administration. It names the team
 * and the permission, and lists what the caller can do instead, so `cr` can
 * print a next step. `addCommand` is the CLI provider for a private re-add.
 */
export function teamPermissionRequired(
  team: { readonly teamId: string; readonly teamName: string },
  action: CoderouterAdminAction,
  options: { readonly error?: "forbidden" | "destination_forbidden"; readonly addCommand?: "claude" | "codex" } = {},
): Response {
  return Response.json({
    error: options.error ?? "forbidden",
    code: "team_permission_required",
    message: `You need the ${CODEROUTER_ADMIN_PERMISSION} permission in ${team.teamName} to ${NEEDED_FOR[action]}.`,
    teamId: team.teamId,
    teamName: team.teamName,
    permission: CODEROUTER_ADMIN_PERMISSION,
    action,
    options: permissionOptions(team.teamName, action, options.addCommand),
    retryable: false,
  }, { status: 403, headers: { "cache-control": "no-store" } });
}

function permissionOptions(
  teamName: string,
  action: CoderouterAdminAction,
  addCommand?: "claude" | "codex",
): TeamPermissionOption[] {
  const privateAccount: TeamPermissionOption = {
    kind: "private",
    message: "Keep the account private. Only you can use it, and no permission is needed.",
    ...(addCommand ? { command: `cr add ${addCommand} --private` } : {}),
  };
  const switchTeam: TeamPermissionOption = {
    kind: "switch_team",
    message: `Switch to a team where you have ${CODEROUTER_ADMIN_PERMISSION}.`,
    command: "cr org switch <team>",
  };
  const askAdmin: TeamPermissionOption = {
    kind: "ask_admin",
    message: `Ask an admin of ${teamName} to grant ${CODEROUTER_ADMIN_PERMISSION} or to make the change.`,
  };
  switch (action) {
    case "share_account":
      return [privateAccount, switchTeam, askAdmin];
    case "change_shared_account":
    case "remove_all_accounts":
      return [askAdmin];
    case "transfer_account":
    case "manage_api_keys":
      return [switchTeam, askAdmin];
  }
}
