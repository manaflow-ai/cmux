import * as Data from "effect/Data";
import * as Effect from "effect/Effect";

import {
  canonicalizeEmailForMatching,
  emailVariantsForMatching,
  isGmailAddress,
} from "../billing/emailMatching";

const STACK_USER_LOOKUP_PAGE_SIZE = 100;
const MAX_STACK_USER_LOOKUP_PAGES = 100;
const STACK_USER_LOOKUP_DEADLINE_MS = 4_000;

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
      const lookupDeadlineAt = Date.now() + STACK_USER_LOOKUP_DEADLINE_MS;
      const withLookupDeadline = async <Result>(
        operation: () => Promise<Result>,
      ): Promise<Result> => {
        const remainingMs = lookupDeadlineAt - Date.now();
        if (remainingMs <= 0) {
          throw new Error("Stack Auth user lookup deadline exceeded");
        }
        let timeoutID: ReturnType<typeof setTimeout> | undefined;
        try {
          return await Promise.race([
            operation(),
            new Promise<never>((_, reject) => {
              timeoutID = setTimeout(
                () => reject(new Error("Stack Auth user lookup deadline exceeded")),
                remainingMs,
              );
            }),
          ]);
        } finally {
          if (timeoutID !== undefined) clearTimeout(timeoutID);
        }
      };
      const collectUsers = async (
        query: string | undefined,
        limit: number,
      ): Promise<boolean> => {
        let cursor: string | undefined;
        const seenCursors = new Set<string>();
        for (let page = 0; page < MAX_STACK_USER_LOOKUP_PAGES; page += 1) {
          const users = await withLookupDeadline(() =>
            dependencies.stackApp.listUsers({
              ...(query ? { query } : {}),
              ...(cursor ? { cursor } : {}),
              limit,
              includeAnonymous: true,
              includeRestricted: true,
            }),
          );
          // A matching primary email is only a candidate. Keep scanning until
          // a matching account exposes a usable unverified auth channel. This
          // handles duplicate Stack accounts where the first result is stale,
          // anonymous, or missing the channel needed for recovery.
          for (const user of users) {
            if (
              canonicalizeEmailForMatching(user.primaryEmail ?? "") !==
              normalizedEmail
            ) {
              continue;
            }
            const channels = await withLookupDeadline(() =>
              user.listContactChannels(),
            );
            const channel = channels.find(
              (candidate) =>
                canonicalizeEmailForMatching(candidate.value) ===
                  normalizedEmail &&
                candidate.usedForAuth &&
                !candidate.isVerified,
            );
            if (!channel) continue;
            await withLookupDeadline(() =>
              channel.sendVerificationEmail({ callbackUrl: input.callbackURL }),
            );
            return true;
          }
          const nextCursor = users.nextCursor ?? null;
          if (!nextCursor) return false;
          if (seenCursors.has(nextCursor)) {
            throw new Error("Stack Auth user lookup pagination looped");
          }
          seenCursors.add(nextCursor);
          cursor = nextCursor;
        }
        throw new Error("Stack Auth user lookup exceeded its bounded page budget");
      };

      let foundCanonicalMatch = false;
      for (const query of emailVariantsForMatching(input.email)) {
        foundCanonicalMatch = await collectUsers(query, 20);
        if (foundCanonicalMatch) break;
      }
      if (
        !foundCanonicalMatch &&
        isGmailAddress(input.email)
      ) {
        // Stack searches literal contact-channel text. A full, bounded list
        // fallback is required to find a differently dotted Gmail spelling.
        foundCanonicalMatch = await collectUsers(undefined, STACK_USER_LOOKUP_PAGE_SIZE);
      }
      return { delivery: foundCanonicalMatch ? "sent" : "accepted" };
    },
    catch: () => new EmailVerificationRecoveryUnavailable({}),
  });
}
