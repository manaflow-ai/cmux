import type Stripe from "stripe";

import { cloudDb } from "../../db/client";
import { getStackServerApp } from "../../app/lib/stack";
import { withFreshAccountMetadataUser } from "../account/metadataMutation";
import type { AccountDeletionUserMutationLease } from "../account/deletionLock";
import {
  CLOUD_INTRO_CHECKOUT_PURPOSE,
  CLOUD_INTRO_PRICING_USD,
  cloudIntroRefusal,
  cloudIntroTerm,
  isCloudIntroEnabled,
  withCloudIntroGrant,
  type CloudIntroTerm,
} from "./cloudIntro";
import {
  createDrizzleCloudIntroAccountFacts,
  createDrizzleCloudIntroPassStore,
  type CloudIntroAccountFactsQuery,
  type CloudIntroAccountUser,
  type CloudIntroPass,
  type CloudIntroPassStore,
} from "./cloudIntroPasses";
import { stripe as defaultStripe } from "./stripe";

/**
 * Webhook fulfillment of the $1 pass. Called from the Stripe webhook inbox for
 * `checkout.session.completed` and `checkout.session.async_payment_succeeded`
 * of a pass checkout, so a replay, a redelivery, or both events of one payment
 * reach it more than once; every step is idempotent:
 *
 * 1. Stripe's session is re-read; only a paid $1 one-time payment counts.
 * 2. The card's funding and fingerprint come from the PaymentIntent's charge.
 * 3. `settle` decides the pass once, under the store's lock, against the
 *    once-per-account, once-per-card and once-per-team rules and the caps.
 * 4. A refusal refunds the payment (one idempotency key per PaymentIntent).
 * 5. A grant writes `cmuxNextPlan` and its dates, only while the pass runs,
 *    so a replay after the pass ended never grants it again.
 */
export type CloudIntroFulfillmentResult =
  | { readonly status: "granted"; readonly pass: CloudIntroPass }
  | { readonly status: "refused"; readonly pass: CloudIntroPass }
  | { readonly status: "skipped"; readonly reason: string };

type CloudIntroStripe = {
  readonly checkout: { readonly sessions: Pick<Stripe["checkout"]["sessions"], "retrieve"> };
  readonly refunds: Pick<Stripe["refunds"], "create">;
};

export type CloudIntroFulfillmentDependencies = {
  readonly env?: Record<string, string | undefined>;
  readonly now?: () => Date;
  readonly stripe: () => CloudIntroStripe;
  readonly store: CloudIntroPassStore;
  readonly loadUser: (stackUserId: string) => Promise<CloudIntroAccountUser | null>;
  readonly accountFacts: CloudIntroAccountFactsQuery;
  /** Writes the pass into the account's metadata; false when nothing was written. */
  readonly writeGrant: (stackUserId: string, term: CloudIntroTerm) => Promise<boolean>;
};

let defaults: CloudIntroFulfillmentDependencies | null = null;

function defaultDependencies(): CloudIntroFulfillmentDependencies {
  defaults ??= {
    stripe: defaultStripe,
    store: createDrizzleCloudIntroPassStore(),
    loadUser: async (stackUserId) => await getStackServerApp().getUser(stackUserId),
    accountFacts: createDrizzleCloudIntroAccountFacts(),
    writeGrant: writeCloudIntroGrant,
  };
  return defaults;
}

type GrantUser = CloudIntroAccountUser & {
  update(options: { clientReadOnlyMetadata: Record<string, unknown> }): Promise<unknown>;
};

/** Writes the pass under the account mutation lease, like the `cmuxPlan` mirror. */
async function writeCloudIntroGrant(stackUserId: string, term: CloudIntroTerm): Promise<boolean> {
  const app = getStackServerApp();
  return await withFreshAccountMetadataUser({
    db: cloudDb(),
    userId: stackUserId,
    loader: { getUser: async (id) => (await app.getUser(id)) as GrantUser | null },
    operation: async (user: GrantUser, lease: AccountDeletionUserMutationLease) => {
      const metadata = user.clientReadOnlyMetadata as Record<string, unknown> | undefined;
      if (metadata?.cmuxAccountDeleting === true) return false;
      const next = withCloudIntroGrant(metadata, term);
      if (!next) return false;
      await lease.refresh();
      await user.update({ clientReadOnlyMetadata: next });
      return true;
    },
  });
}

type VerifiedPayment = {
  readonly stackUserId: string;
  readonly renewOnPlus: boolean;
  readonly paymentIntentId: string;
  readonly stripeCustomerId: string | null;
  readonly paymentMethodId: string | null;
  readonly cardFingerprint: string | null;
  readonly cardFunding: string | null;
};

export async function fulfillCloudIntroCheckout(
  checkoutSessionId: string,
  dependencies: CloudIntroFulfillmentDependencies = defaultDependencies(),
): Promise<CloudIntroFulfillmentResult> {
  // With the flag off a pass checkout grants nothing, and the payment stays as
  // Stripe recorded it until someone turns the pass on and replays the event.
  if (!isCloudIntroEnabled(dependencies.env)) return { status: "skipped", reason: "cloud_intro_disabled" };
  const session = await dependencies.stripe().checkout.sessions.retrieve(checkoutSessionId, {
    expand: ["payment_intent.latest_charge"],
  });
  const verified = verifiedPayment(session);
  if ("skipped" in verified) return { status: "skipped", reason: verified.skipped };
  const user = await dependencies.loadUser(verified.stackUserId);
  if (!user || user.id !== verified.stackUserId) return { status: "skipped", reason: "cloud_intro_user_unavailable" };
  const account = await dependencies.accountFacts(user);
  const now = dependencies.now?.() ?? new Date();
  const term = cloudIntroTerm(now);
  const pass = await dependencies.store.settle(
    {
      checkoutSessionId,
      stackUserId: verified.stackUserId,
      stackTeamIds: account.stackTeamIds,
      renewOnPlus: verified.renewOnPlus,
      paymentIntentId: verified.paymentIntentId,
      stripeCustomerId: verified.stripeCustomerId,
      cardFingerprint: verified.cardFingerprint,
      cardFunding: verified.cardFunding,
      paymentMethodId: verified.renewOnPlus ? verified.paymentMethodId : null,
      startedAt: term.startedAt,
      endsAt: term.endsAt,
    },
    (facts) => cloudIntroRefusal({ ...facts, ...account, cardFunding: verified.cardFunding }, "payment"),
  );
  if (pass.status === "refused") {
    await refundRefusedPass(pass, dependencies);
    return { status: "refused", pass };
  }
  if (pass.status !== "granted" || !pass.startedAt || !pass.endsAt) {
    return { status: "skipped", reason: "cloud_intro_pass_open" };
  }
  // A replay after the pass ended must not write it back.
  if (pass.endsAt.getTime() > now.getTime()) {
    await dependencies.writeGrant(pass.stackUserId, { startedAt: pass.startedAt, endsAt: pass.endsAt });
  }
  return { status: "granted", pass };
}

async function refundRefusedPass(pass: CloudIntroPass, dependencies: CloudIntroFulfillmentDependencies): Promise<void> {
  if (pass.refundId || !pass.paymentIntentId) return;
  const refund = await dependencies.stripe().refunds.create(
    {
      payment_intent: pass.paymentIntentId,
      reason: "requested_by_customer",
      metadata: { app: "cmux", purpose: CLOUD_INTRO_CHECKOUT_PURPOSE, refusal: pass.refusal ?? "unknown" },
    },
    { idempotencyKey: `cmux-cloud-intro-refund-${pass.paymentIntentId}` },
  );
  await dependencies.store.markRefunded(pass.checkoutSessionId, refund.id);
}

/** The paid pass behind a session, or why it is not one. */
function verifiedPayment(session: Stripe.Checkout.Session): VerifiedPayment | { readonly skipped: string } {
  const metadata = session.metadata ?? {};
  if (metadata.app !== "cmux" || metadata.purpose !== CLOUD_INTRO_CHECKOUT_PURPOSE) {
    return { skipped: "foreign_checkout" };
  }
  const stackUserId = metadata.stackUserId?.trim();
  if (!stackUserId) return { skipped: "cloud_intro_missing_user" };
  if (!isPaidPassAmount(session)) return { skipped: "cloud_intro_not_paid" };
  const intent = expandedIntent(session.payment_intent);
  if (!intent || intent.status !== "succeeded") return { skipped: "cloud_intro_not_paid" };
  const card = chargeCard(intent.latest_charge);
  if (!card) return { skipped: "cloud_intro_card_unreadable" };
  return {
    stackUserId,
    renewOnPlus: metadata.renewOnPlus === "true",
    paymentIntentId: intent.id,
    stripeCustomerId: stripeId(session.customer),
    paymentMethodId: stripeId(intent.payment_method),
    cardFingerprint: card.fingerprint ?? null,
    cardFunding: card.funding ?? null,
  };
}

function isPaidPassAmount(session: Stripe.Checkout.Session): boolean {
  return (
    session.mode === "payment" &&
    session.payment_status === "paid" &&
    session.amount_total === CLOUD_INTRO_PRICING_USD.unitAmountCents &&
    session.currency === CLOUD_INTRO_PRICING_USD.currency
  );
}

function expandedIntent(value: Stripe.Checkout.Session["payment_intent"]): Stripe.PaymentIntent | null {
  return value && typeof value === "object" ? value : null;
}

function chargeCard(
  value: Stripe.PaymentIntent["latest_charge"],
): Stripe.Charge.PaymentMethodDetails.Card | null {
  if (!value || typeof value !== "object") return null;
  return value.payment_method_details?.card ?? null;
}

function stripeId(value: string | { readonly id: string } | null | undefined): string | null {
  if (!value) return null;
  return typeof value === "string" ? value : value.id;
}
