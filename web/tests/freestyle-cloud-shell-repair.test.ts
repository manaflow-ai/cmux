import { describe, expect, test } from "bun:test";
import {
  freestyleDaemonHealthyCommand,
  freestyleStartDaemonCommand,
} from "../services/vms/drivers/freestyle";

describe("Freestyle Cloud VM daemon repair", () => {
  test("health checks require the managed daemon and its dual-stack listener", () => {
    expect(freestyleDaemonHealthyCommand()).toBe(
      "pgrep -f 'cmux-tui server start' >/dev/null 2>&1 && grep -qi ':0539 ' /proc/net/tcp6",
    );
  });

  test("repair restores the managed dual-stack daemon", () => {
    const command = freestyleStartDaemonCommand();
    expect(command).toContain("cmux-tui-daemon.service");
    expect(command).toContain("CMUX_TUI_REMOTE_WS_BIND=[::]:1337");
    expect(command).toContain("systemctl daemon-reload");
    expect(command).toContain("systemctl restart cmux-tui-daemon");
    expect(command).toContain("--remote-ws [::]:1337");
  });
});
