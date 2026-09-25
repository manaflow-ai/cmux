import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { parseSshPublicKey, scpAuthorizedKeyLine } from "../services/vms/drivers/scp";

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
