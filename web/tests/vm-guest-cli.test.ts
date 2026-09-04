import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { GUEST_CMUX_SHIM, GUEST_CMUX_SHIM_PATH, guestCliInstallCommand } from "../services/vms/guestCli";
import {
  GUEST_CODEROUTER_ALIAS_PATH,
  GUEST_CODEROUTER_BIN_PATH,
  GUEST_CODEROUTER_INSTALL_ROOT,
  GUEST_CODEROUTER_VERSION,
  guestCoderouterInstallCommand,
} from "../services/vms/guestCoderouter";

function runShim(args: string[], env: Record<string, string | undefined> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "cmux-guest-cli-"));
  try {
    const shim = join(dir, "cmux");
    const fakeTui = join(dir, "cmux-tui");
    writeFileSync(shim, GUEST_CMUX_SHIM);
    chmodSync(shim, 0o755);
    writeFileSync(fakeTui, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
    chmodSync(fakeTui, 0o755);
    const result = spawnSync("sh", [shim, ...args], {
      encoding: "utf8",
      env: {
        NODE_ENV: "test",
        PATH: process.env.PATH ?? "/usr/bin:/bin",
        HOME: dir,
        CMUX_TUI_BIN: fakeTui,
        ...env,
      },
    });
    return {
      status: result.status,
      stdout: result.stdout,
      stderr: result.stderr,
      argv: result.stdout.trimEnd() ? result.stdout.trimEnd().split("\n") : [],
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("in-VM cmux CLI", () => {
  test("is valid POSIX shell and forwards local verbs to cmux-tui", () => {
    const syntax = spawnSync("sh", ["-n"], { input: GUEST_CMUX_SHIM, encoding: "utf8" });
    expect(syntax.status).toBe(0);
    expect(syntax.stderr).toBe("");

    const run = runShim(["workspace", "current", "get"]);
    expect(run.status).toBe(0);
    expect(run.argv).toEqual(["--session", "cloud", "workspace", "current", "get"]);
  });

  test("translates cmux notify without leaking Mac topology", () => {
    const run = runShim(
      ["notify", "--title", "Build done", "--subtitle", "api", "--body", "3 passed", "--workspace", "workspace:1"],
      { CMUX_TUI_TERMINAL_ID: "term_0123456789abcdef0123456789abcdef", CMUX_SOCKET_PATH: "/tmp/private.sock" },
    );
    expect(run.status).toBe(0);
    expect(run.argv).toEqual([
      "--session", "cloud", "--quiet", "notification", "create", "--title", "Build done",
      "--body", "api — 3 passed", "--terminal", "term_0123456789abcdef0123456789abcdef",
    ]);
    expect(run.stdout).not.toContain("workspace:1");
    expect(run.stdout).not.toContain("private.sock");
  });

  test("install command writes the shim atomically", () => {
    const command = guestCliInstallCommand();
    expect(command).toContain(`${GUEST_CMUX_SHIM_PATH}.tmp`);
    expect(command).toContain(`mv ${GUEST_CMUX_SHIM_PATH}.tmp ${GUEST_CMUX_SHIM_PATH}`);
    expect(command).toContain("chmod 0755");
    expect(spawnSync("sh", ["-n", "-c", command]).status).toBe(0);
  });
});

describe("in-VM CodeRouter CLI installer", () => {
  test("pins the npm package and exposes coderouter plus cr", () => {
    const command = guestCoderouterInstallCommand();
    expect(command).toContain(`'coderouter@${GUEST_CODEROUTER_VERSION}'`);
    expect(command).toContain(GUEST_CODEROUTER_BIN_PATH);
    expect(command).toContain(GUEST_CODEROUTER_ALIAS_PATH);
    expect(command).toContain(GUEST_CODEROUTER_INSTALL_ROOT);
    expect(command).toContain("prefix --global");
    expect(command).toContain("mv /etc/cmux/coderouter-version.tmp /etc/cmux/coderouter-version");
    expect(spawnSync("sh", ["-n", "-c", command]).status).toBe(0);
  });
});
