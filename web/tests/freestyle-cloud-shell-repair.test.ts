import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";

const freestyleDriverSource = readFileSync(
  join(import.meta.dir, "../services/vms/drivers/freestyle.ts"),
  "utf8",
);

describe("Freestyle Cloud VM shell repair", () => {
  test("daemon creation and repair use the managed cloud shell", () => {
    expect(freestyleDriverSource).toContain(
      'const CMUX_CLOUD_SHELL_PATH = "/usr/local/bin/cmux-cloud-shell"',
    );
    expect(freestyleDriverSource).toContain('"--shell",\n        CMUX_CLOUD_SHELL_PATH');
    expect(freestyleDriverSource).toContain(
      "ExecStart=/usr/local/bin/cmuxd-remote serve --ws --listen 0.0.0.0:7777 --auth-lease-file ${CMUXD_WS_PTY_LEASE_PATH} --rpc-auth-lease-file ${CMUXD_WS_RPC_LEASE_PATH} --shell /usr/local/bin/cmux-cloud-shell",
    );
    expect(freestyleDriverSource).not.toContain('"--shell",\n        "/bin/bash"');
  });

  test("healthy websocket daemons are still repaired when shell integration is missing", () => {
    expect(freestyleDriverSource).toContain("readFreestyleCloudShellState(vm)");
    expect(freestyleDriverSource).toContain("service-shell-not-managed");
    expect(freestyleDriverSource).toContain("cmux-user-missing");
    expect(freestyleDriverSource).toContain("home-zshrc-missing");
    expect(freestyleDriverSource).toContain("freestyleCloudShellSetupCommands()");
  });
});
