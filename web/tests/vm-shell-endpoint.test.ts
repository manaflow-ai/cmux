import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import {
  SHELL_KEY_TTL_SECONDS,
  scpAuthorizeCommand,
  sshKeyFingerprint,
  shellAuthorizedKeyLine,
  shellAuthorizeCommand,
} from "../services/vms/drivers/scp";

const blob = Buffer.concat([Buffer.from("0000000b7373682d6564323535313900000020", "hex"), Buffer.alloc(32, 9)]);
const key = `ssh-ed25519 ${blob.toString("base64")}`;
const vmId = "vm-" + "b".repeat(32);

describe("rescue shell endpoint", () => {
  test("a shell key may open one PTY and nothing else, and expires", () => {
    const line = shellAuthorizedKeyLine(key, new Date("2026-10-04T00:05:00Z"));
    expect(line).toBe(`restrict,pty,expiry-time="20261004000500Z" ${key} cmux-shell:1791072300`);
    expect(line).not.toContain("port-forwarding");
    expect(line).not.toContain("agent-forwarding");
    expect(line).not.toContain("command=");
  });

  test("shell and scp keys clean only their own expired markers", () => {
    for (const command of [shellAuthorizeCommand(key, new Date(0)), scpAuthorizeCommand(key, new Date(0))]) {
      expect(command).toContain("cmux-(scp|shell):[0-9]+");
    }
  });

  test("the audit fingerprint is the OpenSSH SHA256 form and never the key", () => {
    const fingerprint = sshKeyFingerprint(key);
    expect(fingerprint).toMatch(/^SHA256:[A-Za-z0-9+/]{43}$/);
    expect(fingerprint).not.toContain(blob.toString("base64"));
  });

  test("the endpoint pins the guest host key from the provider call and lives five minutes", async () => {
    const execs: { command: string; linuxUser?: string }[] = [];
    const client = { vms: { ref: () => ({
      data: async () => ({ vpcs: [{ ipv4: "10.4.0.9" }] }),
      exec: async (request: { command: string; linuxUser?: string }) => {
        execs.push(request);
        return { statusCode: 0, stdout: key + " guest\n", stderr: "" };
      },
    }) } } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });
    const before = Math.floor(Date.now() / 1000);
    const endpoint = await provider.prepareShell(vmId, key);
    expect(endpoint).toMatchObject({ host: "10.4.0.9", port: 22, username: "cmux", hostPublicKey: key });
    expect(endpoint.expiresAtUnix).toBeGreaterThanOrEqual(before + SHELL_KEY_TTL_SECONDS);
    expect(endpoint.expiresAtUnix).toBeLessThanOrEqual(before + SHELL_KEY_TTL_SECONDS + 5);
    expect(SHELL_KEY_TTL_SECONDS).toBe(5 * 60);
    expect(execs).toHaveLength(1);
    expect(execs[0].linuxUser).toBe("root");
    expect(execs[0].command).toContain("restrict,pty,expiry-time=");
  });

  test("refuses a machine without a private address before changing guest access", async () => {
    let execs = 0;
    const client = { vms: { ref: () => ({
      data: async () => ({ publicIpv6: "2602::1", vpcs: [] }),
      exec: async () => { execs++; return { statusCode: 0, stdout: key, stderr: "" }; },
    }) } } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client });
    await expect(provider.prepareShell(vmId, key)).rejects.toThrow("private network");
    expect(execs).toBe(0);
  });
});
