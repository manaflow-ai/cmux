import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { freshAccountIdentity, freshAccountSignUp, secondChatPlan } from "./cloud-journey";

describe("--fresh-account", () => {
  test("each run gets its own throwaway identity", () => {
    const a = freshAccountIdentity(1, () => 0.25);
    const b = freshAccountIdentity(2, () => 0.25);
    expect(a.email).toMatch(/^cmux-journey\+fresh-[0-9a-z-]+@example\.com$/);
    expect(a.email).not.toBe(b.email);
    expect(a.password.length).toBeGreaterThanOrEqual(12);
  });

  test("production's Stack project is refused before any call", async () => {
    await expect(freshAccountSignUp("prod")).rejects.toThrow(/dev Stack project only/);
  });
});

/** A stand-in `cmux` whose `link start-chat plan` answers what the shell script says, for the step's own judgement. */
function fakeCmux(planBody: string): { bin: string; done: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "journey-plan-test-"));
  const bin = join(dir, "cmux");
  writeFileSync(bin, `#!/bin/bash
# args: link start-chat ACTION ...
pins="$CMUX_TUI_STATE_DIR/pins"
case "$3" in
  pin) echo "$5" >> "$pins"; echo '{"ok":true}' ;;
  plan) req="$5"; ${planBody} ;;
  *) exit 64 ;;
esac
`);
  chmodSync(bin, 0o755);
  return { bin, done: () => rmSync(dir, { recursive: true, force: true }) };
}

describe("second chat gets its own VM", () => {
  const first = { id: "vm_first", title: "cloud-chats" };

  test("passes when the second chat plans a new machine and a retry keeps the first", async () => {
    // The pinned key's retry answers its machine; any other send answers a new one.
    const cmux = fakeCmux(`key=$(echo "$req" | sed -E 's/.*"key":"([^"]+)".*/\\1/'); if grep -qx "$key" "$pins" 2>/dev/null; then echo '{"ok":true,"machine":"vm_first"}'; else echo '{"ok":true,"machine":null,"new_name":"cloud-chats-2"}'; fi`);
    try {
      expect(await secondChatPlan(cmux.bin, "user_1/", first)).toContain("a new machine (cloud-chats-2), not vm_first");
    } finally { cmux.done(); }
  });

  test("fails when the second chat lands on the first chat's machine", async () => {
    const cmux = fakeCmux(`if [ -s "$pins" ]; then echo '{"ok":true,"machine":"vm_first"}'; else echo '{"ok":true,"machine":null}'; fi`);
    try {
      await expect(secondChatPlan(cmux.bin, "user_1/", first)).rejects.toThrow(/shares the first chat's VM vm_first: one VM per agent is broken/);
    } finally { cmux.done(); }
  });
});
