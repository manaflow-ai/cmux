import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import {
  GUEST_KEY_CLEANUP_AWK,
  SHELL_KEY_LIVE_MAX,
  SHELL_KEY_TTL_SECONDS,
  shellKeyCapCheck,
  sshKeyFingerprint,
  shellAuthorizedKeyLine,
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

  test("cleanup removes only expired cmux-scp and cmux-shell keys", () => {
    const dir = mkdtempSync(join(tmpdir(), "cmux-shell-keys-"));
    const file = join(dir, "authorized_keys");
    writeFileSync(file, [
      "ssh-ed25519 AAAAuser user@laptop",
      "restrict ssh-ed25519 AAAAold cmux-scp:900",
      "restrict ssh-ed25519 AAAAlive cmux-scp:2000",
      "restrict,pty ssh-ed25519 AAAAold cmux-shell:999",
      "restrict,pty ssh-ed25519 AAAAlive cmux-shell:1001",
      "ssh-ed25519 AAAAother cmux-scp:not-a-time",
      "ssh-ed25519 AAAAprovider cmux-other:10",
    ].join("\n") + "\n");
    const run = spawnSync("awk", ["-v", "now=1000", GUEST_KEY_CLEANUP_AWK, file], { encoding: "utf8" });
    expect(run.status).toBe(0);
    expect(run.stdout.trim().split("\n")).toEqual([
      "ssh-ed25519 AAAAuser user@laptop",
      "restrict ssh-ed25519 AAAAlive cmux-scp:2000",
      "restrict,pty ssh-ed25519 AAAAlive cmux-shell:1001",
      "ssh-ed25519 AAAAother cmux-scp:not-a-time",
      "ssh-ed25519 AAAAprovider cmux-other:10",
    ]);
    expect(readFileSync(file, "utf8")).toContain("AAAAold");
  });

  test("a machine refuses another shell key while too many are live", () => {
    const dir = mkdtempSync(join(tmpdir(), "cmux-shell-cap-"));
    const file = join(dir, "keys");
    const live = (count: number) => Array.from({ length: count }, (_, i) => `restrict,pty ssh-ed25519 AAAA${i} cmux-shell:${2_000_000_000 + i}`).join("\n") + "\n";
    writeFileSync(file, live(SHELL_KEY_LIVE_MAX - 1) + "ssh-ed25519 AAAAuser cmux-scp:2000000000\n");
    expect(spawnSync("sh", ["-c", shellKeyCapCheck(`'${file}'`)]).status).toBe(0);
    writeFileSync(file, live(SHELL_KEY_LIVE_MAX));
    expect(spawnSync("sh", ["-c", shellKeyCapCheck(`'${file}'`)]).status).not.toBe(0);
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
    const endpoint = await provider.prepareShell(vmId, key, new Date((before + SHELL_KEY_TTL_SECONDS) * 1000));
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
    await expect(provider.prepareShell(vmId, key, new Date(Date.now() + 300_000))).rejects.toThrow("private network");
    expect(execs).toBe(0);
  });
});
