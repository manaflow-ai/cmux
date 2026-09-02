import { describe, expect, test } from "bun:test";
import {
  freestyleDaemonHealthyCommand,
  freestyleStartDaemonCommand,
} from "../services/vms/drivers/freestyle";

describe("Freestyle Cloud VM daemon repair", () => {
  test("health checks require the managed daemon and its dual-stack listener", () => {
    const healthy = freestyleDaemonHealthyCommand();
    // [s]tart keeps the pattern from matching the exec shell that carries it.
    expect(healthy).toContain("pgrep -f 'cmux-tui server [s]tart' >/dev/null 2>&1 && grep -qi ':0539 ' /proc/net/tcp6");
    // Instance-binding images: healthy also means bound to this machine's id.
    expect(healthy).toContain("[ ! -f /etc/cmux/bake-instance-id ] ||");
    expect(healthy).toContain("/etc/cmux/daemon-instance-id");
    expect(healthy).toContain("/latest/meta-data/instance-id");
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
