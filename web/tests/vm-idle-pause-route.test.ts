import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import type { AuthedUser } from "../services/vms/auth";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmNotFoundError } from "../services/vms/errors";
import { parseIdlePauseBody } from "../services/vms/idlePauseRoute";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";

// cmux NEXT's `cloud set-idle-pause` and `new-machine --persistent` send
// `PUT /api/vm/{id}/idle-pause` to cmux.com, which deploys from main. The route
// existed only on feat-cmux-next, so production answered 404. These tests pin
// that main serves it: Off and every timeout the app offers are stored on the
// machine (the vm-idle-pause cron honours them), and a bad body or a caller
// without access never reaches the store.
let active = false;
let authedUser: AuthedUser | null = null;
const programs: Array<Record<string, unknown>> = [];
let routeResult: { ok: true; value: Record<string, unknown> } | { ok: false; response: Response } = {
  ok: true,
  value: { providerVmId: "fs-idle", idlePauseMinutes: 0 },
};

const realAuth = await import("../services/vms/auth");
const realVerifyRequest = realAuth.verifyRequest;
const realWorkflows = await import("../services/vms/workflows");
const realSetVmIdlePause = realWorkflows.setVmIdlePause;
const realRouteWorkflow = await import("../services/vms/routeWorkflow");
const realRunVmRoute = realRouteWorkflow.runVmRoute;

mock.module("../services/vms/auth", () => ({
  ...realAuth,
  verifyRequest: ((request: Request, options?: unknown) =>
    active ? Promise.resolve(authedUser) : realVerifyRequest(request, options as never)) as typeof realVerifyRequest,
}));

mock.module("../services/vms/workflows", () => ({
  ...realWorkflows,
  setVmIdlePause: ((input: Parameters<typeof realSetVmIdlePause>[0]) => {
    if (!active) return realSetVmIdlePause(input);
    programs.push(input as Record<string, unknown>);
    return { sentinel: "idle-pause" } as unknown as ReturnType<typeof realSetVmIdlePause>;
  }) as typeof realSetVmIdlePause,
}));

mock.module("../services/vms/routeWorkflow", () => ({
  ...realRouteWorkflow,
  runVmRoute: (async (program: unknown, options?: unknown) => {
    if (!active) return realRunVmRoute(program as never, options as never);
    expect((program as { sentinel?: string }).sentinel).toBe("idle-pause");
    return routeResult;
  }) as typeof realRunVmRoute,
}));

const idlePauseRoute = await import("../app/api/vm/[id]/idle-pause/route");

const user: AuthedUser = {
  id: "user-idle-route",
  isAnonymous: false,
  displayName: "Idle User",
  primaryEmail: "idle@example.com",
  billingCustomerType: "team",
  billingTeamId: "team-idle-route",
  selectedTeamId: "team-idle-route",
  teams: [{ id: "team-idle-route", displayName: "cmux", billingPlanId: "pro", billingSeats: 3 }],
  teamIds: ["team-idle-route"],
  userBillingPlanId: null,
  billingPlanId: "pro",
  billingSeats: 3,
};

function put(body: unknown): Request {
  return new Request("https://cmux.test/api/vm/fs-idle/idle-pause", {
    method: "PUT",
    headers: {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
      "content-type": "application/json",
    },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

const params = { params: Promise.resolve({ id: "fs-idle" }) };

describe("PUT /api/vm/[id]/idle-pause", () => {
  beforeAll(() => {
    active = true;
  });

  beforeEach(() => {
    authedUser = user;
    programs.length = 0;
    routeResult = { ok: true, value: { providerVmId: "fs-idle", idlePauseMinutes: 0 } };
  });

  afterAll(() => {
    active = false;
  });

  test("Off, as the app sends it, is stored and answered", async () => {
    for (const minutes of ["off", 0]) {
      programs.length = 0;
      const response = await idlePauseRoute.PUT(put({ minutes }), params);
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ id: "fs-idle", idlePauseMinutes: 0 });
      expect(programs).toHaveLength(1);
      expect(programs[0]).toMatchObject({
        userId: user.id,
        billingTeamId: user.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: "fs-idle",
        minutes: 0,
      });
    }
  });

  test("every timeout the app offers is stored now that the idle cron honours it", async () => {
    for (const minutes of [15, 30, 60, 120]) {
      programs.length = 0;
      routeResult = { ok: true, value: { providerVmId: "fs-idle", idlePauseMinutes: minutes } };
      const response = await idlePauseRoute.PUT(put({ minutes }), params);
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ id: "fs-idle", idlePauseMinutes: minutes });
      expect(programs).toHaveLength(1);
      expect(programs[0]).toMatchObject({ providerVmId: "fs-idle", minutes });
    }
  });

  test("a bad body is a 400 that never reaches the workflow", async () => {
    for (const body of [{ minutes: 45 }, { minutes: "30" }, {}, null, [0]]) {
      const response = await idlePauseRoute.PUT(put(body), params);
      expect(response.status).toBe(400);
      expect(await response.json()).toMatchObject({ error: "invalid_idle_pause", details: { field: "minutes" } });
    }
    const notJson = await idlePauseRoute.PUT(put("{"), params);
    expect(notJson.status).toBe(400);
    expect(await notJson.json()).toMatchObject({ error: "vm_invalid_json" });
    expect(programs).toEqual([]);
  });

  test("passes through a workflow failure, such as a machine the caller cannot see", async () => {
    routeResult = {
      ok: false,
      response: new Response(JSON.stringify({ error: "vm_not_found" }), {
        status: 404,
        headers: { "content-type": "application/json" },
      }),
    };
    const response = await idlePauseRoute.PUT(put({ minutes: "off" }), params);
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "vm_not_found" });
  });

  test("returns unauthorized without invoking the workflow", async () => {
    authedUser = null;
    const response = await idlePauseRoute.PUT(put({ minutes: "off" }), params);
    expect(response.status).toBe(401);
    expect(programs).toEqual([]);
  });
});

describe("parseIdlePauseBody", () => {
  test("takes off, 0, 15, 30, 60 or 120 and refuses anything else with 400", () => {
    expect(parseIdlePauseBody({ minutes: "off" })).toEqual({ ok: true, minutes: 0 });
    expect(parseIdlePauseBody({ minutes: 0 })).toEqual({ ok: true, minutes: 0 });
    for (const minutes of [15, 30, 60, 120]) expect(parseIdlePauseBody({ minutes })).toEqual({ ok: true, minutes });
    for (const body of [{ minutes: -1 }, { minutes: "off " }, { minutes: true }, undefined]) {
      const parsed = parseIdlePauseBody(body);
      expect(parsed.ok === false && parsed.response.status).toBe(400);
    }
  });
});

describe("setVmIdlePause", () => {
  const TEAM = "team-idle";

  function row(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
    // Inside the free access window, so the access check needs no plan.
    const now = new Date();
    return {
      id: "00000000-0000-4000-8000-00000000d1e0", userId: "user-owner", billingTeamId: TEAM, billingPlanId: "pro",
      provider: "freestyle", providerVmId: "fs-idle", displayName: null, slug: null, imageId: "snapshot-test",
      imageVersion: null, status: "running", idempotencyKey: null, createdAt: now, updatedAt: now, destroyedAt: null,
      failureCode: null, failureMessage: null, providerMetadata: {}, networkPolicy: null, networkPolicyStatus: null,
      agentUpdates: null, ownerTeamId: TEAM, coderouterPoolId: null, ...overrides,
    };
  }

  function harness(vm: CloudVmRow) {
    const stored: Array<{ id: string; minutes: number }> = [];
    const repo: Partial<VmRepositoryShape> = {
      findUserVm: () => Effect.succeed(vm),
      setIdlePauseMinutes: (input) => Effect.sync(() => { stored.push({ ...input }); }),
    };
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo as VmRepositoryShape),
      Layer.succeed(VmProviderGateway, {} as VmProviderGatewayShape),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
    );
    const run = (teamIds: readonly string[]) =>
      Effect.runPromise(Effect.either(realSetVmIdlePause({
        userId: "user-caller", billingTeamId: TEAM, teamIds, providerVmId: "fs-idle", minutes: 0,
      })).pipe(Effect.provide(layer)));
    return { run, stored };
  }

  test("stores Off on the machine's row and answers it", async () => {
    const h = harness(row());
    const result = await h.run([TEAM]);
    expect(result).toMatchObject({ _tag: "Right", right: { providerVmId: "fs-idle", idlePauseMinutes: 0 } });
    expect(h.stored).toEqual([{ id: "00000000-0000-4000-8000-00000000d1e0", minutes: 0 }]);
  });

  test("a caller outside the machine's team gets not found, and nothing is stored", async () => {
    const h = harness(row());
    const result = await h.run(["team-other"]);
    expect(result._tag).toBe("Left");
    if (result._tag === "Left") expect(result.left).toBeInstanceOf(VmNotFoundError);
    expect(h.stored).toEqual([]);
  });
});
