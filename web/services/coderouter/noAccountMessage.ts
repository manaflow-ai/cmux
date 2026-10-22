import { accountAccessForIdentity } from "./accountAccess";

export type NoAccountFamily = "codex" | "claude" | "opencode";

const FAMILY: Record<
  NoAccountFamily,
  { readonly name: string; readonly agent: string; readonly hostAdd: string; readonly vmAdd: string }
> = {
  codex: { name: "Codex", agent: "Codex", hostAdd: "`cr add codex`", vmAdd: "`cr add codex`" },
  claude: { name: "Claude upstream", agent: "Claude", hostAdd: "`cmux coderouter claude add`", vmAdd: "`cr add claude`" },
  opencode: { name: "OpenCode", agent: "OpenCode", hostAdd: "`cr add opencode`", vmAdd: "`cr add opencode`" },
};

/**
 * How a team machine's refusal starts, after the agent's name. The agent pane
 * (webviews/src/agent-session/acpmux/failureCopy.ts) and the iOS chat
 * (TurnFailureCopy.swift) read it to tell this refusal from a rate limit:
 * Codex shows only a 403 body's `error.message`, never its `code`, so the
 * sentence is the one signal that reaches them. Change it with both.
 */
export const TEAM_MACHINE_NO_ACCOUNT = "needs a team account on this machine";

/**
 * The terminal 403 text when the caller can see no account of a family.
 * An organization's Cloud machine sees only that team's shared accounts (its
 * pool), so an account its owner imported privately on the host is listed
 * there but not here. It is shared by the team, so it refuses own sign-ins
 * (agent-auth.sh, vm-kind `team`): the only ways out are an account added on
 * the machine, which is shared with its team, or sharing a private one.
 * A personal machine already sees its owner's private accounts, so sharing
 * would not help it, and it can still use the owner's own sign-in.
 * The message reveals nothing about which accounts exist.
 */
export function noAccountConfiguredMessage(
  family: NoAccountFamily,
  identity: Parameters<typeof accountAccessForIdentity>[0],
): string {
  const { name, agent, hostAdd, vmAdd } = FAMILY[family];
  const vm = accountAccessForIdentity(identity).kind === "vm";
  if (vm && identity.teamId !== identity.stackUserId) {
    return `${agent} ${TEAM_MACHINE_NO_ACCOUNT}. To add one for the team, run ${vmAdd} in this machine's terminal. If someone added one as private, they can choose Share with team at coderouter.dev.`;
  }
  const message = `No ${name} account is configured for this team or shared with this caller. Add one with ${vm ? vmAdd : hostAdd} or at coderouter.dev.`;
  // A personal Cloud machine can sign in with its owner's own account
  // instead; `cr use own` stops the machine from sending it through CodeRouter.
  return vm ? `${message} ${OWN_LOGIN_HINT[family]}` : message;
}

/**
 * The second way out of a refusal on a personal Cloud machine, per agent.
 * Machines from images before the sign-in switch have no `cr use`; the
 * parenthetical is their equivalent.
 */
export const OWN_LOGIN_HINT: Record<NoAccountFamily, string> = {
  claude:
    "Or use your own Claude account on this machine: run `cr use own claude` (on older machines, `unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL` in the terminal instead), then restart claude and sign in with /login.",
  codex:
    "Or use your own Codex sign-in on this machine: run `cr use own codex`, then `codex login` (on older machines, start Codex with `codex -c model_provider=openai` after `codex login`).",
  opencode:
    "Or use your own provider sign-in on this machine: run `cr use own opencode`, then `opencode auth login` (on older machines, start OpenCode with `env -u OPENAI_BASE_URL -u ANTHROPIC_BASE_URL opencode`).",
};
