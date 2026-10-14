import { createHash } from "node:crypto";
import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { runChild } from "./helpers/run-child";

const script = readFileSync(path.join(import.meta.dirname, "../scripts/cloud-vm/cmux-tui-upgrade.sh"), "utf8");
const entry = script.indexOf("\nif id -u cmux");
if (entry < 0) throw new Error("upgrade script entry point was not found");
const functions = script.slice(0, entry);

describe("Cloud daemon upgrade recovery", () => {
  test.each(["install", "pin", "health", "hosts"])("%s failure restores both binary and helper", async (failure) => {
    const root = mkdtempSync(path.join(tmpdir(), "cmux-upgrade-"));
    try {
      const binary = path.join(root, "cmux-tui");
      const helper = path.join(root, "state-mount");
      writeFileSync(binary, "previous binary\n");
      writeFileSync(helper, "previous helper\n");
      writeFileSync(path.join(root, "cmux-tui-state-mount.prev"), "previous helper\n");
      writeFileSync(path.join(root, "install.cmd"), `printf 'target binary\\n' > "$FIXTURE_BIN"\nprintf 'target helper\\n' > "$FIXTURE_HELPER"\n${failure === "install" ? 'printf "bad binary\\n" > "$FIXTURE_BIN"\nexit 1' : failure === "pin" ? 'printf "bad binary\\n" > "$FIXTURE_BIN"' : ":"}\n`);
      const fixture = `flock() { return 0; }
${functions}
BIN="$RUN/cmux-tui"
H="$RUN"
STATE_MOUNT="$RUN/state-mount"
STATE_MOUNT_UPDATED=1
sha256sum() { shasum -a 256 "$1"; }
install() { cp "$3" "$4"; }
daemon_pid() { echo 77; }
stop_child() { :; }
host_pids() { ${failure === "hosts" ? "echo 88" : ":"}; }
kill() { return 1; }
wait_serving() { [ "$1" = "$OLD_SHA" ] && echo 99; ${failure === "hosts" ? '[ "$1" = "$TARGET_SHA" ] && echo 77;' : ""} [ "$1" = "$OLD_SHA" ]${failure === "hosts" ? ' || [ "$1" = "$TARGET_SHA" ]' : ""}; }
canary_crash_loop
`;
      const result = await runChild("/bin/sh", ["-c", fixture, "fixture", createHash("sha256").update("target binary\n").digest("hex"), "target-commit", root], {
        timeout: 5000,
        env: { ...process.env, FIXTURE_BIN: binary, FIXTURE_HELPER: helper },
      });
      expect(result.status).toBe(0);
      expect(readFileSync(binary, "utf8")).toBe("previous binary\n");
      expect(readFileSync(helper, "utf8")).toBe("previous helper\n");
      expect(readFileSync(path.join(root, "result"), "utf8")).toContain("ROLLBACK");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
