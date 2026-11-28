import { describe, expect, test } from "bun:test";
import { FreestyleApiError, type Freestyle } from "freestyle";

import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { VmProviderOperationError } from "../services/vms/errors";
import { isOperatorFaultVmError } from "../services/vms/observability";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";

// Production 2026-10-13 15:00-18:00 UTC: Freestyle answered machine creates
// with 409 CONFLICT "no manager has enough capacity for vm" (and 409
// PLACEMENT_REJECTED) within ~60 ms, and 4 of 11 creates answered a generic
// 502 vm_cloud_service_unavailable. The week before, 409 VM-state answers on
// exec, resume and network updates ("vm … is still starting", "is not
// running") were also answered as that operator 502. A capacity refusal is a
// retryable 503 that says capacity; a state conflict is a 409 with a user
// action; neither is a generic outage.

async function failure(run: () => Promise<unknown>): Promise<unknown> {
  try {
    await run();
  } catch (error) {
    return error;
  }
  throw new Error("expected the provider call to fail");
}

async function answer(operation: string, cause: unknown) {
  const response = await vmWorkflowErrorResponse(new VmProviderOperationError({ provider: "freestyle", operation, cause }));
  expect(response).not.toBeNull();
  const payload = await response!.json() as Record<string, unknown>;
  return { response: response!, payload };
}

const capacity = () => new FreestyleApiError(409, { code: "CONFLICT", message: "conflict: no manager has enough capacity for vm" });
const placementRejected = () => new FreestyleApiError(409, { code: "PLACEMENT_REJECTED", message: "placement rejected" });
const stillStarting = () => new FreestyleApiError(409, { code: "CONFLICT", message: "conflict: vm vm-1 is still starting" });
const notRunning = () => new FreestyleApiError(409, { code: "CONFLICT", message: "conflict: vm vm-1 is not running" });
const nonResponsive = () => new FreestyleApiError(409, { code: "VM_NON_RESPONSIVE", message: "vm vm-1 did not respond" });

function providerWith(vms: Record<string, unknown>): FreestyleProvider {
  const client = { vms: { ...vms, ref: () => vms } } as unknown as Freestyle;
  return new FreestyleProvider({ client: () => client });
}

describe("a provider capacity refusal", () => {
  const refusals: Array<[string, () => FreestyleApiError]> = [
    ["409 CONFLICT naming capacity", capacity],
    ["409 PLACEMENT_REJECTED", placementRejected],
  ];
  test.each(refusals)("a create refused with %s answers a retryable 503 that says capacity", async (_label, refusal) => {
    const provider = providerWith({ create: async () => { throw refusal(); } });
    const cause = await failure(() => provider.create({ image: "snapshot" }));
    const { response, payload } = await answer("create", cause);
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("30");
    expect(payload).toMatchObject({ error: "vm_provider_capacity", retryable: true, phase: "create" });
    expect(String(payload.message)).toMatch(/capacity/i);
    expect(JSON.stringify(payload)).not.toMatch(/temporarily unavailable/i);
    // One full region is not an incident to page on; its rate is alerted.
    expect(isOperatorFaultVmError({ error: String(payload.error), status: response.status })).toBe(false);
  });
});

describe("a machine-state conflict", () => {
  test("an exec on a machine that is still starting answers 409 with a wait-and-retry action", async () => {
    const provider = providerWith({ exec: async () => { throw stillStarting(); } });
    const cause = await failure(() => provider.exec("vm-1", "true", { timeoutMs: 1_000 }));
    const { response, payload } = await answer("exec", cause);
    expect(response.status).toBe(409);
    expect(payload).toMatchObject({ error: "vm_state_conflict", retryable: true });
    expect(String(payload.action)).toContain("cmux vm ls");
    expect(isOperatorFaultVmError({ error: String(payload.error), status: response.status })).toBe(false);
  });

  test("a resume of a machine the provider reports not running answers 409", async () => {
    const provider = providerWith({ start: async () => { throw notRunning(); } });
    const cause = await failure(() => provider.resume("vm-1"));
    const { response, payload } = await answer("resume", cause);
    expect(response.status).toBe(409);
    expect(payload).toMatchObject({ error: "vm_state_conflict" });
  });

  test("a machine that does not respond preserves its state and offers support, not an unsupported recovery", async () => {
    const provider = providerWith({ exec: async () => { throw nonResponsive(); } });
    const cause = await failure(() => provider.exec("vm-1", "true", { timeoutMs: 1_000 }));
    const { response, payload } = await answer("exec", cause);
    expect(response.status).toBe(503);
    expect(payload).toMatchObject({ error: "vm_guest_unresponsive", retryable: false });
    expect(String(payload.action)).toMatch(/contact support/i);
    expect(String(payload.action)).toMatch(/trace ID/i);
    expect(String(payload.action)).not.toMatch(/cmux vm (?:pause|resume|restart|rm)/);
  });
});

describe("other provider failures keep their answers", () => {
  test("a 500 is still the retryable Cloud service outage", async () => {
    const provider = providerWith({ create: async () => { throw new FreestyleApiError(500, { code: "INTERNAL_ERROR", message: "boom" }); } });
    const cause = await failure(() => provider.create({ image: "snapshot" }));
    const { response, payload } = await answer("create", cause);
    expect(response.status).toBe(502);
    expect(payload.error).toBe("vm_cloud_service_unavailable");
  });

  test("a 409 about another resource is neither capacity nor a machine-state conflict", async () => {
    const provider = providerWith({ exec: async () => { throw new FreestyleApiError(409, { code: "CONFLICT", message: "conflict: network policy for vpc-1 changed concurrently" }); } });
    const cause = await failure(() => provider.exec("vm-1", "true", { timeoutMs: 1_000 }));
    const { response, payload } = await answer("exec", cause);
    expect(response.status).toBe(502);
    expect(payload.error).toBe("vm_cloud_service_unavailable");
  });

  test("a full private network is still the network-full refusal, not capacity", async () => {
    const provider = providerWith({ create: async () => { throw new FreestyleApiError(409, { code: "CONFLICT", message: "conflict: vpc vpc-1 has no free addresses in 10.40.0.0/24" }); } });
    const cause = await failure(() => provider.create({ image: "snapshot", network: { id: "vpc-1" } }));
    const { response, payload } = await answer("create", cause);
    expect(response.status).toBe(409);
    expect(payload.error).toBe("vm_network_full");
  });
});
