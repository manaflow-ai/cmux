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
  freestyleDaemonSettledCommand,
  freestyleStartDaemonCommand,
} from "../services/vms/drivers/freestyle";

const SOURCE = {
  url: "https://files.cmux.com/cmux-tui/test/cmux-tui-x86_64-unknown-linux-musl",
  sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  commit: "0123456789abcdef0123456789abcdef01234567",
  builtAt: null,
} as const;

describe("Freestyle Cloud VM daemon repair", () => {
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
    // The cloud listener is reachable only inside the owner's private network.
    expect(daemon).toContain("--remote-ws-trusted-carrier");
    expect(daemon).toContain(CMUX_TUI_BINARY_PATH);
    expect(daemon).not.toContain("cmuxd-remote");
  });

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
    // Machines healed in place get trusted mode through the same drop-in; the
    // daemon reads the env, so the baked launch line need not carry the flag.
    expect(start).toContain("Environment=CMUX_TUI_REMOTE_WS_TRUSTED_CARRIER=1");
    expect(start).toContain("systemctl daemon-reload");
    expect(start).toContain("systemctl restart cmux-tui-daemon");
    expect(start).toContain("--remote-ws [::]:1337");

    // The default launcher keeps a daemon that already runs; the trusted-listener
    // heal must replace it, or installing the pinned binary changes nothing for
    // the live process and the retried bundle still reports an untrusted daemon.
    expect(start).toContain("pgrep -f 'cmux-tui server [s]tart' >/dev/null 2>&1 ||");
    expect(start).not.toContain("pkill");
    const heal = freestyleStartDaemonCommand({ replaceExisting: true });
    expect(heal).toContain("systemctl restart cmux-tui-daemon");
    expect(heal).toContain("pkill -f 'cmux-tui server [s]tart'");
    expect(heal).not.toContain("pgrep -f 'cmux-tui server [s]tart' >/dev/null 2>&1 ||");
    expect(heal).toContain("--remote-ws-trusted-carrier");

    const pinCheck = cmuxTuiPinCheckCommand(SOURCE);
    expect(pinCheck).toContain(SOURCE.sha256);
    expect(pinCheck).toContain("sha256sum -c");
  });
});
