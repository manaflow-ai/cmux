import { hasActiveCoderouterSubscription } from "../billing/pro";
import { countAccountsForTeam, findAccountByProviderIdentity } from "./repository";
import type { CodeRouterProvider } from "./types";

/**
 * Hosted coderouter pricing: a team may connect and route up to this many
 * provider accounts (subscriptions) for free. More than this requires an
 * active cmux Pro (user) or Team (team) subscription.
 */
export const CODEROUTER_FREE_ACCOUNT_LIMIT = 3;

export type CoderouterEntitlement = {
  readonly allowed: boolean;
  /** What granted (or would grant) access. */
  readonly basis: "free_tier" | "subscription" | "pro_required";
  readonly accountCount: number;
};

export type CoderouterEntitlementDependencies = {
  readonly countAccounts: typeof countAccountsForTeam;
  readonly hasActiveSubscription: typeof hasActiveCoderouterSubscription;
};

/**
 * Free tier first: the account count is one cheap indexed RDS read and covers
 * most teams, so the Stripe-subscription read only runs for teams over the
 * limit. Failures propagate to the caller, which must fail closed.
 */
export function createCoderouterEntitlementCheck(
  dependencies: CoderouterEntitlementDependencies,
): (stackUserId: string, teamId: string) => Promise<CoderouterEntitlement> {
  return async (stackUserId, teamId) => {
    const accountCount = await dependencies.countAccounts(teamId);
    if (accountCount <= CODEROUTER_FREE_ACCOUNT_LIMIT) {
      return { allowed: true, basis: "free_tier", accountCount };
    }
    const subscribed = await dependencies.hasActiveSubscription(
      stackUserId,
      teamId,
    );
    return subscribed
      ? { allowed: true, basis: "subscription", accountCount }
      : { allowed: false, basis: "pro_required", accountCount };
  };
}

export const coderouterEntitlement = createCoderouterEntitlementCheck({
  countAccounts: countAccountsForTeam,
  hasActiveSubscription: hasActiveCoderouterSubscription,
});

export type AccountAdditionGateDependencies =
  & CoderouterEntitlementDependencies
  & {
    readonly findExisting: typeof findAccountByProviderIdentity;
  };

export type AccountAdditionDecision = {
  readonly allowed: boolean;
  readonly accountCount: number;
};

/**
 * Gate for connecting one more provider account. Re-importing a credential
 * for an account the team already has never increases the count, so it is
 * always allowed — a broken account must stay repairable on the free tier.
 * A genuinely new account is allowed while the team stays at or under the
 * free limit after adding it, or when a subscription covers the team.
 */
export function createAccountAdditionGate(
  dependencies: AccountAdditionGateDependencies,
): (input: {
  stackUserId: string;
  teamId: string;
  provider: CodeRouterProvider;
  providerAccountId: string;
}) => Promise<AccountAdditionDecision> {
  return async (input) => {
    const accountCount = await dependencies.countAccounts(input.teamId);
    const existing = await dependencies.findExisting(
      input.teamId,
      input.provider,
      input.providerAccountId,
    );
    if (existing) return { allowed: true, accountCount };
    if (accountCount < CODEROUTER_FREE_ACCOUNT_LIMIT) {
      return { allowed: true, accountCount };
    }
    const subscribed = await dependencies.hasActiveSubscription(
      input.stackUserId,
      input.teamId,
    );
    return { allowed: subscribed, accountCount };
  };
}

export const accountAdditionAllowed = createAccountAdditionGate({
  countAccounts: countAccountsForTeam,
  hasActiveSubscription: hasActiveCoderouterSubscription,
  findExisting: findAccountByProviderIdentity,
});
