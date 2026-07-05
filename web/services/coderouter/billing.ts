import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { CoderouterBillingError } from "./errors";

export type BillingCustomerType = "team" | "user";

export type BillingCustomer = {
  readonly type: BillingCustomerType;
  readonly id: string;
};

export type CoderouterBillingGatewayShape = {
  readonly currentBalanceMicros: (customer: BillingCustomer) => Effect.Effect<number, CoderouterBillingError>;
  readonly debitUsage: (customer: BillingCustomer, costMicros: number) => Effect.Effect<void, CoderouterBillingError>;
  readonly managedBillingEnabled: () => boolean;
};

export class CoderouterBillingGateway extends Context.Tag("cmux/CoderouterBillingGateway")<
  CoderouterBillingGateway,
  CoderouterBillingGatewayShape
>() {}

export const CoderouterBillingGatewayLive = Layer.succeed(
  CoderouterBillingGateway,
  makeStackCoderouterBillingGateway(process.env),
);

export function makeStackCoderouterBillingGateway(
  env: Record<string, string | undefined>,
): CoderouterBillingGatewayShape {
  const itemId = () => normalizedItemId(env.CMUX_CODEROUTER_CREDIT_ITEM_ID);
  return {
    managedBillingEnabled: () => itemId() !== null,

    currentBalanceMicros: (customer) => {
      const configuredItemId = itemId();
      if (!configuredItemId) return Effect.succeed(0);
      return Effect.tryPromise({
        try: async () => {
          const item = await stackItem(customer, configuredItemId);
          return await itemQuantity(item);
        },
        catch: (cause) => new CoderouterBillingError("currentBalanceMicros", cause),
      });
    },

    debitUsage: (customer, costMicros) => {
      const configuredItemId = itemId();
      if (!configuredItemId || costMicros <= 0) return Effect.void;
      return Effect.tryPromise({
        try: async () => {
          const item = await stackItem(customer, configuredItemId);
          const reserved = await item.tryDecreaseQuantity(costMicros);
          if (reserved) return;
          const remaining = Math.max(0, Math.floor(await itemQuantity(item)));
          const floorDebit = Math.min(costMicros, remaining);
          if (floorDebit > 0) {
            await item.tryDecreaseQuantity(floorDebit);
          }
        },
        catch: (cause) => new CoderouterBillingError("debitUsage", cause),
      });
    },
  };
}

export function noOpCoderouterBillingGateway(balanceMicros = 0): CoderouterBillingGatewayShape {
  return {
    managedBillingEnabled: () => balanceMicros > 0,
    currentBalanceMicros: () => Effect.succeed(balanceMicros),
    debitUsage: () => Effect.void,
  };
}

async function stackItem(
  customer: BillingCustomer,
  itemId: string,
): Promise<{
  readonly quantity?: number;
  readonly getQuantity?: () => Promise<number>;
  readonly tryDecreaseQuantity: (amount: number) => Promise<boolean>;
}> {
  const { getStackServerApp, isStackConfigured } = await import("../../app/lib/stack");
  if (!isStackConfigured()) {
    throw new Error(`Stack Auth is required for coderouter credits (${itemId})`);
  }
  return customer.type === "team"
    ? await getStackServerApp().getItem({ teamId: customer.id, itemId })
    : await getStackServerApp().getItem({ userId: customer.id, itemId });
}

async function itemQuantity(item: { readonly quantity?: number; readonly getQuantity?: () => Promise<number> }): Promise<number> {
  if (typeof item.getQuantity === "function") return await item.getQuantity();
  if (typeof item.quantity === "number") return item.quantity;
  return 0;
}

function normalizedItemId(value: string | undefined): string | null {
  const normalized = value?.trim();
  return normalized ? normalized : null;
}
