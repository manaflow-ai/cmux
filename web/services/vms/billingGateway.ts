import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import type { ProviderId } from "./drivers";
import {
  VmBillingError,
  VmCreateCreditsInsufficientError,
} from "./errors";

export type BillingCustomerType = "team" | "user";

export type VmCreateCreditReservation =
  | { readonly kind: "none" }
  | {
      readonly kind: "stack_item";
      readonly itemId: string;
      readonly customerType: BillingCustomerType;
      readonly customerId: string;
      readonly amount: number;
    };

export type VmBillingGatewayShape = {
  readonly reserveCreate: (input: {
    readonly userId: string;
    readonly billingCustomerType: BillingCustomerType;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly provider: ProviderId;
    readonly image: string;
    readonly imageVersion?: string | null;
    readonly vmId: string;
    readonly idempotencyKey?: string;
  }) => Effect.Effect<VmCreateCreditReservation, VmBillingError | VmCreateCreditsInsufficientError>;
  readonly refundCreate: (reservation: VmCreateCreditReservation) => Effect.Effect<void, VmBillingError>;
};

export class VmBillingGateway extends Context.Tag("cmux/VmBillingGateway")<
  VmBillingGateway,
  VmBillingGatewayShape
>() {}

export const DEFAULT_FREE_CREATE_CREDIT_ITEM_ID = "cmux-vm-create-credit";

export const VmBillingGatewayLive = Layer.succeed(
  VmBillingGateway,
  makeStackVmBillingGateway(process.env),
);

export function makeStackVmBillingGateway(
  env: Record<string, string | undefined>,
): VmBillingGatewayShape {
  return {
    reserveCreate: (input) =>
      Effect.tryPromise({
        try: async () => {
          const itemId = createCreditItemId(input.billingPlanId, env);
          if (!itemId) return { kind: "none" };

          const { getStackServerApp, isStackConfigured } = await import("../../app/lib/stack");
          if (!isStackConfigured()) {
            throw new Error(`Stack Auth is required for Cloud VM create credits (${itemId})`);
          }
          const amount = createCreditCost(input.billingPlanId, input.provider, env);
          const customer = billingCustomer(input);
          const item = customer.type === "team"
            ? await getStackServerApp().getItem({ teamId: customer.id, itemId })
            : await getStackServerApp().getItem({ userId: customer.id, itemId });
          const reserved = await item.tryDecreaseQuantity(amount);
          if (!reserved) {
            throw new VmCreateCreditsInsufficientError({
              itemId,
              billingCustomerId: customer.id,
              amount,
            });
          }
          return {
            kind: "stack_item" as const,
            itemId,
            customerType: customer.type,
            customerId: customer.id,
            amount,
          };
        },
        catch: (cause) =>
          cause instanceof VmCreateCreditsInsufficientError
            ? cause
            : new VmBillingError({ operation: "reserveCreate", cause }),
      }),

    refundCreate: (reservation) => {
      if (reservation.kind === "none") return Effect.void;
      return Effect.tryPromise({
        try: async () => {
          const { getStackServerApp } = await import("../../app/lib/stack");
          const item = reservation.customerType === "team"
            ? await getStackServerApp().getItem({ teamId: reservation.customerId, itemId: reservation.itemId })
            : await getStackServerApp().getItem({ userId: reservation.customerId, itemId: reservation.itemId });
          await item.increaseQuantity(reservation.amount);
        },
        catch: (cause) => new VmBillingError({ operation: "refundCreate", cause }),
      });
    },
  };
}

export function noOpVmBillingGateway(): VmBillingGatewayShape {
  return {
    reserveCreate: () => Effect.succeed({ kind: "none" }),
    refundCreate: () => Effect.void,
  };
}

function billingCustomer(input: {
  readonly userId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
}): { readonly type: BillingCustomerType; readonly id: string } {
  if (input.billingCustomerType === "team") {
    return { type: "team", id: input.billingTeamId };
  }
  return { type: "user", id: input.userId };
}

function createCreditItemId(
  planId: string,
  env: Record<string, string | undefined>,
): string | null {
  const planSpecific = resolvedCreateCreditItemIdValue(env[createCreditItemIdEnvKey(planId)]);
  if (planSpecific.kind === "disabled") return null;
  if (planSpecific.kind === "item") return planSpecific.itemId;

  const global = resolvedCreateCreditItemIdValue(env.CMUX_VM_CREATE_CREDIT_ITEM_ID);
  if (global.kind === "disabled") return null;
  if (global.kind === "item") return global.itemId;

  return normalizedPlanId(planId) === "free" ? DEFAULT_FREE_CREATE_CREDIT_ITEM_ID : null;
}

function resolvedCreateCreditItemIdValue(
  raw: string | undefined,
): { readonly kind: "unset" } | { readonly kind: "disabled" } | { readonly kind: "item"; readonly itemId: string } {
  const value = raw?.trim();
  if (!value) return { kind: "unset" };
  return isDisabledCreateCreditValue(value)
    ? { kind: "disabled" }
    : { kind: "item", itemId: value };
}

function isDisabledCreateCreditValue(value: string): boolean {
  return ["disabled", "false", "none", "off"].includes(value.toLowerCase());
}

function createCreditItemIdEnvKey(planId: string): string {
  return `CMUX_VM_PLAN_${planEnvKey(planId)}_CREATE_CREDIT_ITEM_ID`;
}

function createCreditCost(
  planId: string,
  provider: ProviderId,
  env: Record<string, string | undefined>,
): number {
  const planKey = planEnvKey(planId);
  const providerKey = `CMUX_VM_CREATE_CREDIT_COST_${provider.toUpperCase()}`;
  const planProviderKey = `CMUX_VM_PLAN_${planKey}_CREATE_CREDIT_COST_${provider.toUpperCase()}`;
  const planKeyDefault = `CMUX_VM_PLAN_${planKey}_CREATE_CREDIT_COST`;
  const configured = firstConfiguredEnv(env, [
    planProviderKey,
    planKeyDefault,
    providerKey,
    "CMUX_VM_CREATE_CREDIT_COST",
  ]);
  const raw = configured?.value ?? "1";
  const key = configured?.key ??
    `${planProviderKey} or ${planKeyDefault} or ${providerKey} or CMUX_VM_CREATE_CREDIT_COST`;
  const value = raw.trim();
  if (!/^\d+$/.test(value)) throw new Error(`${key} must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${key} must be a positive integer`);
  }
  return parsed;
}

function firstConfiguredEnv(
  env: Record<string, string | undefined>,
  keys: readonly string[],
): { readonly key: string; readonly value: string } | null {
  for (const key of keys) {
    const value = env[key];
    if (value?.trim()) return { key, value };
  }
  return null;
}

function normalizedPlanId(planId: string): string {
  const normalized = planId.trim().toLowerCase();
  return normalized || "free";
}

function planEnvKey(planId: string): string {
  return normalizedPlanId(planId).replace(/[^a-zA-Z0-9]/g, "_").toUpperCase();
}
