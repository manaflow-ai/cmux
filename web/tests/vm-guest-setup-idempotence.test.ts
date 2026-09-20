import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { guestBrowserInstallCommand, GUEST_BROWSER_FILES } from "../services/vms/guestBrowser";
import { guestResourceReporterInstallCommand } from "../services/vms/guestResourceReporter";

/** Executes the actual guest installer with filesystem paths confined to an owned directory. */
function fixture(body: (root: string, run: (command: string) => void, calls: () => string[]) => void) {
  const root = mkdtempSync(join(tmpdir(), "cmux-guest-setup-"));
  const bin = join(root, "bin");
  mkdirSync(bin);
  mkdirSync(join(root, "etc/systemd/system"), { recursive: true });
  mkdirSync(join(root, "etc/zsh"), { recursive: true });
  const source = `[ -r ${root}/etc/profile.d/cmux-browser.sh ] && . ${root}/etc/profile.d/cmux-browser.sh`;
  writeFileSync(join(root, "etc/bash.bashrc"), `${source}\n`);
  writeFileSync(join(root, "etc/zsh/zshenv"), `${source}\n`);
  const tool = (name: string, script: string) => writeFileSync(join(bin, name), `#!/bin/sh\n${script}\n`, { mode: 0o755 });
  tool("getent", "exit 0");
  tool("runuser", 'shift 3; exec "$@"');
  tool("xdg-mime", 'printf "mime\\n" >> "$FIXTURE_ROOT/calls"; printf "cmux-browser.desktop\\n"');
  tool("systemctl", `
printf '%s\\n' "$*" >> "$FIXTURE_ROOT/calls"
case "$1" in
  is-active) test -f "$FIXTURE_ROOT/active" ;;
  is-enabled) test -f "$FIXTURE_ROOT/enabled" ;;
  restart) touch "$FIXTURE_ROOT/active" ;;
  enable) touch "$FIXTURE_ROOT/active" "$FIXTURE_ROOT/enabled" ;;
esac`);
  if (spawnSync("which", ["sha256sum"]).status !== 0) tool("sha256sum", 'exec shasum -a 256 "$@"');
  const calls = () => {
    try { return readFileSync(join(root, "calls"), "utf8").trim().split("\n").filter(Boolean); }
    catch { return []; }
  };
  const run = (command: string) => {
    const isolated = command.replaceAll("/usr/local/", `${root}/usr/local/`).replaceAll("/etc/", `${root}/etc/`);
    const result = spawnSync("sh", ["-c", isolated], {
      encoding: "utf8", env: { NODE_ENV: "test", PATH: `${bin}:${process.env.PATH}`, FIXTURE_ROOT: root, HOME: root },
    });
    expect(result.stderr).toBe("");
    expect(result.status).toBe(0);
  };
  try { body(root, run, calls); }
  finally { rmSync(root, { recursive: true, force: true }); }
}

test("an unchanged browser integration does not repeat MIME setup on create or attach", () => fixture((root, run, calls) => {
  run(guestBrowserInstallCommand());
  expect(calls()).toHaveLength(6);
  run(guestBrowserInstallCommand());
  expect(calls()).toHaveLength(6);
  const opener = GUEST_BROWSER_FILES[0];
  writeFileSync(join(root, opener.path), "broken");
  run(guestBrowserInstallCommand());
  expect(calls()).toHaveLength(12);
  expect(readFileSync(join(root, opener.path), "utf8")).toBe(opener.content);
}));

test("an unchanged running reporter needs no systemd mutation on attach", () => fixture((root, run, calls) => {
  run(guestResourceReporterInstallCommand());
  const mutations = () => calls().filter(call => /^(enable|restart|daemon-reload)( |$)/.test(call));
  const installed = mutations();
  expect(installed).toContain("restart cmux-resource-stats.service");
  run(guestResourceReporterInstallCommand());
  expect(mutations()).toEqual(installed);
  rmSync(join(root, "active"));
  run(guestResourceReporterInstallCommand());
  expect(mutations().length).toBeGreaterThan(installed.length);
  const resumed = mutations().length;
  writeFileSync(join(root, "usr/local/lib/cmux/resource-stats.py"), "obsolete");
  run(guestResourceReporterInstallCommand());
  expect(mutations().slice(resumed)).toContain("restart cmux-resource-stats.service");
}));
