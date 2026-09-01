import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { DaytonaProvider } from "../services/vms/drivers/daytona";
import { ProviderError } from "../services/vms/drivers/types";

// Daytona machines attach exclusively through the cmux-tui remote daemon
// (transport cmux-remote), same as Blaxel. The legacy websocket PTY and SSH
// surfaces must refuse loudly so callers migrate instead of hanging.

describe("DaytonaProvider session transports", () => {
  test("cmux-remote is the only attach transport", () => {
    const provider = new DaytonaProvider();
    expect(provider.attachTransports).toEqual(["cmux-remote"]);
    expect(typeof provider.openCmuxRemote).toBe("function");
    expect(typeof provider.approveCmuxRemoteEnrollment).toBe("function");
  });

  test("legacy openAttach is unsupported and names the replacement", async () => {
    const provider = new DaytonaProvider();

    await expect(provider.openAttach("sandbox-1")).rejects.toThrow(ProviderError);
    await expect(provider.openAttach("sandbox-1")).rejects.toThrow("cmux-remote");
  });

  test("openSSH is unsupported and points at the cmux-tui daemon", async () => {
    const provider = new DaytonaProvider();

    await expect(provider.openSSH("sandbox-1")).rejects.toThrow(ProviderError);
    await expect(provider.openSSH("sandbox-1")).rejects.toThrow("cmux-tui");
  });

  test("revokeSSHIdentity is a safe no-op", async () => {
    const provider = new DaytonaProvider();

    await expect(provider.revokeSSHIdentity("anything")).resolves.toBeUndefined();
    await expect(provider.revokeSSHIdentity("")).resolves.toBeUndefined();
  });
});

describe("DaytonaProvider cmux-remote route", () => {
  test("the route carries the preview token as the URL query the proxy accepts", () => {
    // The cmux-tui dialer connects to the route verbatim (it can add no
    // headers), so the Daytona ingress token must ride the query string.
    // DAYTONA_SANDBOX_AUTH_KEY is the parameter the Daytona proxy reads (the
    // Daytona SDK dials its own WebSockets the same way).
    const driver = readDriverSource();
    expect(driver).toContain("DAYTONA_SANDBOX_AUTH_KEY=${encodeURIComponent(token)}");
    expect(driver).toContain("/v1/link?DAYTONA_SANDBOX_AUTH_KEY=");
  });

  test("the entrypoint supervisor is the restart story across stop/start", () => {
    const driver = readDriverSource();
    expect(driver).toContain('"/usr/local/bin/cmux-devbox-boot"');
    expect(driver).toContain("pgrep -f 'cmux-tui server start'");
  });
});

function readDriverSource(): string {
  return readFileSync(path.join(import.meta.dirname, "../services/vms/drivers/daytona.ts"), "utf8");
}
