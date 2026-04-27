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
    readonly vmId: string;
    readonly idempotencyKey?: string;
  }) => Effect.Effect<VmCreateCreditReservation, VmBillingError | VmCreateCreditsInsufficientError>;
  readonly refundCreate: (reservation: VmCreateCreditReservation) => Effect.Effect<void, VmBillingError>;
};

export class VmBillingGateway extends Context.Tag("cmux/VmBillingGateway")<
  VmBillingGateway,
  VmBillingGatewayShape
>() {}

export const VmBillingGatewayLive = Layer.succeed(
  VmBillingGateway,
  makeStackVmBillingGateway(process.env),
);

export function makeStackVmBillingGateway(
  env: Record<string, string | undefined>,
): VmBillingGatewayShape {
  const itemId = env.CMUX_VM_CREATE_CREDIT_ITEM_ID?.trim();
  if (!itemId) return noOpVmBillingGateway();

  return {
    reserveCreate: (input) =>
      Effect.tryPromise({
        try: async () => {
          const { getStackServerApp, isStackConfigured } = await import("../../app/lib/stack");
          if (!isStackConfigured()) {
            throw new Error("Stack Auth is required when CMUX_VM_CREATE_CREDIT_ITEM_ID is configured");
          }
          const amount = createCreditCost(input.provider, env);
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

function createCreditCost(
  provider: ProviderId,
  env: Record<string, string | undefined>,
): number {
  const providerKey = `CMUX_VM_CREATE_CREDIT_COST_${provider.toUpperCase()}`;
  const raw = env[providerKey] ?? env.CMUX_VM_CREATE_CREDIT_COST ?? "1";
  const value = raw.trim();
  if (!/^\d+$/.test(value)) throw new Error(`${providerKey} or CMUX_VM_CREATE_CREDIT_COST must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${providerKey} or CMUX_VM_CREATE_CREDIT_COST must be a positive integer`);
  }
  return parsed;
}
