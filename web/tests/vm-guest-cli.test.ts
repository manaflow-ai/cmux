import { describe, expect, test } from "bun:test";

import { GUEST_CMUX_SHIM, GUEST_CMUX_SHIM_PATH, guestCliInstallCommand } from "../services/vms/guestCli";

// The in-VM `cmux` shim is shipped as driver-written bytes; a syntax error
// would surface only inside a live machine, so validate it here.
describe("in-VM cmux shim", () => {
  test("is valid POSIX sh", async () => {
    const proc = Bun.spawn(["sh", "-n"], { stdin: new Blob([GUEST_CMUX_SHIM]) });
    expect(await proc.exited).toBe(0);
  });

  test("fronts the machine's own cmux-tui and the peer-link verbs", () => {
    // Local verbs forward to the daemon binary on the daemon's session.
    expect(GUEST_CMUX_SHIM).toContain("/root/.cmux/bin/cmux-tui");
    expect(GUEST_CMUX_SHIM).toContain('--session "$LOCAL_SESSION"');
    // Peer links ride the same headless connect contract the Mac app uses:
    // remote connect --headless --json, socket named by the
    // connection-snapshot event's local_socket field.
    expect(GUEST_CMUX_SHIM).toContain("remote connect");
    expect(GUEST_CMUX_SHIM).toContain("--headless --json");
    expect(GUEST_CMUX_SHIM).toContain('select(.event=="connection-snapshot")');
    expect(GUEST_CMUX_SHIM).toContain(".local_socket");
    // The single-use invitation travels by file, never argv, and is dropped
    // from the peer file once consumed.
    expect(GUEST_CMUX_SHIM).toContain("--invite-file");
    expect(GUEST_CMUX_SHIM).toContain("del(.invite)");
    // Peer exec runs through a durable terminal on the peer.
    expect(GUEST_CMUX_SHIM).toContain("workspace current run");
  });

  test("install command is a safe atomic base64 write", () => {
    const command = guestCliInstallCommand();
    expect(command).toContain(`${GUEST_CMUX_SHIM_PATH}.tmp`);
    expect(command).toContain(`mv ${GUEST_CMUX_SHIM_PATH}.tmp ${GUEST_CMUX_SHIM_PATH}`);
    expect(command).toContain("chmod 0755");
    // The payload is base64: no shell metacharacters from the script body leak
    // into the exec command line.
    const encoded = command.match(/printf '%s' '([A-Za-z0-9+/=]+)'/);
    expect(encoded).not.toBeNull();
    expect(Buffer.from(encoded![1], "base64").toString("utf8")).toBe(GUEST_CMUX_SHIM);
  });
});
