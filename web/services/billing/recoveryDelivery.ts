import * as Data from "effect/Data";
import * as Effect from "effect/Effect";

import type { EmailVerificationRecoveryResult } from "../auth/emailVerificationRecovery";

type PaidRecoveryResult =
  | false
  | true
  | { readonly deliveryEmail: string | null; readonly deliveryHandled?: boolean }
  | { readonly skipped: "account_deletion_in_progress" | "no_customer_email" };

type DeliveryInput = { readonly email: string; readonly callbackURL: string };

export type BillingRecoveryDeliveryDependencies = {
  readonly recoverPaid: (email: string) => Promise<PaidRecoveryResult>;
  readonly sendMagicLink: (input: DeliveryInput) => Promise<void>;
  readonly sendVerification: (input: DeliveryInput) => Promise<EmailVerificationRecoveryResult>;
};

class BillingRecoveryUnavailable extends Data.TaggedError("BillingRecoveryUnavailable")<
  Record<string, never>
> {}

/** Shared recovery decisions, executed only inside the post-response lifecycle. */
export function processBillingRecovery(
  input: DeliveryInput & { readonly verificationURL: string },
  dependencies: BillingRecoveryDeliveryDependencies,
): Effect.Effect<void, BillingRecoveryUnavailable> {
  return Effect.tryPromise({
    try: async () => {
      const paid = await dependencies.recoverPaid(input.email);
      if (paid && typeof paid === "object" && "skipped" in paid) return;
      if (paid) {
        // Provisioning owns the delivery ledger; never send a second link.
        if (typeof paid === "object" && paid.deliveryHandled === true) return;
        const candidate = typeof paid === "object" ? paid.deliveryEmail : null;
        await dependencies.sendMagicLink({
          email: validDeliveryEmail(candidate) ?? input.email,
          callbackURL: input.callbackURL,
        });
      } else {
        await dependencies.sendVerification({
          email: input.email,
          callbackURL: input.verificationURL,
        });
      }
    },
    // Do not retain a raw provider error as a cause: it may contain the email.
    catch: () => new BillingRecoveryUnavailable({}),
  });
}

function validDeliveryEmail(value: string | null): string | null {
  const email = value?.trim();
  return email && email.length <= 254 && /^\S+@\S+\.\S+$/.test(email)
    ? email
    : null;
}
