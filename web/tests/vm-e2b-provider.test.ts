import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { E2BProvider, ENVD_CONTROL_PORT, INBOUND_FIREWALL_COMMAND } from "../services/vms/drivers/e2b";
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

describe("E2BProvider inbound firewall", () => {
  test("closes every port except cmux-tui and envd, and keeps envd reachable", () => {
    // allowPublicTraffic exposes every listener at <port>-<id>.e2b.app, so the
    // driver applies a default-deny INPUT that allows only lo, established,
    // icmp, envd (49983), and the cmux-tui daemon (1337). envd MUST stay open
    // or the SDK's commands.run/attach break (they reach envd through the same
    // proxy). Verified live 2026-08-28 by verify-devbox-image.ts.
    expect(ENVD_CONTROL_PORT).toBe(49983);
    const cmd = INBOUND_FIREWALL_COMMAND;
    expect(cmd).toContain("--dport 49983 -j ACCEPT");
    expect(cmd).toContain("--dport 1337 -j ACCEPT");
    expect(cmd).toContain("-i lo -j ACCEPT");
    expect(cmd).toContain("ESTABLISHED,RELATED -j ACCEPT");
    expect(cmd).toContain("-A CMUX_FW -j DROP");
    // Reversible + idempotent: a dedicated chain hooked into INPUT only once.
    expect(cmd).toContain("iptables -w -C INPUT -j CMUX_FW 2>/dev/null || iptables -w -I INPUT 1 -j CMUX_FW");
    // Applied on create and re-asserted on the attach/restore heal path.
    const driver = readFileSync(
      path.join(import.meta.dirname, "../services/vms/drivers/e2b.ts"),
      "utf8",
    );
    expect(driver.match(/applyInboundFirewall\(sandbox\)/g)?.length).toBeGreaterThanOrEqual(2);
    // Best-effort: a firewall failure is logged, never thrown (must not brick a
    // machine whose daemon is already up).
    expect(driver).toContain("did not apply cleanly");
  });
});
