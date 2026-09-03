import { describe, expect, test } from "bun:test";
import {
  freestyleDaemonHealthyCommand,
  freestyleDaemonSettledCommand,
  freestyleStartDaemonCommand,
} from "../services/vms/drivers/freestyle";

describe("Freestyle Cloud VM daemon repair", () => {
  test("health checks require the managed daemon and its dual-stack listener", () => {
    // Attach right after create lands in the supervisor's start window: on a
    // baked image the heal waits up to the settle budget before restarting.
    const settled = freestyleDaemonSettledCommand();
    expect(settled).toContain("if [ -f /etc/cmux/bake-instance-id ] && systemctl is-active cmux-tui-daemon");
    expect(settled).toContain("for i in $(seq 1 30); do {");
    expect(settled).toContain("sleep 0.1");
    expect(settled).toContain(`else ${freestyleDaemonHealthyCommand()}; fi`);
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
