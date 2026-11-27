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

// Production 2026-11 (https://github.com/manaflow-ai/cmux/issues/39766):
// Freestyle answered pause and exec with 429 TOO_MANY_REQUESTS in ~0.2 s and
// resume with 429 INFRASTRUCTURE_OVERLOADED after ~130 s, and each was
// answered as the operator-fault 502. A 429 is the provider asking us to come
// back later: the same retryable capacity 503 as a 409 placement refusal.
describe("a provider rate limit or overload", () => {
  const tooManyRequests = () => new FreestyleApiError(429, { code: "TOO_MANY_REQUESTS", message: "too many requests" });
  const overloaded = () => new FreestyleApiError(429, { code: "INFRASTRUCTURE_OVERLOADED", message: "infrastructure overloaded: VM start capacity queue wait expired" });
  const cases: Array<[string, string, Record<string, unknown>, (provider: FreestyleProvider) => Promise<unknown>]> = [
    ["pause", "429 TOO_MANY_REQUESTS", { pause: async () => { throw tooManyRequests(); } }, (provider) => provider.pause("vm-1")],
    ["exec", "429 TOO_MANY_REQUESTS", { exec: async () => { throw tooManyRequests(); } }, (provider) => provider.exec("vm-1", "true", { timeoutMs: 1_000 })],
    ["resume", "429 INFRASTRUCTURE_OVERLOADED", { start: async () => { throw overloaded(); } }, (provider) => provider.resume("vm-1")],
  ];
  test.each(cases)("a %s refused with %s answers the retryable capacity 503", async (operation, _label, vms, run) => {
    const cause = await failure(() => run(providerWith(vms)));
    const { response, payload } = await answer(operation, cause);
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("30");
    expect(payload).toMatchObject({ error: "vm_provider_capacity", retryable: true });
    expect(isOperatorFaultVmError({ error: String(payload.error), status: response.status })).toBe(false);
  });
});

// Production 2026-11-27: Freestyle answered `POST /v5/vms/<id>/start` with
// 409 CONFLICT "start did not complete successfully (current state: Stopped)"
// (or "Paused") on 10 machines, in the same minutes as PLACEMENT_REJECTED
// "memory headroom exhausted" and 429 INFRASTRUCTURE_OVERLOADED for the same
// machines. Freestyle documents start's 409 as "no capacity is available"
// (the other case, an ephemeral machine deleted at shutdown, answers not
// found). Each was answered as the generic 502 "temporarily unavailable"
// with the provider's "conflict" text, and the Mac app retried one 32 vCPU
// machine's resume every ~2 minutes for over 3 hours. Nothing was lost: the
// machine and its disk are where they were, and the same resume can succeed
// once the provider has room.
describe("a start the provider could not complete", () => {
  const startDidNotComplete = (state: string) => () => new FreestyleApiError(409, {
    code: "CONFLICT",
    message: `conflict: vm vm-1 start did not complete successfully (current state: ${state})`,
  });
  const refusals: Array<[string, () => FreestyleApiError]> = [
    ["the machine stayed stopped", startDidNotComplete("Stopped")],
    ["the machine stayed paused", startDidNotComplete("Paused")],
  ];
  test.each(refusals)("a resume refused because %s answers the retryable capacity 503", async (_label, refusal) => {
    const provider = providerWith({ start: async () => { throw refusal(); } });
    const cause = await failure(() => provider.resume("vm-1"));
    const { response, payload } = await answer("resume", cause);
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("30");
    expect(payload).toMatchObject({ error: "vm_provider_capacity", retryable: true, phase: "resume" });
    expect(JSON.stringify(payload)).not.toMatch(/temporarily unavailable|conflict:/i);
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

// Production 2026-11-16 (https://github.com/manaflow-ai/cmux/issues/44783):
// a Freestyle host went down and every machine whose retained disk head lived
// on it was refused with 409 CONFLICT naming the disk head or a recovery
// hold. Resume, exec and attach answered the generic 502 "temporarily
// unavailable, retrying is safe", so clients retried every minute for hours
// against a refusal only the provider's host recovery could lift.
const diskHeadMustBeRecovered = () => new FreestyleApiError(409, {
  code: "CONFLICT",
  message: "conflict: cannot start vm vm-1: its retained disk head must be recovered on vms10-as1010",
});
const diskHeadOwnerUnreachable = () => new FreestyleApiError(409, {
  code: "CONFLICT",
  message: "conflict: cannot start vm vm-1: disk head owner vms10-as1010 is not reachable",
});
const recoveryHold = () => new FreestyleApiError(409, {
  code: "CONFLICT",
  message: "conflict: VM has recovery hold 66b4699d-096b-499a-b1dd-b518f8839e3b: Bounded admission hold to drain repeated failed starts before guarded original-running metadata repair",
});

describe("a machine whose disk is held by a host being recovered", () => {
  const refusals: Array<[string, () => FreestyleApiError]> = [
    ["its retained disk head must be recovered", diskHeadMustBeRecovered],
    ["its disk head owner is not reachable", diskHeadOwnerUnreachable],
    ["the provider holds it for recovery", recoveryHold],
  ];
  test.each(refusals)("a resume refused because %s answers host recovery, not a retry-now outage", async (_label, refusal) => {
    const provider = providerWith({ start: async () => { throw refusal(); } });
    const cause = await failure(() => provider.resume("vm-1"));
    const { response, payload } = await answer("resume", cause);
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("300");
    expect(payload).toMatchObject({ error: "vm_host_recovery_pending", retryable: true, phase: "resume" });
    expect(String(payload.message)).toMatch(/being recovered/i);
    expect(String(payload.message)).toMatch(/files are kept/i);
    expect(String(payload.action)).toMatch(/don't delete or recreate/i);
    expect(JSON.stringify(payload)).not.toMatch(/temporarily unavailable|retrying is safe/i);
    // Provider host names and hold ids stay in server traces.
    expect(JSON.stringify(payload)).not.toMatch(/vms10-as1010|66b4699d/);
    // Only the provider can recover the host, so the incident still pages.
    expect(isOperatorFaultVmError({ error: String(payload.error), status: response.status })).toBe(true);
  });

  test("an exec that has to wake the machine answers the same host recovery", async () => {
    const provider = providerWith({ exec: async () => { throw diskHeadMustBeRecovered(); } });
    const cause = await failure(() => provider.exec("vm-1", "true", { timeoutMs: 1_000 }));
    const { response, payload } = await answer("exec", cause);
    expect(response.status).toBe(503);
    expect(payload).toMatchObject({ error: "vm_host_recovery_pending" });
  });

  test("the answer is localized", async () => {
    const response = await vmWorkflowErrorResponse(
      new VmProviderOperationError({ provider: "freestyle", operation: "resume", cause: diskHeadOwnerUnreachable() }),
      { locale: "de" },
    );
    const payload = await response!.json() as Record<string, unknown>;
    expect(payload.error).toBe("vm_host_recovery_pending");
    expect(String(payload.message)).toMatch(/wiederhergestellt/);
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
