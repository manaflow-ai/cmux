import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";

import {
  captureVmProductEvent,
  VM_LEDGER_TO_POSTHOG_EVENT,
  VM_PRODUCT_EVENT_NAMES,
  vmProductEventFromLedger,
  withVmProductAnalytics,
} from "../services/vms/productAnalytics";
import {
  captureVmRequestOutcome,
  isPolledVmOperation,
  VM_REQUEST_POSTHOG_SCHEMA_VERSION,
} from "../services/vms/observability";
import {
  annotateVmRequestBilling,
  runWithVmRequestContext,
  vmIdFromRequestPath,
  type VmRequestContext,
} from "../services/vms/requestContext";
import type { VmRepositoryShape, VmUsageEventInput } from "../services/vms/repository";

const NOW = new Date("2026-09-03T12:00:00.000Z");

function ledgerRow(overrides: Partial<VmUsageEventInput> = {}): VmUsageEventInput {
  return {
    userId: "user-1",
    billingTeamId: "team-1",
    billingPlanId: "Pro",
    vmId: "11111111-1111-4111-8111-111111111111",
    eventType: "vm.created",
    provider: "freestyle",
    imageId: "sh-abc",
    metadata: {},
    ...overrides,
  };
}

describe("cloud vm ledger to PostHog mapping", () => {
  test("vm.created becomes cloud_vm_created keyed by the user with team group, plan and shape", () => {
    const event = vmProductEventFromLedger(ledgerRow({
      metadata: {
        origin: "fork",
        imageVersion: "v5",
        imageSize: "lgx",
        memoryMb: 20480,
        persistentHome: true,
        perMachineHome: false,
        idempotencyKeySet: true,
        // Free-form keys never reach PostHog.
        homeVolume: "cmux-home-secret",
        message: "provider said no",
      },
    }), NOW);
    expect(event).not.toBeNull();
    expect(event!.event).toBe("cloud_vm_created");
    expect(event!.distinctId).toBe("user-1");
    expect(event!.teamId).toBe("team-1");
    expect(event!.insertId).toBe("cloud_vm_created:11111111-1111-4111-8111-111111111111");
    expect(event!.properties).toEqual({
      product: "cloud_vm",
      ledger_event: "vm.created",
      vm_id: "11111111-1111-4111-8111-111111111111",
      provider: "freestyle",
      image_id: "sh-abc",
      plan_id: "pro",
      billing_team_id: "team-1",
      schema_version: 1,
      origin: "fork",
      image_version: "v5",
      image_size: "lgx",
      memory_mb: 20480,
      persistent_home: true,
      per_machine_home: false,
      idempotency_key_set: true,
    });
    expect(event!.set).toEqual({ billing_plan: "pro" });
    expect(event!.setOnce).toEqual({ cloud_vm_first_created_at: NOW.toISOString() });
  });

  test("vm.destroyed carries the reason and the machine lifetime", () => {
    const createdAt = new Date(NOW.getTime() - 90 * 60 * 1000);
    const event = vmProductEventFromLedger(ledgerRow({
      eventType: "vm.destroyed",
      vmCreatedAt: createdAt,
      metadata: { source: "provider_status_cron", homeVolumeDeleted: true },
    }), NOW);
    expect(event!.event).toBe("cloud_vm_destroyed");
    expect(event!.properties).toMatchObject({
      reason: "provider_status_cron",
      home_volume_deleted: true,
      lifetime_seconds: 5400,
    });
    expect(event!.insertId).toBe("cloud_vm_destroyed:11111111-1111-4111-8111-111111111111");
  });

  test("an unknown destroy source stays neutral and a missing createdAt omits lifetime", () => {
    const event = vmProductEventFromLedger(ledgerRow({
      eventType: "vm.destroyed",
      metadata: { source: "something-new" },
    }), NOW);
    expect(event!.properties).toMatchObject({ reason: "unknown" });
    expect("lifetime_seconds" in event!.properties!).toBe(false);
  });

  test("account-deletion destroys stay in the ledger without recreating the deleted person", () => {
    expect(vmProductEventFromLedger(ledgerRow({
      eventType: "vm.destroyed",
      metadata: { source: "account_deletion" },
    }), NOW)).toBeNull();
  });

  test("attach, exec and the other lifecycle rows map with their typed metadata", () => {
    const attach = vmProductEventFromLedger(ledgerRow({
      eventType: "vm.attach",
      metadata: { transport: "cmux-remote", invited: false },
    }), NOW);
    expect(attach!.event).toBe("cloud_vm_attached");
    expect(attach!.properties).toMatchObject({ transport: "cmux-remote", invited: false });
    expect(attach!.setOnce).toEqual({ cloud_vm_first_attached_at: NOW.toISOString() });
    expect(attach!.insertId).toBeUndefined();

    const exec = vmProductEventFromLedger(ledgerRow({
      eventType: "vm.exec",
      metadata: { exitCode: 1, commandLength: 42 },
    }), NOW);
    expect(exec!.event).toBe("cloud_vm_exec");
    expect(exec!.properties).toMatchObject({ exit_code: 1, command_length: 42 });

    const port = vmProductEventFromLedger(ledgerRow({ eventType: "vm.open_port", metadata: { port: 3000 } }), NOW);
    expect(port!.event).toBe("cloud_vm_port_opened");
    expect(port!.properties).toMatchObject({ port: 3000 });

    const base = vmProductEventFromLedger(ledgerRow({ eventType: "vm.base.reset", metadata: { generation: 3 } }), NOW);
    expect(base!.event).toBe("cloud_vm_base_reset");
    expect(base!.properties).toMatchObject({ generation: 3 });
  });

  test("failure and bookkeeping rows are not product events", () => {
    for (const eventType of [
      "vm.create.failed",
      "vm.create.requested",
      "vm.create.credit.reserved",
      "vm.home_volume.delete_failed",
      "vm.destroy.after_provider_destroy_failed",
      "base.create_failed",
    ]) {
      expect(vmProductEventFromLedger(ledgerRow({ eventType }), NOW)).toBeNull();
    }
  });

  test("metadata values of the wrong type are dropped, not forwarded", () => {
    const event = vmProductEventFromLedger(ledgerRow({
      eventType: "vm.exec",
      metadata: { exitCode: "1", commandLength: { nested: true } },
    }), NOW);
    expect(event!.properties!.exit_code).toBeUndefined();
    expect(event!.properties!.command_length).toBeUndefined();
  });

  test("every ledger type in the map has a distinct PostHog name", () => {
    expect(new Set(VM_PRODUCT_EVENT_NAMES).size).toBe(Object.keys(VM_LEDGER_TO_POSTHOG_EVENT).length);
    for (const name of VM_PRODUCT_EVENT_NAMES) expect(name.startsWith("cloud_vm_")).toBe(true);
  });
});

describe("repository analytics sink", () => {
  function fakeRepository(): { repo: VmRepositoryShape; written: VmUsageEventInput[] } {
    const written: VmUsageEventInput[] = [];
    const repo = {
      recordUsageEvent: (input: VmUsageEventInput) => Effect.sync(() => {
        written.push(input);
      }),
      recordUsageEvents: (inputs: readonly VmUsageEventInput[]) => Effect.sync(() => {
        written.push(...inputs);
      }),
    } as unknown as VmRepositoryShape;
    return { repo, written };
  }

  test("every ledger write reaches the capture and still lands in the database", async () => {
    const { repo, written } = fakeRepository();
    const captured: VmUsageEventInput[] = [];
    const decorated = withVmProductAnalytics(repo, (input) => {
      captured.push(input);
    });
    await Effect.runPromise(decorated.recordUsageEvent(ledgerRow()));
    await Effect.runPromise(decorated.recordUsageEvents([
      ledgerRow({ eventType: "vm.attach" }),
      ledgerRow({ eventType: "vm.create.failed" }),
    ]));
    expect(captured.map((input) => input.eventType)).toEqual(["vm.created", "vm.attach", "vm.create.failed"]);
    expect(written.map((input) => input.eventType)).toEqual(["vm.created", "vm.attach", "vm.create.failed"]);
  });

  test("a throwing capture never fails the ledger write", async () => {
    const { repo, written } = fakeRepository();
    const decorated = withVmProductAnalytics(repo, () => {
      throw new Error("posthog exploded");
    });
    await Effect.runPromise(decorated.recordUsageEvent(ledgerRow()));
    expect(written).toHaveLength(1);
  });

  test("a failed ledger write does not create a product event", async () => {
    const captured: VmUsageEventInput[] = [];
    const repo = {
      recordUsageEvent: () => Effect.fail(new Error("database unavailable")),
      recordUsageEvents: () => Effect.fail(new Error("database unavailable")),
    } as unknown as VmRepositoryShape;
    const decorated = withVmProductAnalytics(repo, (input) => captured.push(input));
    await expect(Effect.runPromise(decorated.recordUsageEvent(ledgerRow()))).rejects.toThrow("database unavailable");
    await expect(Effect.runPromise(decorated.recordUsageEvents([ledgerRow()]))).rejects.toThrow("database unavailable");
    expect(captured).toHaveLength(0);
  });

  test("the default capture posts the mapped event through the shared sender", async () => {
    const bodies: Array<Record<string, unknown>> = [];
    const fetchImpl = (async (_input: string | URL | Request, init?: RequestInit) => {
      bodies.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
      return new Response(null, { status: 200 });
    }) as unknown as typeof fetch;
    const deferred: Array<() => Promise<void>> = [];
    captureVmProductEvent(ledgerRow(), {
      fetch: fetchImpl,
      env: { CMUX_SERVER_ANALYTICS_FORCE: "1" },
      defer: (task) => {
        deferred.push(task);
      },
      now: () => NOW,
    });
    await deferred[0]!();
    expect(bodies).toHaveLength(1);
    expect(bodies[0]).toMatchObject({ event: "cloud_vm_created", distinct_id: "user-1" });
    expect((bodies[0].properties as Record<string, unknown>).$groups).toEqual({ stack_team: "team-1" });
    expect((bodies[0].properties as Record<string, unknown>).$set).toEqual({ billing_plan: "pro" });
  });
});

describe("cloud_vm_request scope", () => {
  function context(overrides: Partial<VmRequestContext> = {}): VmRequestContext {
    return {
      route: "/api/vm/[id]/exec",
      method: "POST",
      operation: "exec",
      startedAtMs: 0,
      client: { name: "cmux-mac" },
      userId: "user-1",
      ...overrides,
    };
  }

  type CapturedRequestBody = {
    batch: Array<{ event: string; properties: Record<string, unknown> }>;
  };

  function capture(ctx: VmRequestContext, response: Response): CapturedRequestBody | null {
    let body: CapturedRequestBody | null = null;
    const fakeFetch = ((_input: string | URL | Request, init?: RequestInit) => {
      body = JSON.parse(String(init?.body));
      return Promise.resolve(new Response("ok"));
    }) as unknown as typeof fetch;
    captureVmRequestOutcome(
      { context: ctx, response, durationMs: 10 },
      { fetch: fakeFetch, env: { CMUX_VM_ANALYTICS_FORCE: "1" } },
    );
    return body;
  }

  test("the machine id comes from the URL of per-machine routes only", () => {
    const perMachine = new Request("https://cmux.test/api/vm/noble-wren/exec");
    expect(vmIdFromRequestPath(perMachine, "/api/vm/[id]/exec")).toBe("noble-wren");
    expect(vmIdFromRequestPath(new Request("https://cmux.test/api/vm/base/open"), "/api/vm/base/open")).toBeUndefined();
    expect(vmIdFromRequestPath(new Request("https://cmux.test/api/vm"), "/api/vm")).toBeUndefined();
    expect(vmIdFromRequestPath(new Request("https://cmux.test/api/vm/%3Cscript%3E/exec"), "/api/vm/[id]/exec")).toBeUndefined();
  });

  test("billing annotation lands on the active request context and the PostHog row", () => {
    const ctx = context();
    const body = runWithVmRequestContext(ctx, () => {
      annotateVmRequestBilling({ billingTeamId: "team-1", billingCustomerType: "team", planId: "Pro" });
      return capture({ ...ctx, vmId: "noble-wren" }, new Response("{}", { status: 200 }));
    });
    expect(ctx.planId).toBe("pro");
    expect(ctx.billingTeamId).toBe("team-1");
    expect(body!.batch[0].event).toBe("cloud_vm_request");
    expect(body!.batch[0].properties).toMatchObject({
      operation: "exec",
      vm_id: "noble-wren",
      plan_id: "pro",
      billing_customer_type: "team",
      billing_team_id: "team-1",
      $groups: { stack_team: "team-1" },
      schema_version: VM_REQUEST_POSTHOG_SCHEMA_VERSION,
    });
  });

  test("billing annotation clears a prior scope when the resolved scope has no team or plan", () => {
    const ctx = context({ billingTeamId: "old-team", billingCustomerType: "team", planId: "pro" });
    runWithVmRequestContext(ctx, () => {
      annotateVmRequestBilling({ billingTeamId: null, billingCustomerType: "user", planId: null });
    });
    expect(ctx.billingTeamId).toBeUndefined();
    expect(ctx.billingCustomerType).toBe("user");
    expect(ctx.planId).toBeUndefined();
  });

  test("annotation outside a request context is a no-op", () => {
    expect(() => annotateVmRequestBilling({ planId: "pro" })).not.toThrow();
  });

  test("polled operations, including remote-enrollment approval, stay out of PostHog on success", () => {
    expect(isPolledVmOperation("approve_cmux_remote_enrollment")).toBe(true);
    expect(isPolledVmOperation("exec")).toBe(false);
    const polled = capture(context({ operation: "approve_cmux_remote_enrollment" }), new Response("{}", { status: 200 }));
    expect(polled).toBeNull();
    const failed = capture(context({ operation: "approve_cmux_remote_enrollment" }), new Response("{}", { status: 500 }));
    expect(failed!.batch[0].event).toBe("cloud_vm_request");
  });
});
