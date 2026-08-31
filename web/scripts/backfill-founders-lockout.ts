#!/usr/bin/env bun

import type Stripe from "stripe";
import { and, eq, inArray, isNull } from "drizzle-orm";

import { cloudDb } from "../db/client";
import { stripeCustomers, stripeSubscriptions } from "../db/schema";
import { getStackServerApp } from "../app/lib/stack";
import {
  canonicalizeEmailForMatching,
  findBillingUserByEmail,
  findOrCreateBillingUser,
  recordFoundersCheckoutCompletion,
  remapBillingOwnershipForRecovery,
  type BillingPurchaseDependencies,
  type StackBillingApp,
} from "../services/billing/purchase";
import { PRO_PLAN_ID } from "../services/billing/pro";
import { enrollTester } from "../services/asc/testflight";
import { stripe } from "../services/billing/stripe";

export type FoundersLockoutCase = {
  readonly email: string;
  readonly purchaseEmail?: string;
  readonly paymentIntent?: string;
  readonly realEmail?: string;
};

export const FOUNDERS_LOCKOUT_CASES: readonly FoundersLockoutCase[] = [
  { email: "bentatum@me.com" },
  {
    email: "zacpeterson98@gmail.com",
    paymentIntent: "pi_3U8UT2GhInAdn3Jb0FOgt60e",
  },
  {
    email: "friedrichmichel800@gmail.com",
    purchaseEmail: "friedrich.michel800@gmail.com",
    realEmail: "friedrichmichel800@gmail.com",
  },
];

type BackfillStripeClient = {
  readonly customers: {
    list(options?: Record<string, unknown>): Promise<{
      data: readonly Stripe.Customer[];
    }>;
    retrieve?(id: string): Promise<Stripe.Customer | Stripe.DeletedCustomer>;
  };
  readonly subscriptions: {
    list(options?: Record<string, unknown>): Promise<{
      data: readonly Stripe.Subscription[];
    }>;
  };
  readonly checkout: {
    sessions: {
      list(options?: Record<string, unknown>): Promise<{
        data: readonly Stripe.Checkout.Session[];
      }>;
    };
  };
  readonly paymentIntents?: {
    retrieve(id: string): Promise<Stripe.PaymentIntent>;
  };
};

export type FoundersBackfillSummary = {
  readonly mode: "dry-run" | "apply";
  readonly customers: readonly {
    readonly email: string;
    readonly status: "did" | "skipped";
    readonly reason: string;
    readonly targetUserId?: string;
    readonly duplicateUserIds?: readonly string[];
  }[];
};

export type FoundersBackfillDependencies = {
  readonly stripeClient: BackfillStripeClient;
  readonly stackApp: StackBillingApp;
  readonly billingDependencies?: BillingPurchaseDependencies;
  readonly provision?: typeof recordFoundersCheckoutCompletion;
  readonly remap?: typeof remapBillingOwnershipForRecovery;
  readonly enroll?: (
    email: string,
    firstName?: string,
    lastName?: string,
  ) => Promise<void>;
  readonly log?: (value: unknown) => void;
};

/**
 * Reconcile the three known Founder's Edition lockout cases.
 *
 * Dry-run performs provider reads and prints the exact intended ownership
 * changes without calling any mutating helper. Apply mode uses the same
 * idempotent recorder as the webhook; subsequent runs therefore report each
 * case as already provisioned.
 */
export async function runFoundersLockoutBackfill(
  options: {
    readonly dryRun: boolean;
    readonly cases?: readonly FoundersLockoutCase[];
  },
  dependencies: FoundersBackfillDependencies,
): Promise<FoundersBackfillSummary> {
  const summaries: Array<FoundersBackfillSummary["customers"][number]> = [];
  for (const target of options.cases ?? FOUNDERS_LOCKOUT_CASES) {
    const resolved = await resolveStripeCase(target, dependencies.stripeClient);
    if (!resolved) {
      const summary = {
        email: target.email,
        status: "skipped" as const,
        reason: "no_paid_cmux_purchase_found",
      };
      summaries.push(summary);
      dependencies.log?.(summary);
      continue;
    }

    const requestedEmail = target.realEmail ?? target.email;
    let user = await findBillingUserByEmail(dependencies.stackApp, requestedEmail);
    if (!user && !options.dryRun) {
      user = await findOrCreateBillingUser(
        dependencies.stackApp,
        requestedEmail,
      );
    }
    if (!user) {
      const summary = {
        email: target.email,
        status: "skipped" as const,
        reason: options.dryRun
          ? "dry_run_would_create_target_user"
          : "target_stack_user_not_found",
      };
      summaries.push(summary);
      dependencies.log?.(summary);
      continue;
    }

    const allUsers = await matchingUsers(dependencies.stackApp, requestedEmail);
    const duplicateUserIds = allUsers
      .map((candidate) => candidate.id)
      .filter((id) => id !== user.id);
    const metadata = user.clientReadOnlyMetadata;
    const alreadyProvisioned =
      user.primaryEmailVerified === true &&
      metadata &&
      typeof metadata === "object" &&
      !Array.isArray(metadata) &&
      ((metadata as Record<string, unknown>).cmuxPlan === "pro" ||
        (metadata as Record<string, unknown>).cmuxVmPlan === "founders");
    const billingDb = dependencies.billingDependencies?.db;
    const needsBillingRepair = await billingRowsNeedRepair(
      billingDb,
      resolved.customer.id,
      user.id,
      resolved.subscriptionIds,
      resolved.subscription?.id,
    );
    if (alreadyProvisioned && !needsBillingRepair) {
      const summary = {
        email: target.email,
        status: "skipped" as const,
        reason: options.dryRun
          ? "already_provisioned_no_mutation"
          : "already_provisioned",
        targetUserId: user.id,
        ...(duplicateUserIds.length > 0 ? { duplicateUserIds } : {}),
      };
      summaries.push(summary);
      dependencies.log?.(
        duplicateUserIds.length > 0
          ? {
              ...summary,
              manualFollowUp: "flag duplicate Stack account for manual merge/deletion",
            }
          : summary,
      );
      continue;
    }
    if (options.dryRun) {
      const summary = {
        email: target.email,
        status: "skipped" as const,
        reason: "dry_run_would_provision",
        targetUserId: user.id,
        ...(duplicateUserIds.length > 0 ? { duplicateUserIds } : {}),
      };
      summaries.push(summary);
      dependencies.log?.({
        ...summary,
        customerId: resolved.customer.id,
        subscriptionIds: resolved.subscriptionIds,
        preserveTeamEntitlements: true,
        manualFollowUp:
          duplicateUserIds.length > 0
            ? "flag duplicate Stack account for manual merge/deletion"
            : undefined,
      });
      continue;
    }

    const billingDependencies: BillingPurchaseDependencies = {
      ...(dependencies.billingDependencies ?? {}),
      stackApp: dependencies.stackApp,
      db: dependencies.billingDependencies?.db ?? cloudDb(),
      testflight: {
        ...(dependencies.billingDependencies?.testflight ?? {}),
        enrollTester: async (email, firstName, lastName) =>
          (dependencies.enroll ?? enrollTester)(email, firstName, lastName),
      },
    };

    // A dotted-alias case moves only the local Stripe history to the selected
    // real account; never delete or merge the duplicate here.
    if (target.realEmail) {
      await (dependencies.remap ?? remapBillingOwnershipForRecovery)(
        {
          customerId: resolved.customer.id,
          subscriptionIds: resolved.subscriptionIds,
          targetStackUserId: user.id,
          email: resolved.customer.email ?? target.email,
        },
        billingDependencies,
      );
    }

    await (dependencies.provision ?? recordFoundersCheckoutCompletion)(
      {
        session: resolved.session,
        subscription: resolved.subscription,
        customer: resolved.customer,
        enrollmentEmail: user.primaryEmail ?? requestedEmail,
      },
      billingDependencies,
    );
    const summary = {
      email: target.email,
      status: "did" as const,
      reason: "provisioned",
      targetUserId: user.id,
      ...(duplicateUserIds.length > 0 ? { duplicateUserIds } : {}),
    };
    summaries.push(summary);
    dependencies.log?.(
      duplicateUserIds.length > 0
        ? {
            ...summary,
            manualFollowUp: "flag duplicate Stack account for manual merge/deletion",
          }
        : summary,
    );
  }
  return { mode: options.dryRun ? "dry-run" : "apply", customers: summaries };
}

async function resolveStripeCase(
  target: FoundersLockoutCase,
  client: BackfillStripeClient,
): Promise<{
  readonly customer: Stripe.Customer;
  readonly session: Stripe.Checkout.Session;
  readonly subscription: Stripe.Subscription | null;
  readonly subscriptionIds: readonly string[];
} | null> {
  const customers = await client.customers.list({ limit: 100 });
  const purchaseEmail = target.purchaseEmail ?? target.email;
  let matching = customers.data.filter(
    (customer) =>
      customer.email &&
      canonicalizeEmailForMatching(customer.email) ===
        canonicalizeEmailForMatching(purchaseEmail),
  );
  const literalPurchaseEmail = purchaseEmail.trim().toLowerCase();
  matching = [...matching].sort((left, right) => {
    const leftExact = left.email?.trim().toLowerCase() === literalPurchaseEmail;
    const rightExact = right.email?.trim().toLowerCase() === literalPurchaseEmail;
    return Number(rightExact) - Number(leftExact);
  });
  if (target.paymentIntent && client.paymentIntents?.retrieve) {
    const paymentIntent = await client.paymentIntents.retrieve(target.paymentIntent);
    const paymentCustomerId = stringID(paymentIntent.customer);
    if (paymentCustomerId) {
      const paymentCustomer = customers.data.find(
        (customer) => customer.id === paymentCustomerId,
      );
      const resolvedPaymentCustomer = paymentCustomer ??
        (client.customers.retrieve
          ? await client.customers.retrieve(paymentCustomerId)
          : null);
      if (
        resolvedPaymentCustomer &&
        !("deleted" in resolvedPaymentCustomer && resolvedPaymentCustomer.deleted) &&
        !matching.some((customer) => customer.id === resolvedPaymentCustomer.id)
      ) {
        matching = [resolvedPaymentCustomer as Stripe.Customer, ...matching];
      }
    }
  }
  for (const customer of matching) {
    const subscriptions = await client.subscriptions.list({
      customer: customer.id,
      status: "all",
      limit: 100,
    });
    const relevant = subscriptions.data.filter((subscription) => {
      const metadata = subscription.metadata ?? {};
      return (
        metadata.founders_edition === "true" ||
        (metadata.app === "cmux" && metadata.plan === "pro")
      );
    });
    // The legacy payment link can leave its subscription unclassified. A
    // paid Founder checkout session is still authoritative; only use a
    // classified subscription as the synthetic-session fallback, never an
    // unrelated subscription on the same Stripe customer.
    const remapCandidates = target.realEmail
      ? subscriptions.data.filter((subscription) => {
          const metadata = subscription.metadata ?? {};
          // Friedrich's customer is explicitly operator-audited. Include
          // unclassified personal subscription history so a cancelled
          // duplicate is moved, while leaving Team-scoped history untouched.
          return !metadata.stackTeamId && metadata.plan !== "team";
        })
      : [];
    const sessions = await client.checkout.sessions.list({
      customer: customer.id,
      limit: 100,
    });
    const selectedSession =
      sessions.data.find(
        (session) =>
          session.metadata?.founders_edition === "true" &&
          ["paid", "no_payment_required"].includes(session.payment_status) &&
          (!target.paymentIntent ||
          stringID(session.payment_intent) === target.paymentIntent),
      ) ??
      (!target.paymentIntent && (relevant[0] ?? remapCandidates[0])
        ? syntheticSession(customer, relevant[0] ?? remapCandidates[0]!)
        : null);
    if (!selectedSession) continue;
    const sessionSubscriptionID = stringID(selectedSession.subscription);
    const subscriptionsToRemap = [
      ...new Map(
        [...relevant, ...remapCandidates]
          .map((subscription) => [subscription.id, subscription] as const),
      ).values(),
    ];
    const selectedSubscription =
      (sessionSubscriptionID
        ? subscriptions.data.find((subscription) => subscription.id === sessionSubscriptionID)
        : null) ??
      relevant.find((subscription) => subscription.status !== "canceled") ??
      remapCandidates.find((subscription) => subscription.status !== "canceled") ??
      relevant[0] ??
      remapCandidates[0] ??
      null;
    return {
      customer,
      session: selectedSession,
      subscription: selectedSubscription,
      subscriptionIds: subscriptionsToRemap.map((subscription) => subscription.id),
    };
  }
  return null;
}

function stringID(value: string | { id: string } | null | undefined): string | null {
  if (!value) return null;
  return typeof value === "string" ? value : value.id;
}

function syntheticSession(
  customer: Stripe.Customer,
  subscription: Stripe.Subscription,
): Stripe.Checkout.Session {
  return {
    id: `backfill_${subscription.id}`,
    client_reference_id: subscription.metadata?.stackUserId ?? null,
    customer: customer.id,
    customer_details: { email: customer.email, name: customer.name },
    metadata: {
      ...subscription.metadata,
      founders_edition: subscription.metadata?.founders_edition ?? "true",
    },
    payment_status: "paid",
    subscription,
  } as unknown as Stripe.Checkout.Session;
}

async function matchingUsers(
  stackApp: StackBillingApp,
  email: string,
): Promise<readonly { id: string }[]> {
  if (!stackApp.listUsers) return [];
  const canonical = canonicalizeEmailForMatching(email);
  const literal = email.trim().toLowerCase();
  const queries = literal === canonical ? [canonical] : [canonical, literal];
  const usersByID = new Map<string, { id: string }>();
  for (const query of queries) {
    const users = await stackApp.listUsers({
      query,
      limit: 50,
      includeAnonymous: true,
      includeRestricted: true,
    });
    for (const user of users) {
      if (
        user.primaryEmail &&
        canonicalizeEmailForMatching(user.primaryEmail) === canonical
      ) {
        usersByID.set(user.id, user);
      }
    }
  }
  return [...usersByID.values()].sort((left, right) =>
    left.id.localeCompare(right.id),
  );
}

async function billingRowsNeedRepair(
  db: BillingPurchaseDependencies["db"] | undefined,
  customerId: string,
  targetStackUserId: string,
  subscriptionIds: readonly string[],
  selectedSubscriptionId?: string,
): Promise<boolean> {
  // A caller that does not inject a database (for example, a dry-run unit
  // harness) cannot prove completion, so it must report the repair plan rather
  // than claiming a no-op. The production entrypoint injects the live DB only
  // when the operator explicitly runs apply mode.
  if (!db) return true;
  try {
    const customerRows = await db
      .select({ stackUserId: stripeCustomers.stackUserId, stackTeamId: stripeCustomers.stackTeamId })
      .from(stripeCustomers)
      .where(eq(stripeCustomers.id, customerId))
      .limit(1);
    const customer = customerRows[0];
    if (!customer || customer.stackUserId !== targetStackUserId || customer.stackTeamId != null) {
      return true;
    }
    const requiredSubscriptionIds = [
      ...new Set([
        ...subscriptionIds,
        ...(selectedSubscriptionId ? [selectedSubscriptionId] : []),
      ]),
    ];
    if (requiredSubscriptionIds.length === 0) {
      const rows = await db
        .select({ id: stripeSubscriptions.id })
        .from(stripeSubscriptions)
        .where(
          and(
            eq(stripeSubscriptions.customerId, customerId),
            eq(stripeSubscriptions.stackUserId, targetStackUserId),
            eq(stripeSubscriptions.plan, PRO_PLAN_ID),
            eq(stripeSubscriptions.scope, "user"),
            isNull(stripeSubscriptions.stackTeamId),
          ),
        )
        .limit(1);
      return rows.length === 0;
    }
    const rows = await db
      .select({ stackUserId: stripeSubscriptions.stackUserId, stackTeamId: stripeSubscriptions.stackTeamId })
      .from(stripeSubscriptions)
      .where(inArray(stripeSubscriptions.id, requiredSubscriptionIds))
      .limit(requiredSubscriptionIds.length);
    return rows.length !== requiredSubscriptionIds.length || rows.some(
      (row) => row.stackUserId !== targetStackUserId || row.stackTeamId != null,
    );
  } catch {
    // Never skip a repair when the read model is unavailable.
    return true;
  }
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const unknown = args.filter((arg) => arg !== "--dry-run");
  if (unknown.length > 0) {
    throw new Error("Unknown argument. Use --dry-run or no arguments.");
  }
  const stackApp = getStackServerApp() as unknown as StackBillingApp;
  const summary = await runFoundersLockoutBackfill(
    { dryRun },
    {
      stripeClient: stripe() as unknown as BackfillStripeClient,
      stackApp,
      billingDependencies: { db: cloudDb() },
      log: (value) => console.log(JSON.stringify(value)),
    },
  );
  console.log(JSON.stringify(summary, null, 2));
}

if ((import.meta as ImportMeta & { main?: boolean }).main) {
  try {
    await main();
  } catch {
    console.error("Founder's billing backfill did not complete; retry after reviewing configuration.");
    process.exitCode = 1;
  }
}
