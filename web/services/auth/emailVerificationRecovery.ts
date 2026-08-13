import * as Data from "effect/Data";
import * as Effect from "effect/Effect";

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
    readonly query: string;
    readonly limit: number;
    readonly includeAnonymous: boolean;
    readonly includeRestricted: boolean;
  }): Promise<readonly RecoveryUser[]>;
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
  const normalizedEmail = normalizeEmail(input.email);
  return Effect.tryPromise({
    try: async () => {
      const users = await dependencies.stackApp.listUsers({
        query: normalizedEmail,
        limit: 20,
        includeAnonymous: true,
        includeRestricted: true,
      });
      for (const user of users) {
        if (normalizeEmail(user.primaryEmail ?? "") !== normalizedEmail) continue;
        const channels = await user.listContactChannels();
        const channel = channels.find(
          (candidate) =>
            normalizeEmail(candidate.value) === normalizedEmail &&
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

function normalizeEmail(value: string): string {
  return value.trim().toLowerCase();
}
