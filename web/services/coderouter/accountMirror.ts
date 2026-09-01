// Connect once, every machine works.
//
// The app and dashboard connect AI accounts through the hosted Subrouter
// store (`POST /api/subrouter/accounts`, fed by `cmux ai-accounts upload`),
// while cloud machines route model traffic through the coderouter vault. This
// module keeps the two in step for the providers the VM plane serves: a Claude
// Max login connected through the existing path is mirrored into the vault so
// every machine's `claude` works immediately, and removing it un-mirrors it.
// Mirroring is best-effort — a vault outage never fails the connect.
import { addAccount } from "./accounts";
import { deleteAccount, findAccountByProviderIdentity } from "./repository";
import type { ClaudeCredential } from "./types";
import type { SubrouterAccount, SubrouterAccountInput } from "../subrouter/types";
import { captureCoderouterError } from "../errors";

/** The vault's provider account id for a mirrored Subrouter account. */
export function mirroredProviderAccountId(subrouterAccountId: string): string {
  return `subrouter:${subrouterAccountId}`;
}

/**
 * The vault credential for a connected account, or null when the VM plane has
 * no provider for it (API-key accounts and Codex stay Subrouter-only here:
 * Codex reaches the vault through `cr add`, keyed by its ChatGPT account id).
 */
export function credentialForMirror(
  input: SubrouterAccountInput,
  created: SubrouterAccount,
): ClaudeCredential | null {
  if (input.provider !== "claude") return null;
  const oauth = input.claudeAiOauth;
  return {
    provider: "claude",
    accessToken: oauth.accessToken,
    refreshToken: oauth.refreshToken,
    accountId: mirroredProviderAccountId(created.id),
    email: created.label ?? "",
    expiresAt: oauth.expiresAt,
    ...(oauth.subscriptionType ? { subscriptionType: oauth.subscriptionType } : {}),
  };
}

export type MirrorDependencies = {
  readonly add: typeof addAccount;
  readonly find: typeof findAccountByProviderIdentity;
  readonly remove: typeof deleteAccount;
  readonly report: typeof captureCoderouterError;
};

const defaultDependencies: MirrorDependencies = {
  add: addAccount,
  find: findAccountByProviderIdentity,
  remove: deleteAccount,
  report: captureCoderouterError,
};

export type MirrorOutcome = "mirrored" | "already_mirrored" | "not_applicable" | "failed";

export async function mirrorConnectedAccount(
  input: {
    readonly teamId: string;
    readonly input: SubrouterAccountInput;
    readonly created: SubrouterAccount;
  },
  dependencies: MirrorDependencies = defaultDependencies,
): Promise<MirrorOutcome> {
  const credential = credentialForMirror(input.input, input.created);
  if (!credential) return "not_applicable";
  try {
    const result = await dependencies.add(input.teamId, credential);
    return result.alreadyExists ? "already_mirrored" : "mirrored";
  } catch (error) {
    dependencies.report(error, {
      operation: "mirror_connected_account",
      route: "/api/subrouter/accounts",
    });
    return "failed";
  }
}

export type UnmirrorOutcome = "removed" | "not_mirrored" | "failed";

export async function unmirrorConnectedAccount(
  input: { readonly teamId: string; readonly subrouterAccountId: string },
  dependencies: MirrorDependencies = defaultDependencies,
): Promise<UnmirrorOutcome> {
  try {
    const existing = await dependencies.find(
      input.teamId,
      "claude",
      mirroredProviderAccountId(input.subrouterAccountId),
    );
    if (!existing) return "not_mirrored";
    const result = await dependencies.remove({
      teamId: input.teamId,
      accountId: existing.id,
    });
    return result.removed ? "removed" : "not_mirrored";
  } catch (error) {
    dependencies.report(error, {
      operation: "unmirror_connected_account",
      route: "/api/subrouter/accounts/[accountId]",
    });
    return "failed";
  }
}
