import { describe, expect, test } from "bun:test";
import { FreestyleApiError, type Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { parseSshPublicKey, scpAuthorizedKeyLine } from "../services/vms/drivers/scp";
import { VmProviderOperationError } from "../services/vms/errors";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";

const blob = Buffer.concat([Buffer.from("0000000b7373682d6564323535313900000020", "hex"), Buffer.alloc(32, 7)]);
const key = `ssh-ed25519 ${blob.toString("base64")}`;
const vmId = "vm-" + "a".repeat(32);

describe("private SCP authentication", () => {
  test("accepts one complete Ed25519 key and removes the comment", () => {
    expect(parseSshPublicKey(key + " local-key\n")).toBe(key);
  });

  test.each(["", "ssh-rsa AAAA", "ssh-ed25519 AAAA", key + "\n" + key, key + "; touch /tmp/injected"])(
    "rejects malformed or injected key input: %s", (input) => {
      expect(() => parseSshPublicKey(input)).toThrow();
    },
  );

  test("keys expire in UTC and cannot open PTYs or forward connections", () => {
    const line = scpAuthorizedKeyLine(key, new Date("2026-09-14T00:15:00Z"));
    expect(line).toBe(`restrict,expiry-time="20260914001500Z" ${key} cmux-scp:1789344900`);
  });

  test("private endpoint uses the guest key from the authenticated provider call", async () => {
    const execs: { command: string; linuxUser?: string }[] = [];
    const client = { vms: { ref: () => ({
      data: async () => ({ vpcs: [{ ipv4: "10.4.0.7" }] }),
      exec: async (request: { command: string; linuxUser?: string }) => {
        execs.push(request);
        return { statusCode: 0, stdout: key + " guest\n", stderr: "" };
      },
    }) } } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });
    const endpoint = await provider.prepareSCP(vmId, key);
    expect(endpoint.host).toBe("10.4.0.7");
    expect(endpoint.username).toBe("cmux");
    expect(endpoint.port).toBe(22);
    expect(endpoint.hostPublicKey).toBe(key);
    expect(endpoint.expiresAtUnix).toBeGreaterThan(Date.now() / 1000 + 800);
    expect(execs).toHaveLength(1);
    expect(execs[0].linuxUser).toBe("root");
    expect(endpoint).not.toHaveProperty("credential");
    expect(endpoint).not.toHaveProperty("identityHandle");
  });

  test("refuses a machine without a private address before changing guest access", async () => {
    let execs = 0;
    const client = { vms: { ref: () => ({
      data: async () => ({ publicIpv6: "2602::1", vpcs: [] }),
      exec: async () => { execs++; return { statusCode: 0, stdout: key, stderr: "" }; },
    }) } } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });
    await expect(provider.prepareSCP(vmId, key)).rejects.toThrow("private network");
    expect(execs).toBe(0);
  });
});

// Production 2026-10-11: a guest whose provider exec channel stopped answering
// was reported as "SSH server unavailable" and a generic retryable outage. The
// SSH service was never checked: the setup command never ran or never exited.
describe("SCP setup on a machine that does not answer", () => {
  const unresponsiveProvider = (exec: () => Promise<unknown>) => {
    const client = { vms: { ref: () => ({
      data: async () => ({ vpcs: [{ ipv4: "10.4.0.7" }] }),
      exec,
    }) } } as unknown as Freestyle;
    return new FreestyleProvider({ client: () => client });
  };

  const failure = async (run: () => Promise<unknown>) => {
    try { await run(); } catch (error) { return error as Error; }
    throw new Error("expected SCP setup to fail");
  };

  const stuckExecs: [string, () => Promise<unknown>][] = [
    ["the exec poll ends in a gateway 502", async () => { throw new FreestyleApiError(502, { code: "INTERNAL_ERROR", message: "Bad Gateway" }); }],
    ["the exec poll ends in a gateway 504", async () => { throw new FreestyleApiError(504, { code: "GATEWAY_TIMEOUT", message: "Gateway Timeout" }); }],
    ["the exec request times out", async () => { throw new DOMException("The operation timed out.", "TimeoutError"); }],
    ["the guest command never exits", async () => ({ statusCode: null, stdout: "", stderr: "" })],
  ];
  test.each(stuckExecs)("names the machine as unresponsive when %s", async (_label, exec) => {
    const error = await failure(() => unresponsiveProvider(exec).prepareSCP(vmId, key));
    expect(error.name).toBe("ProviderGuestUnresponsiveError");
    expect(error.message).not.toContain("SSH server unavailable");

    const response = await vmWorkflowErrorResponse(
      new VmProviderOperationError({ provider: "freestyle", operation: "prepareSCP", cause: error }),
    );
    expect(response?.status).toBe(503);
    const payload = await response!.json() as Record<string, unknown>;
    expect(payload).toMatchObject({ error: "vm_guest_unresponsive", retryable: false });
    expect(String(payload.action)).toMatch(/contact support/i);
    expect(String(payload.action)).toMatch(/trace ID/i);
    expect(String(payload.action)).not.toMatch(/cmux vm (?:pause|resume|restart|rm)/);
    expect(JSON.stringify(payload)).not.toMatch(/temporarily unavailable/i);
  });

  // A refusal that arrives before the command could run says nothing about
  // the guest: it keeps its provider error and code.
  const earlyRefusals: [number, string, string][] = [
    [401, "UNAUTHORIZED", "invalid api key"],
    [500, "INTERNAL_ERROR", "exec dispatch failed"],
  ];
  test.each(earlyRefusals)("keeps an early %i from the exec as a provider error", async (status, code, message) => {
    const provider = unresponsiveProvider(async () => { throw new FreestyleApiError(status, { code, message }); });
    const error = await failure(() => provider.prepareSCP(vmId, key));
    expect(error.name).toBe("ProviderError");

    const response = await vmWorkflowErrorResponse(
      new VmProviderOperationError({ provider: "freestyle", operation: "prepareSCP", cause: error }),
    );
    // The same answer any other provider failure gets, as before this change.
    expect(response?.status).toBe(502);
    const payload = await response!.json() as { error: string; details?: { operation?: string } };
    expect(payload.error).toBe("vm_cloud_service_unavailable");
    expect(payload.details?.operation).toBe("prepareSCP");
    expect((error as Error & { cause?: { code?: string } }).cause?.code).toBe(code);
  });

  test("keeps the guest's own error when the setup command fails", async () => {
    const provider = unresponsiveProvider(async () => ({ statusCode: 1, stdout: "", stderr: "Failed to start ssh.service: Unit ssh.service not found.\n" }));
    const error = await failure(() => provider.prepareSCP(vmId, key));
    expect(error.name).toBe("ProviderError");
    expect(error.message).toContain("Unit ssh.service not found");
  });
});
