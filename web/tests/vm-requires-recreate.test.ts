import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";

import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { VmProviderOperationError } from "../services/vms/errors";
import { isOperatorFaultVmError } from "../services/vms/observability";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";
import { locales } from "../i18n/routing";

const VM_ID = "vm-legacy-snapshot-v1";

async function legacyAttachResponse(providerMetadata: Record<string, unknown>, locale?: (typeof locales)[number]): Promise<Response> {
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
  }), locale ? { locale } : undefined);
  if (!response) throw new Error("the provider failure must map to an HTTP response");
  return response;
}

describe("legacy snapshot-v2 attach contract", () => {
  for (const [name, providerMetadata] of [
    ["without the snapshot-v2 contract", { networkIpv4: "10.4.0.8" }],
    ["without recorded addresses", { cmuxTuiContract: "snapshot-v2" }],
    ["with no metadata", {}],
  ] as const) {
    test(`a row ${name} returns the permanent recreate state`, async () => {
      // Reproduction from issue #15106: the row has an address but no recorded
      // contract, so the driver refuses it before any provider request.
      const response = await legacyAttachResponse(providerMetadata);

      expect(response.status).toBe(409);
      expect(response.headers.get("retry-after")).toBeNull();
      const payload = await response.json() as Record<string, unknown>;
      expect(payload).toMatchObject({
        error: "vm_requires_recreate",
        retryable: false,
        phase: "attach",
        details: { operation: "openCmuxRemote", requiresRecreate: true, retryable: false },
        ui: {
          severity: "error",
          retryable: false,
        },
      });
      expect(String(payload.message)).toMatch(/delete|recreate|new machine/i);
      expect(String(payload.action)).toMatch(/delete|recreate|new machine/i);
      expect(JSON.stringify(payload)).not.toMatch(/freestyle|snapshot-v2|temporarily unavailable/i);
      expect(isOperatorFaultVmError({ error: "vm_requires_recreate", status: response.status })).toBe(false);
    });
  }

  test("uses localized actionable copy", async () => {
    const response = await legacyAttachResponse({}, "ja");
    const payload = await response.json() as Record<string, unknown>;
    expect(payload.error).toBe("vm_requires_recreate");
    expect(String(payload.message)).toMatch(/[\u3040-\u30ff]/);
    expect(String(payload.action)).toMatch(/[\u3040-\u30ff]/);
  });

  test("provides copy for every supported locale", async () => {
    const provider = new FreestyleProvider({ client: () => ({ vms: { ref: () => ({}) } } as unknown as Freestyle) });
    let cause: unknown;
    try {
      await provider.openCmuxRemote(VM_ID, { providerMetadata: {} });
    } catch (error) {
      cause = error;
    }
    for (const locale of locales) {
      const response = await vmWorkflowErrorResponse(new VmProviderOperationError({
        provider: "freestyle",
        operation: "openCmuxRemote",
        cause,
      }), { locale });
      const payload = await response!.json() as Record<string, unknown>;
      expect(payload.error).toBe("vm_requires_recreate");
      expect(String(payload.ui && (payload.ui as Record<string, unknown>).title)).not.toContain("vmErrors");
      expect(String(payload.action).length).toBeGreaterThan(0);
    }
  });

  test("an unrelated provider failure remains a retryable attach outage", async () => {
    const response = await vmWorkflowErrorResponse(new VmProviderOperationError({
      provider: "freestyle",
      operation: "openCmuxRemote",
      cause: new Error("socket hang up"),
    }));
    const payload = await response!.json() as { error: string; retryable: boolean };
    expect(response!.status).toBe(502);
    expect(payload).toMatchObject({ error: "vm_cloud_service_unavailable", retryable: true });
  });
});
