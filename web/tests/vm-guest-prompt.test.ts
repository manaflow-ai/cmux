import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { guestPromptInstallCommand, vmPromptIdentity } from "../services/vms/guestPrompt";

const directories: string[] = [];
afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

function fixture() {
  const directory = mkdtempSync(path.join(tmpdir(), "cmux-prompt-"));
  directories.push(directory);
  return directory;
}

function install(directory: string, name: string, revision: number, machineId = "vm-one") {
  const result = spawnSync("sh", ["-c", guestPromptInstallCommand({ machineId, name, revision }, directory)], { encoding: "utf8" });
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
}

function bash(directory: string, command: string) {
  const result = spawnSync("bash", ["--noprofile", "--norc", "-c", command], {
    encoding: "utf8",
    env: { PATH: process.env.PATH!, HOME: directory },
  });
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
  return result.stdout;
}

describe("Cloud Bash prompt", () => {
  test("uses the generated slug, then a shell-safe renamed label", () => {
    const row = { id: "vm-one", slug: "brave-blue-otter", displayName: null, updatedAt: new Date(100) };
    expect(vmPromptIdentity(row)).toEqual({ machineId: "vm-one", name: "brave-blue-otter", revision: 100 });
    expect(vmPromptIdentity({ ...row, displayName: "My Build Box" }).name).toBe("my-build-box");
    expect(vmPromptIdentity({ ...row, displayName: "東京" }).name).toBe(row.slug);
    expect(vmPromptIdentity({ ...row, displayName: "a".repeat(100) }).name).toHaveLength(63);
    expect(vmPromptIdentity({ ...row, displayName: "$(touch /tmp/injected) `id` \\n" }).name).toMatch(/^[a-z0-9-]+$/);
  });

  test("an open shell reads a renamed machine on its next prompt without commands or hooks", () => {
    const directory = fixture();
    install(directory, "brave-blue-otter", 100);
    // Evaluate Bash's real prompt expansion in one shell. Empty PATH makes
    // any accidental git/cat/hostname/network command fail the test.
    const output = bash(directory, `
      . '${directory}/prompt.bash'
      PATH=/does-not-exist
      eval 'printf "%s\\n" "'"$PS1"'"'
      printf '%s\\n' renamed-box > '${directory}/vm-name'
      eval 'printf "%s\\n" "'"$PS1"'"'
      printf 'hook=%s\\n' "\${PROMPT_COMMAND-}"
    `);
    expect(output).toContain("@brave-blue-otter");
    expect(output).toContain("@renamed-box");
    expect(output).toContain("hook=\n");
  });

  test("user Bash settings and a custom prompt survive updates", () => {
    const directory = fixture();
    const custom = `PS1='my custom prompt> '\nPROMPT_COMMAND=':'\n`;
    writeFileSync(path.join(directory, ".bashrc"), custom);
    install(directory, "brave-blue-otter", 100);
    install(directory, "renamed-box", 200);
    expect(readFileSync(path.join(directory, ".bashrc"), "utf8")).toBe(custom);
    expect(bash(directory, `. '${directory}/prompt.bash'; . "$HOME/.bashrc"; printf '%s|%s' "$PS1" "$PROMPT_COMMAND"`))
      .toBe("my custom prompt> |:");
  });

  test("a stale attach cannot undo a rename, and a clone takes its own identity", () => {
    const directory = fixture();
    install(directory, "renamed-box", 200);
    install(directory, "old-name", 100);
    expect(readFileSync(path.join(directory, "vm-name"), "utf8")).toBe("renamed-box\n");
    install(directory, "clone-name", 50, "vm-two");
    expect(readFileSync(path.join(directory, "vm-name"), "utf8")).toBe("clone-name\n");
  });
});
