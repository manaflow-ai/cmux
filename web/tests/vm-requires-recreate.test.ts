import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";

import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { VmProviderOperationError } from "../services/vms/errors";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";

const VM_ID = "vm-legacy-snapshot-v1";

async function legacyAttachResponse(providerMetadata: Record<string, unknown>): Promise<Response> {
  const client = { vms: { ref: () => ({}) } } as unknown as Freestyle;
  const provider = new FreestyleProvider({ client: () => client });
  let cause: unknown;
  try {
    await provider.openCmuxRemote(VM_ID, { providerMetadata });
  } catch (error) {
    cause = error;
  }
  if (!cause) throw new Error("a legacy row must not produce an attach endpoint");
  const response = await vmWorkflowErrorResponse(new VmProviderOperationError({
    provider: "freestyle",
    operation: "openCmuxRemote",
    cause,
  }));
  if (!response) throw new Error("the provider failure must map to an HTTP response");
  return response;
}

describe("legacy snapshot-v2 attach contract", () => {
  test("returns the permanent recreate state instead of a retryable outage", async () => {
    // Reproduction from issue #15106: the row has an address but no recorded
    // contract, so the driver refuses it before any provider request.
    const response = await legacyAttachResponse({ networkIpv4: "10.4.0.8" });

    expect(response.status).toBe(409);
    expect(response.headers.get("retry-after")).toBeNull();
    const payload = await response.json() as Record<string, unknown>;
    expect(payload).toMatchObject({
      error: "vm_requires_recreate",
      retryable: false,
      phase: "attach",
      ui: {
        severity: "error",
        retryable: false,
      },
    });
    expect(String(payload.message)).toMatch(/delete|recreate|new machine/i);
    expect(String(payload.action)).toMatch(/delete|recreate|new machine/i);
    expect(JSON.stringify(payload)).not.toMatch(/freestyle|snapshot-v2|temporarily unavailable/i);
  });
});
