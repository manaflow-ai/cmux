// Connect once, every machine works.
//
// The app and dashboard connect AI accounts through the hosted Subrouter
// store (`POST /api/subrouter/accounts`, fed by `cmux ai-accounts upload`),
// while cloud machines route model traffic through the coderouter vault. This
// module keeps the two in step: every account connected through the existing
// path (Claude and ChatGPT logins, Anthropic and OpenAI API keys) is mirrored
// into the vault so every machine's agents work immediately, and removing it
// un-mirrors it. Mirroring is best-effort — a vault outage never fails the
// connect.
import { addAccount } from "./accounts";
import { accountAdditionAllowed } from "./entitlement";
import { deleteAccount, findAccountByProviderIdentity } from "./repository";
import type { CodeRouterCredential, CodeRouterProvider } from "./types";
import type { SubrouterAccount, SubrouterAccountInput } from "../subrouter/types";
import { captureCoderouterError } from "../errors";

/** The vault's provider account id for a mirrored Subrouter account. */
export function mirroredProviderAccountId(subrouterAccountId: string): string {
  return `subrouter:${subrouterAccountId}`;
}

/** The vault kinds the mirror can create; un-mirroring searches all of them. */
export const MIRRORED_PROVIDERS: readonly CodeRouterProvider[] = [
  "claude",
  "codex",
  "anthropic-apikey",
  "openai-apikey",
];

/**
 * The vault credential for a connected account. Every kind the app can
 * connect has a machine-plane mapping: Claude and ChatGPT logins become the
 * OAuth kinds the planes refresh server-side, and provider API keys become
 * the key kinds. The vault identity is always the app-side account id, so a
 * disconnect can find its mirror without knowing anything provider-specific.
 */
export function credentialForMirror(
  input: SubrouterAccountInput,
  created: SubrouterAccount,
): CodeRouterCredential {
  const accountId = mirroredProviderAccountId(created.id);
  // The vault's decrypt-path parser requires a non-empty email (it doubles
  // as the account label), so an unlabeled connect falls back to the
  // mirrored identity rather than storing a credential it can't read back.
  const label = created.label?.trim() || input.label?.trim() || accountId;
  switch (input.provider) {
    case "claude": {
      const oauth = input.claudeAiOauth;
      return {
        provider: "claude",
        accessToken: oauth.accessToken,
        refreshToken: oauth.refreshToken,
        accountId,
        email: label,
        expiresAt: oauth.expiresAt,
        ...(oauth.subscriptionType ? { subscriptionType: oauth.subscriptionType } : {}),
      };
    }
    case "codex": {
      const tokens = input.tokens;
      return {
        provider: "codex",
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        idToken: tokens.idToken,
        accountId,
        chatgptAccountId: tokens.accountID,
        email: jwtStringClaim(tokens.idToken, "email") ?? label,
        // The upload carries no expiry; the access token's own `exp` claim
        // is the truth, and a token without one is refreshed on first use.
        expiresAt: jwtExpiryMs(tokens.accessToken) ?? Date.now(),
      };
    }
    case "anthropic-apikey":
      return { provider: "anthropic-apikey", apiKey: input.apiKey, accountId, email: label };
    case "openai-apikey":
      return { provider: "openai-apikey", apiKey: input.apiKey, accountId, email: label };
  }
}

/** A JWT payload claim, read without verification (the provider verifies). */
function jwtStringClaim(token: string, claim: string): string | null {
  const value = jwtPayload(token)?.[claim];
  return typeof value === "string" && value.trim().length > 0 && value.length <= 320
    ? value.trim()
    : null;
}

function jwtExpiryMs(token: string): number | null {
  const exp = jwtPayload(token)?.exp;
  return typeof exp === "number" && Number.isFinite(exp) && exp > 0 ? exp * 1_000 : null;
}

function jwtPayload(token: string): Record<string, unknown> | null {
  const parts = token.split(".");
  if (parts.length !== 3 || !parts[1]) return null;
  try {
    const decoded = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8")) as unknown;
    return decoded && typeof decoded === "object" && !Array.isArray(decoded)
      ? (decoded as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

export type MirrorDependencies = {
  readonly add: typeof addAccount;
  readonly find: typeof findAccountByProviderIdentity;
  readonly remove: typeof deleteAccount;
  readonly report: typeof captureCoderouterError;
  /** The same free-tier account gate `POST /api/coderouter/accounts` applies. */
  readonly additionAllowed: typeof accountAdditionAllowed;
  readonly hostedProRequired: () => boolean;
};

const defaultDependencies: MirrorDependencies = {
  add: addAccount,
  find: findAccountByProviderIdentity,
  remove: deleteAccount,
  report: captureCoderouterError,
  additionAllowed: accountAdditionAllowed,
  hostedProRequired: () => process.env.CODEROUTER_HOSTED_PRO_REQUIRED === "1",
};

export type MirrorOutcome =
  | "mirrored"
  | "refreshed"
  | "limit_reached"
  | "failed";

export async function mirrorConnectedAccount(
  input: {
    readonly teamId: string;
    readonly stackUserId: string;
    readonly input: SubrouterAccountInput;
    readonly created: SubrouterAccount;
  },
  dependencies: MirrorDependencies = defaultDependencies,
): Promise<MirrorOutcome> {
  const credential = credentialForMirror(input.input, input.created);
  try {
    // Mirroring must not be a way around the hosted account limit: the vault
    // applies the same gate here as on its own add endpoint.
    if (dependencies.hostedProRequired()) {
      const decision = await dependencies.additionAllowed({
        stackUserId: input.stackUserId,
        teamId: input.teamId,
        provider: credential.provider,
        providerAccountId: credential.accountId,
      });
      if (!decision.allowed) return "limit_reached";
    }
    // A re-connect carries freshly rotated tokens; the vault copy must follow
    // them rather than keep serving the older, sooner-expiring pair.
    const result = await dependencies.add(input.teamId, credential, { refreshExisting: true });
    return result.refreshed ? "refreshed" : "mirrored";
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
    const providerAccountId = mirroredProviderAccountId(input.subrouterAccountId);
    let existing: Awaited<ReturnType<MirrorDependencies["find"]>> = null;
    for (const provider of MIRRORED_PROVIDERS) {
      existing = await dependencies.find(input.teamId, provider, providerAccountId);
      if (existing) break;
    }
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
