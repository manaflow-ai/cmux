import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { GUEST_CMUX_SHIM } from "../services/vms/guestCli";

describe("browser opener installation on an already healthy Cloud attach", () => {
  function fixture(browserReady: boolean) {
    const commands: string[] = [];
    const writes: string[] = [];
    const vm = {
      data: async () => ({ vpcs: [{ ipv4: "10.4.0.7", ipv6: "fd00:4::7" }] }),
      fs: {
        writeTextFile: async (_path: string, content: string) => { writes.push(content); },
        remove: async () => {},
      },
      exec: async ({ command }: { command: string }) => {
        commands.push(command);
        if (command.includes("__CMUX_PROBE__")) {
          return {
            statusCode: 0,
            stdout: ["__CMUX_PROBE__", JSON.stringify({ build_identity: "abc", remote_protocol: 12, version: "0.1.0" }),
              "__CMUX_DEVICES__", "[]", "__CMUX_TRUSTED__", "1", "__CMUX_END__"].join("\n"),
            stderr: "",
          };
        }
        const readinessProbe = command.includes("browser-opener-version") && !command.includes("mktemp");
        return { statusCode: readinessProbe && !browserReady ? 1 : 0, stdout: "", stderr: "" };
      },
    };
    const client = { vms: { ref: () => vm } } as unknown as Freestyle;
    const provider = new FreestyleProvider({ client: () => client, resolveDaemonSource: async () => {
      throw new Error("A healthy attach must not replace the running daemon");
    } });
    return { provider, commands, writes };
  }

  test("installs missing browser integration before returning an existing terminal's route", async () => {
    const { provider, commands, writes } = fixture(false);
    const result = await provider.openCmuxRemote("vm-browser-attach", { clientCapabilities: [] });
    expect(result.trustedCarrier).toBe(true);
    expect(writes).toEqual([GUEST_CMUX_SHIM]);
    expect(commands.some((command) => command.includes("mktemp") && command.includes("cmux-open-url"))).toBe(true);
    expect(commands.some((command) => command.includes("systemctl restart cmux-tui-daemon"))).toBe(false);
  });

  test("checks installed browser integration without rewriting it or restarting the daemon", async () => {
    const { provider, commands, writes } = fixture(true);
    await provider.openCmuxRemote("vm-browser-attach", { clientCapabilities: [] });
    expect(commands.some((command) => command.includes("browser-opener-version"))).toBe(true);
    expect(writes).toEqual([]);
    expect(commands.some((command) => command.includes("systemctl restart cmux-tui-daemon"))).toBe(false);
  });
});
