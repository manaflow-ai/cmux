import { describe, expect, test } from "bun:test";

import {
  FREESTYLE_ATTACH_TRANSPORT,
  freestyleCmuxRemoteRoute,
  freestyleDaemonHealthyCommand,
  freestyleFirewallRules,
  freestyleStartDaemonCommand,
} from "../services/vms/drivers/freestyle";

const VM_ID = "vm-d05087e5773e4a978036fc806b0cd759";

describe("Freestyle Cloud VM daemon contract", () => {
  test("uses the cmux-tui transport and repairs dual-stack listeners", () => {
    expect(FREESTYLE_ATTACH_TRANSPORT).toBe("cmux-remote");
    expect(freestyleDaemonHealthyCommand()).toContain("/proc/net/tcp6");

    const startCommand = freestyleStartDaemonCommand();
    expect(startCommand).toContain("CMUX_TUI_REMOTE_WS_BIND=[::]:1337");
    expect(startCommand).toContain("systemctl restart cmux-tui-daemon");
    expect(startCommand).toContain("--remote-ws [::]:1337");
  });

  test("uses private network addresses before the legacy public route", () => {
    expect(
      freestyleCmuxRemoteRoute(
        {
          publicIpv6: "2602:f75c:0:1::2a",
          vpcs: [{ ipv6: "fd7a:115c:a1e0::a" }],
        },
        VM_ID,
      ),
    ).toBe("ws://[fd7a:115c:a1e0::a]:1337/v1/link");

    expect(freestyleCmuxRemoteRoute({ publicIpv6: "2602:f75c:0:1::2a" }, VM_ID)).toBe(
      "ws://[2602:f75c:0:1::2a]:1337/v1/link",
    );
    expect(freestyleFirewallRules()).toEqual([
      { action: "allow", source: {}, destination: { public: true } },
    ]);
  });
});
