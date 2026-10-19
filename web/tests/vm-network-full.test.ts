import { describe, expect, test } from "bun:test";
import { FreestyleApiError, type Freestyle } from "freestyle";

import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { ProviderTunnelNetworkOverlapError } from "../services/vms/drivers/types";
import { VmProviderOperationError } from "../services/vms/errors";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";

const TUNNEL_CLIENT_KEY = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

/** Freestyle's answer when every address in the owner's VPC is taken. */
function networkFull(): FreestyleApiError {
  return new FreestyleApiError(409, {
    code: "CONFLICT",
    message: "conflict: vpc vpc-1 has no free addresses in 10.40.0.0/24",
  });
}

async function failure(run: () => Promise<unknown>): Promise<unknown> {
  try {
    await run();
  } catch (error) {
    return error;
  }
  throw new Error("expected the provider call to fail");
}

async function routeResponse(operation: string, cause: unknown): Promise<Response> {
  const response = await vmWorkflowErrorResponse(
    new VmProviderOperationError({ provider: "freestyle", operation, cause }),
  );
  expect(response).not.toBeNull();
  return response!;
}

// A full private network stays full until the owner frees addresses, so a
// retryable 502 kept clients retrying a create that cannot succeed. The
// answer is a permanent 409 with a stable code and a cleanup action.
describe("a private network with no free addresses", () => {
  test("machine create is a non-retryable vm_network_full refusal", async () => {
    const client = {
      vms: { create: async () => { throw networkFull(); } },
    } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });
    const cause = await failure(() => provider.create({ image: "snapshot", network: { id: "vpc-1" } }));

    const response = await routeResponse("create", cause);
    expect(response.status).toBe(409);
    expect(response.headers.get("retry-after")).toBeNull();
    const payload = await response.json() as Record<string, unknown>;
    expect(payload).toMatchObject({
      error: "vm_network_full",
      retryable: false,
      phase: "create",
      message: "This account's private network has no free addresses.",
    });
    expect(payload.retryAfterSeconds).toBeUndefined();
    expect(String(payload.action)).toContain("cmux vm rm");
    expect(JSON.stringify(payload)).not.toMatch(/retrying is safe|temporarily unavailable/i);
  });

  test("tunnel enrollment is the same refusal and skips the create-recovery read", async () => {
    let listed = 0;
    const client = {
      tunnels: {
        create: async () => { throw networkFull(); },
        list: async () => { listed += 1; return { tunnels: [], totalCount: 0 }; },
      },
    } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });
    const cause = await failure(() => provider.privateNetworking!.createTunnel({
      slug: "cmux-wg-full",
      clientPublicKey: TUNNEL_CLIENT_KEY,
      networkId: "vpc-1",
    }));
    expect(listed).toBe(0);

    const response = await routeResponse("createTunnel", cause);
    expect(response.status).toBe(409);
    expect(response.headers.get("retry-after")).toBeNull();
    expect(await response.json()).toMatchObject({
      error: "vm_network_full",
      retryable: false,
      phase: "network",
    });
  });

  test("a full team network is not reported as an overlapping network", async () => {
    const client = {
      tunnels: { attachVpc: async () => { throw networkFull(); } },
    } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });
    const cause = await failure(() => provider.privateNetworking!.attachTunnelNetwork!("tun-1", "vpc-1"));
    expect(cause).not.toBeInstanceOf(ProviderTunnelNetworkOverlapError);

    const response = await routeResponse("attachTunnelNetwork", cause);
    expect(response.status).toBe(409);
    expect((await response.json()).error).toBe("vm_network_full");
  });
});
