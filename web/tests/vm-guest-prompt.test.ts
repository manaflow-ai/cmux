import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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
    env: { NODE_ENV: "test", PATH: process.env.PATH!, HOME: directory },
  });
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
  return result.stdout;
}

describe("Cloud Bash prompt", () => {
  test("attaches the line editor after user Bash settings have loaded", () => {
    const directory = fixture();
    install(directory, "brave-blue-otter", 100);
    const library = path.join(directory, "blesh");
    mkdirSync(library);
    // The editor captures PS1 when it attaches. Its prompt-time mode defers
    // that capture until the rest of the user's startup file has run.
    writeFileSync(path.join(library, "ble.sh"), `
      BLE_VERSION=fixture
      bleopt() { :; }
      ble-face() { :; }
      ble-bind() { :; }
      ble-attach() { printf '%s' "$PS1" > "$HOME/captured-prompt"; }
      [[ \${1-} == --noattach ]] || PROMPT_COMMAND+=(ble-attach)
    `);
    const rcPath = path.join(directory, "bashrc");
    writeFileSync(rcPath, readFileSync(rcPath, "utf8").replaceAll("/usr/local/share/blesh", library));
    const result = spawnSync("bash", ["--noprofile", "--norc", "-ic", `
      . '${rcPath}'
      PS1='custom> '
      for command in "\${PROMPT_COMMAND[@]}"; do eval "$command"; done
    `], {
      encoding: "utf8",
      env: { NODE_ENV: "test", PATH: process.env.PATH!, HOME: directory, USER: "cmux", TERM: "dumb" },
    });
    expect(result.status).toBe(0);
    expect(readFileSync(path.join(directory, "captured-prompt"), "utf8")).toBe("custom> ");
  });

  test("uses the generated slug, then a shell-safe renamed label", () => {
    const row = { id: "vm-one", slug: "brave-blue-otter", displayName: null, updatedAt: new Date(100) };
    expect(vmPromptIdentity(row)).toEqual({ machineId: "vm-one", name: "brave-blue-otter", revision: 100 });
    expect(vmPromptIdentity({ ...row, displayName: "My Build Box" }).name).toBe("my-build-box");
    expect(vmPromptIdentity({ ...row, displayName: "東京" }).name).toBe(row.slug);
    expect(vmPromptIdentity({ ...row, displayName: "a".repeat(100) }).name).toHaveLength(63);
    expect(vmPromptIdentity({ ...row, displayName: "$(touch /tmp/injected) `id` \\n" }).name).toMatch(/^[a-z0-9-]+$/);
  });

  test("an open shell reads a renamed machine using only builtins", () => {
    const directory = fixture();
    install(directory, "brave-blue-otter", 100);
    // Evaluate Bash's real prompt expansion in one shell. Empty PATH makes
    // any accidental git/cat/hostname/network command fail the test.
    const output = bash(directory, `
      . '${directory}/prompt.bash'
      PATH=/does-not-exist
      __cmux_prompt_name
      eval 'printf "%s\\n" "'"$PS1"'"'
      printf '%s\\n' renamed-box > '${directory}/vm-name'
      __cmux_prompt_name
      eval 'printf "%s\\n" "'"$PS1"'"'
      printf 'hook=%s\\n' "\${PROMPT_COMMAND-}"
    `);
    expect(output).toContain("@brave-blue-otter");
    expect(output).toContain("@renamed-box");
    expect(output).toContain("hook=__cmux_prompt_name\n");
  });

  test("preserves existing prompt commands, exit status, and repeated sourcing", () => {
    const directory = fixture();
    install(directory, "brave-blue-otter", 100);
    expect(bash(directory, `
      PROMPT_COMMAND=(':' 'printf user-hook')
      . '${directory}/prompt.bash'
      . '${directory}/prompt.bash'
      false
      __cmux_prompt_name
      printf '%s|' "$?"
      printf '%s|' "\${PROMPT_COMMAND[@]}"
    `)).toBe("1|__cmux_prompt_name|:|printf user-hook|");
  });

  test("renders successive prompts in a real interactive Bash terminal", () => {
    const directory = fixture();
    install(directory, "brave-blue-otter", 100);
    // System rc, Ubuntu user defaults, then the user's cmux source line.
    writeFileSync(path.join(directory, "startup.bash"), `. '${directory}/bashrc'\nPS1='ubuntu> '\n. '${directory}/bashrc'\n`);
    const result = spawnSync("python3", ["-c", String.raw`
import fcntl, os, pathlib, pty, select, signal, struct, subprocess, sys, termios, time
root = pathlib.Path(sys.argv[1])
(root / ".inputrc").write_text("set enable-bracketed-paste off\n")
(root / ".hushlogin").touch()
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 120, 0, 0))
def setup():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
shell = subprocess.Popen(["bash", "--noprofile", "--rcfile", str(root / "startup.bash"), "-i"],
    stdin=slave, stdout=slave, stderr=slave, preexec_fn=setup,
    env={"PATH": os.environ["PATH"], "HOME": str(root), "TERM": "xterm-256color"})
os.close(slave)
def until(marker):
    output = b""
    deadline = time.monotonic() + 3
    while marker not in output:
        if time.monotonic() > deadline: raise AssertionError(repr(output))
        if select.select([master], [], [], 0.1)[0]: output += os.read(master, 65536)
try:
    until(b"@brave-blue-otter")
    (root / "vm-name").write_text("renamed-box\n")
    os.write(master, b"false\n")
    until(b"@renamed-box")
    os.write(master, b"printf 'STATUS=%s\\n' \"$?\"\n")
    until(b"STATUS=1")
    os.write(master, b"PS1='custom> '\n")
    until(b"\r\ncustom> ")
    (root / "vm-name").write_text("third-name\n")
    os.write(master, b":\n")
    until(b"\r\ncustom> ")
finally:
    os.killpg(shell.pid, signal.SIGKILL)
    shell.wait()
    os.close(master)
`, directory], { encoding: "utf8", timeout: 15_000 });
    expect(result.stderr).toBe("");
    expect(result.status).toBe(0);
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
