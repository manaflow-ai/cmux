import { beforeEach, describe, expect, mock, test } from "bun:test";
import * as Effect from "effect/Effect";
import {
  DEFAULT_FREE_CREATE_CREDIT_ITEM_ID,
  makeStackVmBillingGateway,
  type VmBillingGatewayShape,
} from "../services/vms/billingGateway";
import { VmCreateCreditsInsufficientError } from "../services/vms/errors";

type ReserveCreateInput = Parameters<VmBillingGatewayShape["reserveCreate"]>[0];

let stackConfigured = true;
const tryDecreaseQuantity = mock(async () => true);
const increaseQuantity = mock(async () => undefined);
const getItem = mock(async () => ({
  tryDecreaseQuantity,
  increaseQuantity,
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getItem }),
  isStackConfigured: () => stackConfigured,
}));

beforeEach(() => {
  stackConfigured = true;
  tryDecreaseQuantity.mockClear();
  tryDecreaseQuantity.mockResolvedValue(true);
  increaseQuantity.mockClear();
  getItem.mockClear();
});

describe("Stack VM billing gateway", () => {
  test("consumes the default free-plan Stack Auth create-credit item", async () => {
    const gateway = makeStackVmBillingGateway({});

    const reservation = await Effect.runPromise(gateway.reserveCreate(createInput()));

    expect(getItem).toHaveBeenCalledWith({
      teamId: "team-billing",
      itemId: DEFAULT_FREE_CREATE_CREDIT_ITEM_ID,
    });
    expect(tryDecreaseQuantity).toHaveBeenCalledWith(1);
    expect(reservation).toEqual({
      kind: "stack_item",
      itemId: DEFAULT_FREE_CREATE_CREDIT_ITEM_ID,
      customerType: "team",
      customerId: "team-billing",
      amount: 1,
    });
  });

  test("does not require create credits for paid plans by default", async () => {
    stackConfigured = false;
    const gateway = makeStackVmBillingGateway({});

    const reservation = await Effect.runPromise(gateway.reserveCreate(createInput({
      billingPlanId: "pro",
    })));

    expect(reservation).toEqual({ kind: "none" });
    expect(getItem).not.toHaveBeenCalled();
  });

  test("allows the default free-plan create-credit item to be disabled", async () => {
    stackConfigured = false;
    const gateway = makeStackVmBillingGateway({
      CMUX_VM_PLAN_FREE_CREATE_CREDIT_ITEM_ID: "none",
    });

    const reservation = await Effect.runPromise(gateway.reserveCreate(createInput()));

    expect(reservation).toEqual({ kind: "none" });
    expect(getItem).not.toHaveBeenCalled();
  });

  test("allows the global create-credit item to disable the free-plan default", async () => {
    stackConfigured = false;
    const gateway = makeStackVmBillingGateway({
      CMUX_VM_CREATE_CREDIT_ITEM_ID: "disabled",
    });

    const reservation = await Effect.runPromise(gateway.reserveCreate(createInput()));

    expect(reservation).toEqual({ kind: "none" });
    expect(getItem).not.toHaveBeenCalled();
  });

  test("preserves global Stack Auth create-credit items for paid plans", async () => {
    const gateway = makeStackVmBillingGateway({
      CMUX_VM_CREATE_CREDIT_ITEM_ID: "global-vm-create-credit",
    });

    const reservation = await Effect.runPromise(gateway.reserveCreate(createInput({
      billingPlanId: "pro",
    })));

    expect(getItem).toHaveBeenCalledWith({
      teamId: "team-billing",
      itemId: "global-vm-create-credit",
    });
    expect(reservation).toEqual(expect.objectContaining({
      itemId: "global-vm-create-credit",
      amount: 1,
    }));
  });

  test("allows plan-specific Stack Auth item and cost overrides", async () => {
    const gateway = makeStackVmBillingGateway({
      CMUX_VM_PLAN_FREE_CREATE_CREDIT_ITEM_ID: "free-vm-create-credit",
      CMUX_VM_PLAN_FREE_CREATE_CREDIT_COST_FREESTYLE: "2",
    });

    const reservation = await Effect.runPromise(gateway.reserveCreate(createInput({
      provider: "freestyle",
    })));

    expect(getItem).toHaveBeenCalledWith({
      teamId: "team-billing",
      itemId: "free-vm-create-credit",
    });
    expect(tryDecreaseQuantity).toHaveBeenCalledWith(2);
    expect(reservation).toEqual(expect.objectContaining({
      itemId: "free-vm-create-credit",
      amount: 2,
    }));
  });

  test("fails before provider create when Stack Auth create credits are exhausted", async () => {
    tryDecreaseQuantity.mockResolvedValue(false);
    const gateway = makeStackVmBillingGateway({});

    const error = await Effect.runPromise(
      gateway.reserveCreate(createInput()).pipe(Effect.flip),
    );

    expect(error).toBeInstanceOf(VmCreateCreditsInsufficientError);
    expect(error).toMatchObject({
      itemId: DEFAULT_FREE_CREATE_CREDIT_ITEM_ID,
      billingCustomerId: "team-billing",
      amount: 1,
    });
  });

  test("refunds a reserved Stack Auth create credit", async () => {
    const gateway = makeStackVmBillingGateway({});

    await Effect.runPromise(gateway.refundCreate({
      kind: "stack_item",
      itemId: DEFAULT_FREE_CREATE_CREDIT_ITEM_ID,
      customerType: "team",
      customerId: "team-billing",
      amount: 1,
    }));

    expect(getItem).toHaveBeenCalledWith({
      teamId: "team-billing",
      itemId: DEFAULT_FREE_CREATE_CREDIT_ITEM_ID,
    });
    expect(increaseQuantity).toHaveBeenCalledWith(1);
  });
});

function createInput(overrides: Partial<ReserveCreateInput> = {}): ReserveCreateInput {
  return {
    userId: "user-billing",
    billingCustomerType: "team" as const,
    billingTeamId: "team-billing",
    billingPlanId: "free",
    provider: "e2b" as const,
    image: "cmuxd-ws:test",
    imageVersion: "test-version",
    vmId: "vm-billing",
    idempotencyKey: "idem-billing",
    ...overrides,
  };
}
