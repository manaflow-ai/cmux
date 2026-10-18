import { describe, expect, test } from "bun:test";
import { HugeBlueProvider } from "../services/vms/drivers/hugeBlue";

const env = {
  HUGE_BLUE_SSH_HOST: "100.81.77.9",
  HUGE_BLUE_SSH_USER: "leo",
  HUGE_BLUE_SSH_KEY: "/run/secrets/huge-blue-key",
  HUGE_BLUE_SSH_PROXY_COMMAND: "/usr/local/bin/tailscale-manaflow nc %h %p",
  HUGE_BLUE_VM_ID: "huge-blue-staging",
  HUGE_BLUE_CMUX_REMOTE_URL: "wss://huge-blue.example/v1/link",
  HUGE_BLUE_CMUX_REMOTE_TOKEN: "staging-token",
};

describe("Huge Blue provider", () => {
  test("creates a logical shared-host handle and executes over injected SSH", async () => {
    const calls: unknown[] = [];
    const provider = new HugeBlueProvider({
      env,
      run: async (input) => {
        calls.push(input);
        return { exitCode: 0, stdout: "ok", stderr: "" };
      },
    });
    const handle = await provider.create({ image: "huge-blue-host" });
    expect(handle.providerVmId).toBe("huge-blue-staging");
    expect(handle.status).toBe("running");
    expect(await provider.exec(handle.providerVmId, "printf ok")).toEqual({ exitCode: 0, stdout: "ok", stderr: "" });
    expect(calls).toHaveLength(1);
    expect((calls[0] as { host: string; options: { proxyCommand?: string } }).host).toBe("100.81.77.9");
    expect((calls[0] as { host: string; options: { proxyCommand?: string } }).options.proxyCommand).toContain("tailscale-manaflow");
  });

  test("refuses destructive shared-host operations", async () => {
    const provider = new HugeBlueProvider({ env, run: async () => ({ exitCode: 0, stdout: "", stderr: "" }) });
    await expect(provider.destroy("huge-blue-staging")).rejects.toThrow("shared host");
    await expect(provider.snapshot("huge-blue-staging")).rejects.toThrow("not supported");
  });

  test("returns configured trusted cmux remote endpoint", async () => {
    const provider = new HugeBlueProvider({ env });
    await expect(provider.openCmuxRemote("huge-blue-staging")).resolves.toMatchObject({
      transport: "cmux-remote",
      route: "wss://huge-blue.example/v1/link",
      token: "staging-token",
      trustedCarrier: true,
    });
  });
});
