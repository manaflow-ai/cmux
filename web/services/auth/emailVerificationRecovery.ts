import * as Data from "effect/Data";
import * as Effect from "effect/Effect";

import {
  canonicalizeEmailForMatching,
  emailVariantsForMatching,
  isGmailAddress,
} from "../billing/emailMatching";

const STACK_USER_LOOKUP_PAGE_SIZE = 100;
const MAX_STACK_USER_LOOKUP_PAGES = 100;

type RecoveryContactChannel = {
  readonly value: string;
  readonly isVerified: boolean;
  readonly usedForAuth: boolean;
  sendVerificationEmail(options: { callbackUrl: string }): Promise<void>;
};

type RecoveryUser = {
  readonly primaryEmail: string | null;
  listContactChannels(): Promise<readonly RecoveryContactChannel[]>;
};

export type EmailVerificationRecoveryStackApp = {
  listUsers(options: {
    readonly cursor?: string;
    readonly query?: string;
    readonly limit: number;
    readonly includeAnonymous: boolean;
    readonly includeRestricted: boolean;
  }): Promise<(readonly RecoveryUser[]) & { readonly nextCursor?: string | null }>;
};

export type EmailVerificationRecoveryResult = {
  readonly delivery: "sent" | "accepted";
};

export class EmailVerificationRecoveryUnavailable extends Data.TaggedError(
  "EmailVerificationRecoveryUnavailable",
)<Record<string, never>> {}

/**
 * Sends Stack's own contact-channel verification email when an exact,
 * unverified email-auth channel exists. A missing or already-verified channel
 * returns the same accepted outcome so callers cannot enumerate accounts.
 */
export function requestEmailVerificationRecovery(
  input: {
    readonly email: string;
    readonly callbackURL: string;
  },
  dependencies: {
    readonly stackApp: EmailVerificationRecoveryStackApp;
  },
): Effect.Effect<
  EmailVerificationRecoveryResult,
  EmailVerificationRecoveryUnavailable
> {
  const normalizedEmail = canonicalizeEmailForMatching(input.email);
  return Effect.tryPromise({
    try: async () => {
      // Stack's email query is literal. Gmail aliases compare equal for
      // ownership, but a dotted account is not returned by a query for its
      // undotted spelling (and googlemail.com is a separate search value).
      // Query every bounded provider spelling, then canonicalize locally.
      const usersByLiteralEmail = new Map<string, RecoveryUser>();
      const collectUsers = async (query: string | undefined, limit: number) => {
        let cursor: string | undefined;
        for (let page = 0; page < MAX_STACK_USER_LOOKUP_PAGES; page += 1) {
          const users = await dependencies.stackApp.listUsers({
            ...(query ? { query } : {}),
            ...(cursor ? { cursor } : {}),
            limit,
            includeAnonymous: true,
            includeRestricted: true,
          });
          for (const user of users) {
            const literalEmail = user.primaryEmail?.trim().toLowerCase();
            if (!literalEmail) continue;
            usersByLiteralEmail.set(literalEmail, user);
          }
          const nextCursor = users.nextCursor ?? null;
          if (!nextCursor || nextCursor === cursor) return;
          cursor = nextCursor;
        }
        throw new Error("Stack Auth user lookup exceeded its bounded page budget");
      };

      for (const query of emailVariantsForMatching(input.email)) {
        await collectUsers(query, 20);
      }
      if (
        ![...usersByLiteralEmail.values()].some(
          (user) =>
            canonicalizeEmailForMatching(user.primaryEmail ?? "") ===
            normalizedEmail,
        ) &&
        isGmailAddress(input.email)
      ) {
        // Stack searches literal contact-channel text. A full, bounded list
        // fallback is required to find a differently dotted Gmail spelling.
        await collectUsers(undefined, STACK_USER_LOOKUP_PAGE_SIZE);
      }
      for (const user of usersByLiteralEmail.values()) {
        if (
          canonicalizeEmailForMatching(user.primaryEmail ?? "") !==
          normalizedEmail
        ) continue;
        const channels = await user.listContactChannels();
        const channel = channels.find(
          (candidate) =>
            canonicalizeEmailForMatching(candidate.value) === normalizedEmail &&
            candidate.usedForAuth &&
            !candidate.isVerified,
        );
        if (!channel) continue;
        await channel.sendVerificationEmail({ callbackUrl: input.callbackURL });
        return { delivery: "sent" as const };
      }
      return { delivery: "accepted" as const };
    },
    catch: () => new EmailVerificationRecoveryUnavailable({}),
  });
}
