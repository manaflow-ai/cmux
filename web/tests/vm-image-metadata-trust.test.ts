import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { metadataGuardCheckCommand, metadataGuardProblems } from "../services/vms/images/metadataGuard";

const fixtures: string[] = [];
afterEach(() => {
  for (const fixture of fixtures.splice(0)) rmSync(fixture, { recursive: true });
});

function check(sudo: "allow" | "deny"): string {
  const fixture = mkdtempSync(path.join(tmpdir(), "metadata-trust-test-"));
  fixtures.push(fixture);
  const scripts = {
    runuser: "shift 3; export METADATA_TEST_UID=work; exec \"$@\"",
    sudo: "[ \"$METADATA_TEST_SUDO\" = allow ] || exit 1; shift; export METADATA_TEST_UID=root; exec \"$@\"",
    curl: "[ \"${METADATA_TEST_UID:-root}\" = root ] || exit 7; printf 'mock-metadata\\n'",
  };
  for (const [name, script] of Object.entries(scripts)) {
    writeFileSync(path.join(fixture, name), `#!/bin/sh\n${script}\n`, { mode: 0o755 });
  }
  const result = Bun.spawnSync(["/bin/bash", "-c", metadataGuardCheckCommand("cmux")], {
    env: { PATH: `${fixture}:/usr/bin:/bin`, METADATA_TEST_SUDO: sudo, METADATA_TEST_UID: "root" },
  });
  expect(result.exitCode).toBe(0);
  return result.stdout.toString();
}

describe("metadata guard trust contract", () => {
  test("the check proves a sudo-capable work user reaches metadata despite the UID block", () => {
    const output = check("allow");
    expect(output).toContain("user_blocked=yes\n");
    expect(output).toContain("root_reads=yes\n");
    expect(output).toContain("work_user_sudo_reads=yes\n");
    expect(output).toContain("guard_security_boundary=no\n");
    expect(metadataGuardProblems(output)).toEqual([]);
  });

  test("a failed sudo probe cannot silently establish the image's root-access contract", () => {
    const output = check("deny");
    expect(output).toContain("work_user_sudo_reads=no\n");
    expect(metadataGuardProblems(output)).toContain("the work user's sudo metadata access was not demonstrated; review the image trust contract");
  });

  test("legacy UID-only evidence cannot pass as an explicit trust contract", () => {
    expect(metadataGuardProblems("user_blocked=yes\nroot_reads=yes\n")).toContain("the guard must explicitly report that it is not a security boundary");
  });
});
