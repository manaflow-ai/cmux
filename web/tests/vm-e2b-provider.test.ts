import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { E2BProvider } from "../services/vms/drivers/e2b";
import { ProviderError } from "../services/vms/drivers/types";

// E2B machines attach exclusively through the cmux-tui remote daemon
// (transport cmux-remote), same as Blaxel. The legacy websocket PTY and SSH
// surfaces must refuse loudly so callers migrate instead of hanging.

describe("E2BProvider session transports", () => {
  test("cmux-remote is the only attach transport", () => {
    const provider = new E2BProvider();
    expect(provider.attachTransports).toEqual(["cmux-remote"]);
    expect(typeof provider.openCmuxRemote).toBe("function");
    expect(typeof provider.approveCmuxRemoteEnrollment).toBe("function");
  });

  test("legacy openAttach is unsupported and names the replacement", async () => {
    const provider = new E2BProvider();

    await expect(provider.openAttach("sandbox-1")).rejects.toThrow(ProviderError);
    await expect(provider.openAttach("sandbox-1")).rejects.toThrow("cmux-remote");
  });

  test("openSSH is unsupported and points at the cmux-tui daemon", async () => {
    const provider = new E2BProvider();

    await expect(provider.openSSH("sandbox-1")).rejects.toThrow(ProviderError);
    await expect(provider.openSSH("sandbox-1")).rejects.toThrow("cmux-tui");
  });

  test("revokeSSHIdentity is a safe no-op", async () => {
    const provider = new E2BProvider();

    await expect(provider.revokeSSHIdentity("anything")).resolves.toBeUndefined();
    await expect(provider.revokeSSHIdentity("")).resolves.toBeUndefined();
  });
});

describe("E2BProvider cmux-remote route", () => {
  test("sandboxes allow public port traffic because the proxy auth is header-only", () => {
    // The E2B proxy authenticates with the e2b-traffic-access-token HEADER,
    // which the cmux-tui dialer cannot send (it dials the route verbatim).
    // Sandboxes are therefore created with public port traffic and the
    // daemon's Noise device enrollment gates sessions — the same trust model
    // as Blaxel's raw preview route.
    const driver = readFileSync(
      path.join(import.meta.dirname, "../services/vms/drivers/e2b.ts"),
      "utf8",
    );
    expect(driver).toContain("network: { allowPublicTraffic: true }");
    expect(driver).not.toContain("network: { allowPublicTraffic: false }");
    expect(driver).toContain("/v1/link");
    expect(driver).toContain("getHost(CMUX_TUI_PORT)");
  });
});
