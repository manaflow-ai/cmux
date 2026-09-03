import { describe, expect, test } from "bun:test";
import {
  CMUX_TUI_BINARY_PATH,
  CMUX_TUI_PORT,
  cmuxTuiDaemonCommand,
  cmuxTuiInstallCommand,
  cmuxTuiPinCheckCommand,
} from "../services/vms/drivers/cmuxTuiDaemon";
import {
  freestyleDaemonHealthyCommand,
  freestyleStartDaemonCommand,
} from "../services/vms/drivers/freestyle";

const SOURCE = {
  url: "https://files.cmux.com/cmux-tui/test/cmux-tui-x86_64-unknown-linux-musl",
  sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  commit: "0123456789abcdef0123456789abcdef01234567",
  builtAt: null,
} as const;

describe("Freestyle Cloud cmux-tui daemon repair", () => {
  test("install and start use the pinned managed daemon", () => {
    const install = cmuxTuiInstallCommand(SOURCE);
    expect(install).toContain(CMUX_TUI_BINARY_PATH);
    expect(install).toContain(SOURCE.sha256);
    expect(install).toContain(SOURCE.url);
    expect(install).toContain("sha256sum -c");
    expect(install).not.toContain("cmuxd-remote");

    const daemon = cmuxTuiDaemonCommand(`[::]:${CMUX_TUI_PORT}`);
    expect(daemon).toContain("server start --session cloud");
    expect(daemon).toContain(`--remote-ws [::]:${CMUX_TUI_PORT}`);
    expect(daemon).toContain(CMUX_TUI_BINARY_PATH);
    expect(daemon).not.toContain("cmuxd-remote");
  });

  test("health and repair require the dual-stack Freestyle listener", () => {
    const health = freestyleDaemonHealthyCommand();
    expect(health).toContain("pgrep -f 'cmux-tui server [s]tart' >/dev/null 2>&1 && grep -qi ':0539 ' /proc/net/tcp6");
    // Instance-binding images: health must also bind the daemon to this machine.
    expect(health).toContain("[ ! -f /etc/cmux/bake-instance-id ] ||");
    expect(health).toContain("/etc/cmux/daemon-instance-id");
    expect(health).toContain("/latest/meta-data/instance-id");

    const start = freestyleStartDaemonCommand();
    expect(start).toContain("cmux-tui-daemon.service");
    expect(start).toContain("Environment=CMUX_TUI_REMOTE_WS_BIND=[::]:1337");
    expect(start).toContain("systemctl daemon-reload");
    expect(start).toContain("systemctl restart cmux-tui-daemon");
    expect(start).toContain("--remote-ws [::]:1337");

    const pinCheck = cmuxTuiPinCheckCommand(SOURCE);
    expect(pinCheck).toContain(SOURCE.sha256);
    expect(pinCheck).toContain("sha256sum -c");
  });
});
