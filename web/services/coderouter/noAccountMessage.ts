import { accountAccessForIdentity } from "./accountAccess";

export type NoAccountFamily = "codex" | "claude" | "opencode";

const FAMILY: Record<NoAccountFamily, { readonly name: string; readonly hostAdd: string; readonly vmAdd: string }> = {
  codex: { name: "Codex", hostAdd: "`cr add codex`", vmAdd: "`cr add codex`" },
  claude: { name: "Claude upstream", hostAdd: "`cmux coderouter claude add`", vmAdd: "`cr add claude`" },
  opencode: { name: "OpenCode", hostAdd: "`cr add opencode`", vmAdd: "`cr add opencode`" },
};

/**
 * The terminal 403 text when the caller can see no account of a family.
 * An organization's Cloud machine sees only that team's shared accounts (its
 * pool), so an account its owner imported privately on the host is listed
 * there but not here. Say so, and name the two supported ways to change it.
 * A personal machine already sees its owner's private accounts, so sharing
 * would not help it. The message reveals nothing about which accounts exist.
 */
export function noAccountConfiguredMessage(
  family: NoAccountFamily,
  identity: Parameters<typeof accountAccessForIdentity>[0],
): string {
  const { name, hostAdd, vmAdd } = FAMILY[family];
  const vm = accountAccessForIdentity(identity).kind === "vm";
  const message = vm && identity.teamId !== identity.stackUserId
    ? `No ${name} account is shared with this Cloud machine's team. If one was added as private, the person who added it can choose Share with team at coderouter.dev, or add one here with ${vmAdd} (accounts added on a Cloud machine are shared with its team).`
    : `No ${name} account is configured for this team or shared with this caller. Add one with ${vm ? vmAdd : hostAdd} or at coderouter.dev.`;
  // Every agent on a Cloud machine can sign in with the user's own account
  // instead; `cr use own` stops the machine from sending it through CodeRouter.
  return vm ? `${message} ${OWN_LOGIN_HINT[family]}` : message;
}

/**
 * The second way out of a refusal on a Cloud machine, per agent. Machines from
 * images before the sign-in switch have no `cr use`; the parenthetical is
 * their equivalent.
 */
export const OWN_LOGIN_HINT: Record<NoAccountFamily, string> = {
  claude:
    "Or use your own Claude account on this machine: run `cr use own claude` (on older machines, `unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL` in the terminal instead), then restart claude and sign in with /login.",
  codex:
    "Or use your own Codex sign-in on this machine: run `cr use own codex`, then `codex login` (on older machines, start Codex with `codex -c model_provider=openai` after `codex login`).",
  opencode:
    "Or use your own provider sign-in on this machine: run `cr use own opencode`, then `opencode auth login` (on older machines, start OpenCode with `env -u OPENAI_BASE_URL -u ANTHROPIC_BASE_URL opencode`).",
};

/**
 * What the house Claude route (claudeFallback.ts) says when it refuses a team
 * with no Claude account of its own. Plain words for someone who has never
 * heard of upstream accounts: no provider or service names, one way forward.
 * The used-up line is the pricing lane's copy (hq#19720).
 */
export const FALLBACK_REFUSAL_MESSAGES = {
  included_usage_used_up: "You have used the model usage included with your pass. Sign in to Claude or Codex to keep going.",
  model_not_included: "This model is not included with your pass. Sign in to Claude or Codex to use it, or pick a Sonnet model.",
  included_daily_budget_reached: "Included model usage is paused for today. Sign in to Claude or Codex to keep going.",
} as const;
