import { chmodSync, existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, describe, expect, test } from "bun:test";
import { WORK_USER_EXEC_PRELUDE, WORK_USER_EXEC_PRESERVED_VARIABLES, workUserExecCommand } from "../services/vms/drivers/workUserExecCommand";
import { runChild } from "./helpers/run-child";

// The provider runs a work-user exec as uid 1000 with the base image's stale
// HOME (/home/ubuntu, gone since the account was renamed to cmux). These tests
// run the real prelude in the shells a guest can have, against a fake passwd,
// and pin what the caller's command then sees.

const root = realpathSync(mkdtempSync(path.join(tmpdir(), "cmux-work-user-exec-")));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const workHome = path.join(root, "home", "cmux");
const staleHome = path.join(root, "home", "ubuntu");
const fakeBin = path.join(root, "bin");
mkdirSync(path.join(workHome, ".config", "cmux"), { recursive: true });
mkdirSync(fakeBin, { recursive: true });

function script(name: string, body: string) {
  const file = path.join(fakeBin, name);
  writeFileSync(file, `#!/bin/sh\n${body}\n`);
  chmodSync(file, 0o755);
}
// `getent passwd <uid>` answers from CMUX_TEST_PASSWD (empty: no entry).
script("getent", `[ "$1" = passwd ] && [ "$2" = 1000 ] && [ -n "$CMUX_TEST_PASSWD" ] && printf '%s\\n' "$CMUX_TEST_PASSWD" || exit 2`);
script("id", `case "$1" in -u) echo 1000 ;; -un) echo cmux ;; *) exit 1 ;; esac`);

const shells = ["/bin/sh", "/bin/dash", "/bin/bash"].filter((shell) => existsSync(shell));

function writeEnvFile(content: string | null) {
  const file = path.join(workHome, ".config", "cmux", "env");
  if (content === null) rmSync(file, { force: true });
  else writeFileSync(file, content, { mode: 0o600 });
}

async function run(shell: string, command: string, opts: { home?: string; cwd?: string; passwd?: string } = {}) {
  const result = await runChild(shell, ["-c", workUserExecCommand(command)], {
    cwd: opts.cwd ?? "/",
    env: {
      PATH: `${fakeBin}:/usr/bin:/bin`,
      HOME: opts.home ?? staleHome,
      USER: "ubuntu",
      LOGNAME: "ubuntu",
      SHELL: "/bin/sh",
      CMUX_TEST_PASSWD: opts.passwd ?? `cmux:x:1000:1000::${workHome}:/bin/bash`,
    },
  });
  return { exitCode: result.status, stdout: result.stdout, stderr: result.stderr };
}

describe("work-user exec prelude", () => {
  test("is POSIX sh text that runs the caller's command unchanged after it", () => {
    expect(workUserExecCommand("echo hi")).toBe(`${WORK_USER_EXEC_PRELUDE}\necho hi`);
    expect(WORK_USER_EXEC_PRELUDE).not.toMatch(/\[\[|\bsource\b|\blocal\b|\$\{[A-Za-z_]+\/\//);
    expect(WORK_USER_EXEC_PRELUDE).toContain('getent passwd "$(id -u)"');
  });

  for (const shell of shells) {
    describe(shell, () => {
      test("a stale HOME becomes the passwd home, and the command starts there as the work user", async () => {
        writeEnvFile(null);
        const out = await run(shell, 'printf "%s|%s|%s|%s\\n" "$HOME" "$PWD" "$USER" "$LOGNAME"');
        expect(out).toMatchObject({ exitCode: 0, stderr: "" });
        expect(out.stdout).toBe(`${workHome}|${workHome}|cmux|cmux\n`);
      });

      test("the machine env file the receiver wrote is visible to the command", async () => {
        writeEnvFile("export CMUX_TEST_TOKEN='it'\\''s here'\nexport CMUX_TEST_URL='https://x.test'\n");
        const out = await run(shell, 'printf "%s|%s\\n" "$CMUX_TEST_TOKEN" "$CMUX_TEST_URL"');
        expect(out).toMatchObject({ exitCode: 0, stdout: "it's here|https://x.test\n", stderr: "" });
        // A login shell started through exec reads the same file through the same home.
        const login = await run(shell, '[ -f "$HOME/.config/cmux/env" ] && echo found');
        expect(login.stdout).toBe("found\n");
      });

      test("an env file that does not parse is skipped, not fatal", async () => {
        writeEnvFile("export BROKEN='unterminated\nif then fi (\n");
        const out = await run(shell, "echo ran; exit 7");
        expect(out.exitCode).toBe(7);
        expect(out.stdout).toBe("ran\n");
        expect(out.stderr).toBe("");
      });

      test("the command's exit status, stdout and stderr pass through", async () => {
        writeEnvFile(null);
        const out = await run(shell, "echo out; echo err >&2; exit 3");
        expect(out).toEqual({ exitCode: 3, stdout: "out\n", stderr: "err\n" });
      });

      test("a correct HOME and a deliberate working directory are left alone", async () => {
        writeEnvFile(null);
        const elsewhere = path.join(root, "home");
        const out = await run(shell, 'printf "%s|%s|%s\\n" "$HOME" "$PWD" "$USER"', { home: workHome, cwd: elsewhere });
        expect(out.stdout).toBe(`${workHome}|${elsewhere}|ubuntu\n`);
      });

      test("without a passwd entry (or with a missing home) HOME is not touched", async () => {
        writeEnvFile(null);
        const none = await run(shell, 'printf "%s|%s\\n" "$HOME" "$PWD"', { passwd: "" });
        expect(none.stdout).toBe(`${staleHome}|/\n`);
        const missing = await run(shell, 'printf "%s\\n" "$HOME"', { passwd: `cmux:x:1000:1000::${root}/nope:/bin/bash` });
        expect(missing.stdout).toBe(`${staleHome}\n`);
      });

      test("an env file cannot change PATH, HOME, USER, LOGNAME, SHELL or IFS for the command", async () => {
        writeEnvFile(
          [
            "export PATH='/nonexistent'",
            "export HOME='/tmp/elsewhere'",
            "export USER='mallory'",
            "export LOGNAME='mallory'",
            "export SHELL='/bin/false'",
            "IFS='x'",
            "export CMUX_TEST_URL='https://x.test'",
            "",
          ].join("\n"),
        );
        // `id`/`printf` resolve through PATH, so a clobbered PATH would fail here.
        const out = await run(
          shell,
          'set -- a b; [ "${IFS-}" != x ] && ifs=kept; printf "%s|%s|%s|%s|%s|%s|%s|%s\\n" "$(id -un)" "$HOME" "$USER" "$LOGNAME" "$SHELL" "${ifs-}" "$CMUX_TEST_URL" "$*"',
        );
        expect(out).toMatchObject({ exitCode: 0, stderr: "" });
        expect(out.stdout).toBe(`cmux|${workHome}|cmux|cmux|/bin/sh|kept|https://x.test|a b\n`);
        // The command still finds the env file it can now fix (`vm env rm`).
        const rm = await run(shell, '[ -w "$HOME/.config/cmux/env" ] && echo writable');
        expect(rm.stdout).toBe("writable\n");
      });

      test("an env file that makes a kept name readonly is skipped, not fatal", async () => {
        writeEnvFile("export CMUX_TEST_URL='https://x.test'\nreadonly PATH\n");
        const out = await run(shell, 'echo "ran:${CMUX_TEST_URL-}"; exit 4');
        expect(out).toEqual({ exitCode: 4, stdout: "ran:\n", stderr: "" });
      });

      test("the prelude leaves no variables of its own behind", async () => {
        writeEnvFile("export CMUX_TEST_URL='https://x.test'\n");
        const scratch = ["cmux_exec_home", "cmux_exec_user", "cmux_exec_env"].concat(
          WORK_USER_EXEC_PRESERVED_VARIABLES.flatMap((name) => [`cmux_exec_set_${name}`, `cmux_exec_val_${name}`]),
        );
        const out = await run(shell, `[ -z "${scratch.map((name) => `\${${name}+x}`).join("")}" ] && echo clean`);
        expect(out.stdout).toBe("clean\n");
      });
    });
  }
});
