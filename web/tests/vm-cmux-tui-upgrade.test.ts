import { createHash } from "node:crypto";
import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { runChild } from "./helpers/run-child";

const script = readFileSync(path.join(import.meta.dirname, "../scripts/cloud-vm/cmux-tui-upgrade.sh"), "utf8");
const entry = script.indexOf("\nif id -u cmux");
if (entry < 0) throw new Error("upgrade script entry point was not found");
const functions = script.slice(0, entry);

describe("Cloud daemon upgrade recovery", () => {
  test.each(["install", "pin", "health", "hosts", "helper-syntax", "helper-install", "helper-ensure"])("%s failure restores both binary and helper", async (failure) => {
    const root = mkdtempSync(path.join(tmpdir(), "cmux-upgrade-"));
    try {
      const run = path.join(root, "run");
      mkdirSync(run);
      const binary = path.join(run, "cmux-tui");
      const helper = path.join(run, "state-mount");
      writeFileSync(binary, "previous binary\n");
      writeFileSync(helper, "previous helper\n");
      writeFileSync(path.join(run, "cmux-tui-state-mount.prev"), "previous helper\n");
      if (failure.startsWith("helper-")) {
        writeFileSync(path.join(run, "state-mount.sh"), failure === "helper-syntax" ? "if\n" : `#!/bin/sh\nexit ${failure === "helper-ensure" ? 1 : 0}\n`);
      }
      writeFileSync(path.join(run, "install.cmd"), `printf 'target binary\\n' > "$FIXTURE_BIN"\nprintf 'target helper\\n' > "$FIXTURE_HELPER"\n${failure === "install" ? 'printf "bad binary\\n" > "$FIXTURE_BIN"\nexit 1' : failure === "pin" ? 'printf "bad binary\\n" > "$FIXTURE_BIN"' : ":"}\n`);
      const fixture = `flock() { return 0; }
${functions}
BIN="$RUN/cmux-tui"
H="$RUN"
STATE_MOUNT="$RUN/state-mount"
STATE_MOUNT_UPDATED=${failure.startsWith("helper-") ? 0 : 1}
sha256sum() { shasum -a 256 "$1"; }
install() { ${failure === "helper-install" ? '[ "$3" = "$RUN/state-mount.sh" ] && return 1;' : ""} cp "$3" "$4" && chmod 755 "$4"; }
daemon_pid() { echo 77; }
stop_child() { :; }
host_pids() { ${failure === "hosts" ? "echo 88" : ":"}; }
kill() { return 1; }
wait_serving() { [ "$1" = "$OLD_SHA" ] && echo 99; ${failure === "hosts" ? '[ "$1" = "$TARGET_SHA" ] && echo 77;' : ""} [ "$1" = "$OLD_SHA" ]${failure === "hosts" ? ' || [ "$1" = "$TARGET_SHA" ]' : ""}; }
canary_crash_loop
`;
      const result = await runChild("/bin/sh", ["-c", fixture, "fixture", createHash("sha256").update("target binary\n").digest("hex"), "target-commit", run], {
        timeout: 15000,
        env: { ...process.env, FIXTURE_BIN: binary, FIXTURE_HELPER: helper },
      });
      expect(result.status).toBe(0);
      expect(readFileSync(binary, "utf8")).toBe("previous binary\n");
      expect(readFileSync(helper, "utf8")).toBe("previous helper\n");
      expect(readFileSync(path.join(run, "result"), "utf8")).toContain("ROLLBACK");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }, 20000);

  test.each(["absent", "untrusted", "trusted"])("no daemon is skipped with a %s supervisor", async (mode) => {
    const root = mkdtempSync(path.join(tmpdir(), "cmux-upgrade-gate-"));
    const run = path.join(root, "run");
    mkdirSync(run);
    try {
      const gateStart = script.indexOf("# A crash-looping daemon is between restarts");
      const gateEnd = script.indexOf('if [ "$(exe_sha "$D")"', gateStart);
      expect(gateStart).toBeGreaterThanOrEqual(0);
      expect(gateEnd).toBeGreaterThan(gateStart);
      const fixture = `flock() { return 0; }
${functions}
      daemon_pid() { ${mode === "absent" ? ":" : "echo 77"}; }
      sleep() { :; }
      pgrep() { ${mode === "absent" ? "return 1" : "return 0"}; }
      daemon_has_trusted_carrier() { ${mode === "trusted" ? ":" : "return 1"}; }
      canary_crash_loop() { finish "OK fixture-canary"; }
${script.slice(gateStart, gateEnd)}
[ "${mode}" = trusted ] && canary_crash_loop
`;
      const result = await runChild("/bin/sh", ["-c", fixture, "fixture", "target-sha", "target-commit", run], { timeout: 5000 });
      expect(result.status).toBe(0);
      expect(readFileSync(path.join(run, "result"), "utf8").trim()).toBe(
        mode === "absent" ? "SKIP no-daemon" : mode === "untrusted" ? "SKIP no-trusted-carrier" : "OK fixture-canary",
      );
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }, 20000);

});
