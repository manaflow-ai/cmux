import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";

import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { VmProviderOperationError } from "../services/vms/errors";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";
import { locales } from "../i18n/routing";

/** The driver's real refusal for a machine created before the attach contract. */
async function preContractAttachRefusal(
  providerMetadata: Record<string, unknown> = { networkIpv4: "10.4.0.8" },
): Promise<unknown> {
  const client = { vms: { ref: () => ({}) } } as unknown as Freestyle;
  const provider = new FreestyleProvider({ client: () => client });
  try {
    await provider.openCmuxRemote("vm-pre-contract", { providerMetadata });
  } catch (error) {
    return error;
  }
  throw new Error("expected the driver to refuse a pre-contract machine");
}

async function attachResponse(locale?: (typeof locales)[number]): Promise<Response> {
  const response = await vmWorkflowErrorResponse(
    new VmProviderOperationError({
      provider: "freestyle",
      operation: "openCmuxRemote",
      cause: await preContractAttachRefusal(),
    }),
    locale ? { locale } : {},
  );
  expect(response).not.toBeNull();
  return response!;
}

// A machine created before the attach contract can never be attached: nothing
// on the server changes that, so a retryable 502 kept every client polling a
// machine that will not answer. docs/cloud-guest-upgrades.md: a permanent
// refusal is non-retryable, with a stable code and a recreate action.
describe("attach to a machine that predates the attach contract", () => {
  test("is a permanent refusal that tells the user to recreate the machine", async () => {
    const response = await attachResponse();
    expect(response.status).toBe(409);
    expect(response.headers.get("retry-after")).toBeNull();
    const payload = await response.json() as Record<string, unknown>;
    expect(payload).toMatchObject({
      error: "vm_recreate_required",
      retryable: false,
      phase: "attach",
      details: { operation: "openCmuxRemote", retryable: false },
      ui: { title: "Recreate this machine" },
    });
    expect(JSON.stringify(payload)).not.toMatch(/snapshot-v2|freestyle|10\.4\.0\.8/);
  });

  test("refuses a contracted machine with no recorded address", async () => {
    const client = { vms: { ref: () => ({}) } } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });
    let cause: unknown;
    try {
      await provider.openCmuxRemote("vm-pre-contract", { providerMetadata: { cmuxTuiContract: "snapshot-v2" } });
    } catch (error) {
      cause = error;
    }
    expect(cause).toBeDefined();
    const response = await vmWorkflowErrorResponse(new VmProviderOperationError({ provider: "freestyle", operation: "openCmuxRemote", cause }));
    expect(response?.status).toBe(409);
    expect((await response?.json()).error).toBe("vm_recreate_required");
  });

  test("is localized for every locale", async () => {
    const english = await (await attachResponse("en")).json() as { message: string; action: string };
    for (const locale of locales) {
      const payload = await (await attachResponse(locale)).json() as { message: string; action: string };
      expect(payload.message.length).toBeGreaterThan(0);
      expect(payload.action.length).toBeGreaterThan(0);
      if (locale !== "en") expect(payload.message).not.toBe(english.message);
    }
  });
});
