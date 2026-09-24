import { describe, expect, test } from "bun:test";
import {
  CMUX_TUI_PORT,
  cmuxTuiDaemonCommand,
  cmuxTuiInstallCommand,
  cmuxTuiPinCheckCommand,
} from "../services/vms/drivers/cmuxTuiDaemon";

const SOURCE = {
  url: "https://files.cmux.com/cmux-tui/test/cmux-tui-x86_64-unknown-linux-musl",
  sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  commit: "0123456789abcdef0123456789abcdef01234567",
  builtAt: null, hookUrl: "https://files.cmux.com/cmux-tui/test/cmux-tui-hook-x86_64-unknown-linux-musl", hookSha256: "1".repeat(64),
  agentPlugin: {
    url: "https://files.cmux.com/cmux-agent-screen-detection/test/cmux-agent-screen-detection-x86_64-unknown-linux-musl",
    sha256: "2".repeat(64),
    commit: "0123456789abcdef0123456789abcdef01234567",
    manifestUrl: "https://files.cmux.com/cmux-agent-screen-detection/test/manifest.json",
  },
} as const;

describe("Freestyle Cloud VM daemon repair", () => {
  test("install and start use the pinned managed daemon", () => {
    const install = cmuxTuiInstallCommand(SOURCE);
    // The binary follows the daemon's layout, so a work-user machine gets one
    // its non-root sessions can execute (/root is 0700).
    expect(install).toContain('CMUX_TUI_BIN="$CMUX_TUI_HOME/.cmux/bin/cmux-tui"');
    expect(install).toContain(SOURCE.sha256);
    expect(install).toContain(SOURCE.url);
    expect(install).toContain("sha256sum -c");
    expect(install).not.toContain("cmuxd-remote");

    const daemon = cmuxTuiDaemonCommand(`[::]:${CMUX_TUI_PORT}`);
    expect(daemon).toContain("server start --session cloud");
    expect(daemon).toContain(`--remote-ws [::]:${CMUX_TUI_PORT}`);
    // The cloud listener is reachable only inside the owner's private network.
    expect(daemon).toContain("--remote-ws-trusted-carrier");
    expect(daemon).toContain('"$CMUX_TUI_BIN" server start');
    expect(daemon).not.toContain("cmuxd-remote");
  });

  test("pin check verifies the managed binary digest", () => {
    const pinCheck = cmuxTuiPinCheckCommand(SOURCE);
    expect(pinCheck).toContain(SOURCE.sha256);
    expect(pinCheck).toContain("sha256sum -c");
  });
});
