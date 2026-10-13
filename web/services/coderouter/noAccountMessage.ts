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
  if (accountAccessForIdentity(identity).kind === "vm" && identity.teamId !== identity.stackUserId) {
    return `No ${name} account is shared with this Cloud machine's team. If one was added as private, the person who added it can choose Share with team at coderouter.dev, or add one here with ${vmAdd} (accounts added on a Cloud machine are shared with its team).`;
  }
  return `No ${name} account is configured for this team or shared with this caller. Add one with ${hostAdd} or at coderouter.dev.`;
}
