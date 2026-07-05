import { beforeEach, describe, expect, mock, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { priceUsageMicros } from "../services/coderouter/pricing";
import { CoderouterRepository, type CoderouterRepositoryShape } from "../services/coderouter/repository";
import { ingestUsage } from "../services/coderouter/workflows";
import type { UsageIngest } from "../services/coderouter/types";

let stackConfigured = true;
let quantity = 50_000;
let tryDecreaseQuantityImpl = async (_amount: number) => true;
const tryDecreaseQuantity = mock(async (...args: unknown[]) => tryDecreaseQuantityImpl(Number(args[0])));
const getQuantity = mock(async () => quantity);
const getItem = mock(async () => ({
  getQuantity,
  tryDecreaseQuantity,
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getItem }),
  isStackConfigured: () => stackConfigured,
  stackServerApp: { getItem, getUser: async () => null },
}));

const { CoderouterBillingGateway, makeStackCoderouterBillingGateway } = await import(
  "../services/coderouter/billing"
);
type BillingCustomer = import("../services/coderouter/billing").BillingCustomer;
type CoderouterBillingGatewayShape = import("../services/coderouter/billing").CoderouterBillingGatewayShape;

beforeEach(() => {
  stackConfigured = true;
  quantity = 50_000;
  tryDecreaseQuantity.mockClear();
  tryDecreaseQuantityImpl = async (amount: number) => {
    if (amount > quantity) return false;
    quantity -= amount;
    return true;
  };
  getQuantity.mockClear();
  getItem.mockClear();
});

describe("coderouter Stack billing", () => {
  test("debits managed usage from the configured Stack item and reads balance", async () => {
    const gateway = makeStackCoderouterBillingGateway({
      CMUX_CODEROUTER_CREDIT_ITEM_ID: "coderouter-credit",
    });

    await Effect.runPromise(gateway.debitUsage({ type: "team", id: "team-1" }, 123));
    const balance = await Effect.runPromise(gateway.currentBalanceMicros({ type: "team", id: "team-1" }));

    expect(getItem).toHaveBeenCalledWith({ teamId: "team-1", itemId: "coderouter-credit" });
    expect(tryDecreaseQuantity).toHaveBeenCalledWith(123);
    expect(balance).toBe(49_877);
  });

  test("floors insufficient managed-credit debits at zero instead of throwing", async () => {
    quantity = 5;
    const gateway = makeStackCoderouterBillingGateway({
      CMUX_CODEROUTER_CREDIT_ITEM_ID: "coderouter-credit",
    });

    await Effect.runPromise(gateway.debitUsage({ type: "team", id: "team-1" }, 13));
    const balance = await Effect.runPromise(gateway.currentBalanceMicros({ type: "team", id: "team-1" }));

    expect(tryDecreaseQuantity).toHaveBeenNthCalledWith(1, 13);
    expect(tryDecreaseQuantity).toHaveBeenNthCalledWith(2, 5);
    expect(balance).toBe(0);
  });

  test("is disabled when the credit item env is unset", async () => {
    stackConfigured = false;
    const gateway = makeStackCoderouterBillingGateway({});

    await Effect.runPromise(gateway.debitUsage({ type: "team", id: "team-1" }, 123));
    expect(await Effect.runPromise(gateway.currentBalanceMicros({ type: "team", id: "team-1" }))).toBe(0);
    expect(getItem).not.toHaveBeenCalled();
  });
});

describe("coderouter usage ingest workflow", () => {
  test("inserts duplicate event ids once and debits only newly inserted managed cost", async () => {
    const debits: number[] = [];
    const debitCustomers: BillingCustomer[] = [];
    const seen = new Set<string>();
    const repo = fakeRepo({
      poolForName: () => Effect.succeed({
        id: "pool-1",
        teamId: "team-1",
        billingCustomerType: "user",
        family: "openai",
        createdAt: new Date(),
      }),
      insertUsageEvents: (input) =>
        Effect.sync(() => {
          let inserted = 0;
          let managedCostMicros = 0;
          for (const event of input.events) {
            if (seen.has(event.eventId)) continue;
            seen.add(event.eventId);
            inserted += 1;
            if (event.credentialClass === "managed") {
              managedCostMicros += priceUsageMicros(event.model, {
                inputTokens: event.inputTokens,
                outputTokens: event.outputTokens,
                cacheReadTokens: event.cacheReadTokens,
                cacheWriteTokens: event.cacheWriteTokens,
                estimated: event.estimated,
              }) ?? 0;
            }
          }
          return { inserted, managedCostMicros };
        }),
    });
    const billing: CoderouterBillingGatewayShape = {
      managedBillingEnabled: () => true,
      currentBalanceMicros: () => Effect.succeed(999),
      debitUsage: (_customer: BillingCustomer, amount: number) => Effect.sync(() => {
        debitCustomers.push(_customer);
        debits.push(amount);
      }),
    };
    const layer = Layer.mergeAll(
      Layer.succeed(CoderouterRepository, repo),
      Layer.succeed(CoderouterBillingGateway, billing),
    );

    const usage: UsageIngest = {
      poolId: "team-1:openai",
      events: [managedEvent("event-1"), managedEvent("event-1")],
    };
    const result = await Effect.runPromise(ingestUsage({ usage }).pipe(Effect.provide(layer)));

    expect(result.inserted.inserted).toBe(1);
    expect(debits).toEqual([13]);
    expect(debitCustomers).toEqual([{ type: "user", id: "team-1" }]);
    expect(result.balanceMicros).toBe(999);
  });
});

function managedEvent(eventId: string): UsageIngest["events"][number] {
  return {
    eventId,
    family: "openai",
    endpointClass: "openai_api",
    model: "gpt-5",
    credentialClass: "managed",
    status: 200,
    inputTokens: 1,
    outputTokens: 1,
    cacheReadTokens: 1,
    cacheWriteTokens: 0,
    estimated: false,
    ts: Date.now(),
  };
}

function fakeRepo(overrides: Partial<CoderouterRepositoryShape>): CoderouterRepositoryShape {
  const missing = (name: string) => () => {
    throw new Error(`unexpected repository call: ${name}`);
  };
  return {
    getOrCreatePool: missing("getOrCreatePool"),
    listPoolsForTeam: missing("listPoolsForTeam"),
    poolForName: missing("poolForName"),
    listKeys: missing("listKeys"),
    createKey: missing("createKey"),
    revokeKey: missing("revokeKey"),
    listCredentials: missing("listCredentials"),
    createCredential: missing("createCredential"),
    disableCredential: missing("disableCredential"),
    buildPoolConfig: missing("buildPoolConfig"),
    usageSummary: missing("usageSummary"),
    insertUsageEvents: missing("insertUsageEvents"),
    applyStatusUpdates: () => Effect.void,
    ...overrides,
  } as CoderouterRepositoryShape;
}
