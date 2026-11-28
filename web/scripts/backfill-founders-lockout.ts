#!/usr/bin/env bun

import { readFile } from "node:fs/promises";

import type Stripe from "stripe";
import { and, eq, inArray, isNull } from "drizzle-orm";

import { cloudDb } from "../db/client";
import { stripeCustomers, stripeSubscriptions } from "../db/schema";
import { getStackServerApp } from "../app/lib/stack";
import {
  canonicalizeEmailForMatching,
  findBillingUserByEmail,
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

// Customer identities are supplied by the operator at run time. Keeping this
// checked-in default empty prevents payment and email identifiers from being
// copied into source, logs, or future deployments.
export const FOUNDERS_LOCKOUT_CASES: readonly FoundersLockoutCase[] = [];

type BackfillStripeClient = {
  readonly customers: {
    list(options?: Record<string, unknown>): Promise<{
      data: readonly Stripe.Customer[];
      has_more?: boolean;
    }>;
    retrieve?(id: string): Promise<Stripe.Customer | Stripe.DeletedCustomer>;
  };
  readonly subscriptions: {
    list(options?: Record<string, unknown>): Promise<{
      data: readonly Stripe.Subscription[];
      has_more?: boolean;
    }>;
  };
  readonly checkout: {
    sessions: {
      list(options?: Record<string, unknown>): Promise<{
        data: readonly Stripe.Checkout.Session[];
        has_more?: boolean;
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
 * Reconcile operator-selected Founder's Edition lockout cases.
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
    if (!user) {
      const summary = {
        email: target.email,
        status: "skipped" as const,
        // This operator repair never creates a Stack account. Creating one
        // after a deleted account is absent from the lookup can resurrect a
        // tombstoned mailbox and grant the old paid entitlement to a new id.
        reason: "target_stack_user_not_found",
      };
      summaries.push(summary);
      dependencies.log?.(summary);
      continue;
    }

    // Re-read before deciding what the repair would do. Dry-run and apply must
    // use the same safety checks, so a dry-run can never promise a mutation
    // that apply mode would reject after a stale lookup.
    const freshTarget = await dependencies.stackApp.getUser(user.id);
    if (
      !freshTarget ||
      freshTarget.id !== user.id ||
      freshTarget.isAnonymous === true ||
      freshTarget.isRestricted === true ||
      freshTarget.primaryEmailVerified !== true ||
      !freshTarget.primaryEmail ||
      canonicalizeEmailForMatching(freshTarget.primaryEmail) !==
        canonicalizeEmailForMatching(requestedEmail)
    ) {
      const summary = {
        email: target.email,
        status: "skipped" as const,
        reason: "target_stack_user_not_verified",
        targetUserId: user.id,
      };
      summaries.push(summary);
      dependencies.log?.(backfillLogSummary(summary));
      continue;
    }
    user = freshTarget;

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
      dependencies.log?.(backfillLogSummary(summary));
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
      dependencies.log?.(backfillLogSummary(summary));
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
    dependencies.log?.(backfillLogSummary(summary));
  }
  return { mode: options.dryRun ? "dry-run" : "apply", customers: summaries };
}

/** Keep operator progress logs free of internal Stack and Stripe identifiers. */
function backfillLogSummary(
  summary: FoundersBackfillSummary["customers"][number],
): Record<string, unknown> {
  return {
    email: summary.email,
    status: summary.status,
    reason: summary.reason,
    ...(summary.duplicateUserIds && summary.duplicateUserIds.length > 0
      ? {
          duplicateCount: summary.duplicateUserIds.length,
          manualFollowUp: "flag duplicate Stack account for manual merge/deletion",
        }
      : {}),
  };
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
  const purchaseEmail = target.purchaseEmail ?? target.email;
  const customers = await listStripeCustomersByEmail(client, purchaseEmail);
  let matching = customers.filter(
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
      const paymentCustomer = customers.find(
        (customer) => customer.id === paymentCustomerId,
      );
      const resolvedPaymentCustomer = paymentCustomer ??
        (client.customers.retrieve
          ? await client.customers.retrieve(paymentCustomerId)
          : null);
      const paymentCustomerEmailMatches = Boolean(
        resolvedPaymentCustomer &&
        !("deleted" in resolvedPaymentCustomer && resolvedPaymentCustomer.deleted) &&
        resolvedPaymentCustomer.email &&
        canonicalizeEmailForMatching(resolvedPaymentCustomer.email) ===
          canonicalizeEmailForMatching(purchaseEmail),
      );
      if (
        paymentCustomerEmailMatches &&
        resolvedPaymentCustomer &&
        !matching.some((customer) => customer.id === resolvedPaymentCustomer.id)
      ) {
        matching = [resolvedPaymentCustomer as Stripe.Customer, ...matching];
      }
    }
  }
  for (const customer of matching) {
    const subscriptions = await listStripeSubscriptionsForCustomer(client, customer.id);
    const relevant = subscriptions.filter((subscription) => {
      const metadata = subscription.metadata ?? {};
      return (
        metadata.founders_edition === "true" ||
        (metadata.app === "cmux" && metadata.plan === "pro")
      );
    });
    const founderSubscriptions = relevant.filter(
      (subscription) => subscription.metadata?.founders_edition === "true",
    );
    // The legacy payment link can leave its subscription unclassified. A paid
    // Founder checkout session is still authoritative. Synthetic
    // sessions and remaps use only subscriptions with an explicit cmux or
    // Founder marker, never unrelated history on the same customer.
    const sessions = await listStripeCheckoutSessionsForCustomer(
      client,
      customer.id,
    );
    const selectedSession =
      sessions.find(
        (session) =>
          session.metadata?.founders_edition === "true" &&
          ["paid", "no_payment_required"].includes(session.payment_status) &&
          (!target.paymentIntent ||
          stringID(session.payment_intent) === target.paymentIntent),
      ) ??
      (!target.paymentIntent && founderSubscriptions[0]
        ? syntheticSession(customer, founderSubscriptions[0])
        : null);
    if (!selectedSession) continue;
    const sessionSubscriptionID = stringID(selectedSession.subscription);
    const subscriptionsToRemap = [
      ...new Map(
        relevant
          .map((subscription) => [subscription.id, subscription] as const),
      ).values(),
    ];
    const selectedSubscription =
      (sessionSubscriptionID
        ? subscriptions.find((subscription) => subscription.id === sessionSubscriptionID)
        : null) ??
      founderSubscriptions.find((subscription) => subscription.status !== "canceled") ??
      founderSubscriptions[0] ??
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

/**
 * Stripe's customer list is newest-first and capped at 100 rows. Query both
 * literal/canonical spellings and walk every page so an older purchase cannot
 * be missed by the lockout repair.
 */
async function listStripeCustomersByEmail(
  client: BackfillStripeClient,
  email: string,
): Promise<readonly Stripe.Customer[]> {
  const trimmed = email.trim();
  const lower = trimmed.toLowerCase();
  const canonical = canonicalizeEmailForMatching(trimmed);
  const variants = [...new Set([trimmed, lower, canonical])].filter(Boolean);
  const byID = new Map<string, Stripe.Customer>();
  for (const variant of variants) {
    let startingAfter: string | undefined;
    for (;;) {
      const response = await client.customers.list({
        email: variant,
        limit: 100,
        ...(startingAfter ? { starting_after: startingAfter } : {}),
      });
      for (const customer of response.data) byID.set(customer.id, customer);
      const lastID = response.data.at(-1)?.id;
      if (!response.has_more || !lastID || lastID === startingAfter) break;
      startingAfter = lastID;
    }
  }
  return [...byID.values()];
}

/** Walk every subscription page for a customer, with a repeated-cursor guard. */
async function listStripeSubscriptionsForCustomer(
  client: BackfillStripeClient,
  customerId: string,
): Promise<readonly Stripe.Subscription[]> {
  const subscriptions: Stripe.Subscription[] = [];
  let startingAfter: string | undefined;
  for (;;) {
    const response = await client.subscriptions.list({
      customer: customerId,
      status: "all",
      limit: 100,
      ...(startingAfter ? { starting_after: startingAfter } : {}),
    });
    subscriptions.push(...response.data);
    const lastID = response.data.at(-1)?.id;
    if (!response.has_more || !lastID || lastID === startingAfter) break;
    startingAfter = lastID;
  }
  return subscriptions;
}

/** Walk every checkout-session page for a customer, with a cursor guard. */
async function listStripeCheckoutSessionsForCustomer(
  client: BackfillStripeClient,
  customerId: string,
): Promise<readonly Stripe.Checkout.Session[]> {
  const sessions: Stripe.Checkout.Session[] = [];
  let startingAfter: string | undefined;
  for (;;) {
    const response = await client.checkout.sessions.list({
      customer: customerId,
      limit: 100,
      ...(startingAfter ? { starting_after: startingAfter } : {}),
    });
    sessions.push(...response.data);
    const lastID = response.data.at(-1)?.id;
    if (!response.has_more || !lastID || lastID === startingAfter) break;
    startingAfter = lastID;
  }
  return sessions;
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
      .select({
        stackUserId: stripeSubscriptions.stackUserId,
        stackTeamId: stripeSubscriptions.stackTeamId,
        plan: stripeSubscriptions.plan,
        scope: stripeSubscriptions.scope,
      })
      .from(stripeSubscriptions)
      .where(inArray(stripeSubscriptions.id, requiredSubscriptionIds))
      .limit(requiredSubscriptionIds.length);
    return rows.length !== requiredSubscriptionIds.length || rows.some(
      (row) =>
        row.stackUserId !== targetStackUserId ||
        row.stackTeamId != null ||
        row.plan !== PRO_PLAN_ID ||
        row.scope !== "user",
    );
  } catch {
    // Never skip a repair when the read model is unavailable.
    return true;
  }
}

/** Load audited customer identities from an operator-only JSON file. */
async function loadFoundersLockoutCases(): Promise<readonly FoundersLockoutCase[]> {
  const file = process.env.CMUX_FOUNDERS_LOCKOUT_CASES_FILE?.trim();
  if (!file) {
    throw new Error(
      "Set CMUX_FOUNDERS_LOCKOUT_CASES_FILE to an operator-only JSON case file.",
    );
  }
  let contents: string;
  try {
    contents = await readFile(file, "utf8");
  } catch {
    throw new Error("Could not read the Founder's billing case file.");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(contents);
  } catch {
    throw new Error("The Founder's billing case file is not valid JSON.");
  }
  if (!Array.isArray(parsed)) {
    throw new Error("The Founder's billing case file must contain an array.");
  }
  const cases: FoundersLockoutCase[] = [];
  for (const value of parsed) {
    if (!isRecord(value) || typeof value.email !== "string" || !value.email.trim()) {
      throw new Error("Each Founder's billing case must include an email.");
    }
    const optionalFields = ["purchaseEmail", "paymentIntent", "realEmail"] as const;
    for (const field of optionalFields) {
      if (value[field] !== undefined && typeof value[field] !== "string") {
        throw new Error("Founder's billing case fields must be strings.");
      }
    }
    cases.push({
      email: value.email.trim(),
      ...(typeof value.purchaseEmail === "string" && value.purchaseEmail.trim()
        ? { purchaseEmail: value.purchaseEmail.trim() }
        : {}),
      ...(typeof value.paymentIntent === "string" && value.paymentIntent.trim()
        ? { paymentIntent: value.paymentIntent.trim() }
        : {}),
      ...(typeof value.realEmail === "string" && value.realEmail.trim()
        ? { realEmail: value.realEmail.trim() }
        : {}),
    });
  }
  if (cases.length === 0) {
    throw new Error("The Founder's billing case file is empty.");
  }
  return cases;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const apply = args.includes("--apply");
  const dryRun = !apply;
  const unknown = args.filter(
    (arg) => arg !== "--dry-run" && arg !== "--apply",
  );
  if (unknown.length > 0) {
    throw new Error("Unknown argument. Use --apply to mutate, or --dry-run for a plan.");
  }
  if (apply && args.includes("--dry-run")) {
    throw new Error("Choose either --apply or --dry-run, not both.");
  }
  const stackApp = getStackServerApp() as unknown as StackBillingApp;
  const cases = await loadFoundersLockoutCases();
  const summary = await runFoundersLockoutBackfill(
    { dryRun, cases },
    {
      stripeClient: stripe() as unknown as BackfillStripeClient,
      stackApp,
      billingDependencies: { db: cloudDb() },
      log: (value) => console.log(JSON.stringify(value)),
    },
  );
  console.log(
    JSON.stringify(
      {
        mode: summary.mode,
        customers: summary.customers.map(backfillLogSummary),
      },
      null,
      2,
    ),
  );
}

if ((import.meta as ImportMeta & { main?: boolean }).main) {
  try {
    await main();
  } catch {
    console.error(
      "Founder's billing backfill did not complete; review the per-customer records above before retrying.",
      "operation_failed",
    );
    process.exitCode = 1;
  }
}
