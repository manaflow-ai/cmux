import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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

// The prompt hook reports the cwd with OSC 7 (ESC ] 7 ; … BEL) before every
// prompt; tests about other prompt behavior drop those reports from the output.
function withoutCwdReports(text: string): string {
  const start = `${String.fromCharCode(0x1b)}]7;`;
  const end = String.fromCharCode(0x07);
  let output = "";
  let index = 0;
  while (index < text.length) {
    const report = text.indexOf(start, index);
    const reportEnd = report < 0 ? -1 : text.indexOf(end, report + start.length);
    if (report < 0 || reportEnd < 0) {
      output += text.slice(index);
      break;
    }
    output += text.slice(index, report);
    index = reportEnd + 1;
  }
  return output;
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
  test("emits the exact checked-in prompt and bashrc asset bytes", () => {
    const directory = fixture();
    install(directory, "brave-blue-otter", 100);
    const digest = (name: string) => createHash("sha256")
      .update(readFileSync(path.join(directory, name), "utf8").replaceAll(directory, "/etc/cmux"))
      .digest("hex");
    expect({ bashrc: digest("bashrc"), prompt: digest("prompt.bash") }).toEqual({
      bashrc: "b5229855c3edd1961e8bd695ea1254b410ca2146a8f37903d7c2b9db588692c8",
      prompt: "af6c2d4797c6c6e4ff3ec617b2bfceda66a3efa847d8c5511d6662a3656c8dde",
    });
  });

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
    expect(withoutCwdReports(bash(directory, `
      PROMPT_COMMAND=(':' 'printf user-hook')
      . '${directory}/prompt.bash'
      . '${directory}/prompt.bash'
      false
      __cmux_prompt_name
      printf '%s|' "$?"
      printf '%s|' "\${PROMPT_COMMAND[@]}"
    `))).toBe("1|__cmux_prompt_name|:|printf user-hook|");
  });

  test("reports the working directory to the daemon with OSC 7 using only builtins", () => {
    const directory = fixture();
    install(directory, "brave-blue-otter", 100);
    // A space and a multi-byte character: the daemon parses the report as a
    // file URL, so every byte outside the unreserved set is percent-encoded.
    const cwd = path.join(directory, "cmux tést dir");
    mkdirSync(cwd);
    const encoded = Array.from(Buffer.from(cwd, "utf8"), (byte) => {
      const char = String.fromCharCode(byte);
      return /[A-Za-z0-9/_.~-]/.test(char) ? char : `%${byte.toString(16).toUpperCase().padStart(2, "0")}`;
    }).join("");
    const output = bash(directory, `
      . '${directory}/prompt.bash'
      PATH=/does-not-exist
      HOSTNAME=test-host
      cd '${cwd}'
      false
      __cmux_prompt_name
      printf '|status=%s' "$?"
    `);
    expect(output).toBe(`\u001b]7;file://test-host${encoded}\u0007|status=1`);
  });

  test("renders successive prompts in a real interactive Bash terminal", () => {
    const directory = fixture();
    install(directory, "brave-blue-otter", 100);
    // System rc, Ubuntu user defaults, then the user's cmux source line.
    writeFileSync(path.join(directory, "startup.bash"), `. '${directory}/bashrc'\nPS1='ubuntu> '\n. '${directory}/bashrc'\n`);
    const result = spawnSync("python3", ["-c", String.raw`
import fcntl, os, pathlib, pty, re, select, signal, struct, subprocess, sys, termios, time
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
        if select.select([master], [], [], 0.1)[0]:
            # The prompt hook reports the cwd (OSC 7) right before each prompt.
            output = re.sub(rb"\x1b\]7;[^\x07]*\x07", b"", output + os.read(master, 65536))
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

  test("prompt sync treats a name written into vm-name as published, and ignores the baked default", () => {
    const directory = fixture();
    writeFileSync(path.join(directory, "vm-name"), "cmux\n");
    const script = path.join(import.meta.dirname, "../services/vms/images/devbox/cmux-prompt-sync");
    const result = spawnSync("python3", ["-c", String.raw`
import importlib.util, importlib.machinery, pathlib, sys, threading, time
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("prompt_sync", sys.argv[1])
spec = importlib.util.spec_from_loader("prompt_sync", loader)
module = importlib.util.module_from_spec(spec); loader.exec_module(module)
directory = pathlib.Path(sys.argv[2])
ready = threading.Event()
thread = threading.Thread(target=module.watch_local_name, args=(directory, ready, 5.0), daemon=True)
thread.start()
time.sleep(0.5)
print("default", ready.is_set())
(directory / "vm-name").write_text("shiny-cobalt-lizard\n")
print("named", ready.wait(2.0))
`, script, directory], { encoding: "utf8" });
    expect(result.stderr).toBe("");
    expect(result.stdout.trim().split("\n")).toEqual(["default False", "named True"]);
  });

  test("deferred first-workspace images never let prompt sync spawn or interrupt terminals", () => {
    const directory = fixture();
    writeFileSync(path.join(directory, "cloud-first-workspace-v1"), "");
    const script = path.join(import.meta.dirname, "../services/vms/images/devbox/cmux-prompt-sync");
    const result = spawnSync("python3", ["-c", String.raw`
import importlib.util, importlib.machinery, pathlib, sys, threading
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("prompt_sync", sys.argv[1])
spec = importlib.util.spec_from_loader("prompt_sync", loader)
module = importlib.util.module_from_spec(spec); loader.exec_module(module)
def forbidden(*args, **kwargs):
    raise AssertionError("prompt synchronization touched the reserved first workspace")
module.tui = forbidden
module.find_existing_terminal = forbidden
module.bound_terminal = forbidden
module.time.sleep = forbidden
module.seed_terminal(threading.Event(), pathlib.Path(sys.argv[2]))
print("untouched")
`, script, directory], { encoding: "utf8", timeout: 5_000 });
    expect(result.status).toBe(0);
    expect(result.stderr).toBe("");
    expect(result.stdout.trim()).toBe("untouched");
    expect(existsSync(path.join(directory, "first-terminal.json"))).toBe(false);
  });

  test("prompt sync creates the first workspace only after the daemon answers with no terminal", () => {
    // A warm clone's daemon is still adopting the template terminal when the
    // prompt sync starts. An unanswered list must not fall through to a
    // create: the CLI then waits for the daemon and adds a second workspace.
    const script = path.join(import.meta.dirname, "../services/vms/images/devbox/cmux-prompt-sync");
    const run = (listings: string, runDir = path.join(fixture(), "run")) => spawnSync("python3", ["-c", String.raw`
import importlib.util, importlib.machinery, json, pathlib, sys, threading, types
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("prompt_sync", sys.argv[1])
spec = importlib.util.spec_from_loader("prompt_sync", loader)
module = importlib.util.module_from_spec(spec); loader.exec_module(module)
module.time = types.SimpleNamespace(sleep=lambda _: None, monotonic=module.time.monotonic)
listings = json.loads(sys.argv[3])
calls = []
def tui(*args):
    calls.append(" ".join(args))
    if args[:2] == ("terminal", "list"):
        code, out = listings.pop(0) if listings else (0, '{"terminals":[{"terminal_id":"term_created"}]}')
        return types.SimpleNamespace(returncode=code, stdout=out)
    if args[:2] == ("workspace", "create"):
        return types.SimpleNamespace(returncode=0, stdout='{"terminal_id":"term_created"}')
    return types.SimpleNamespace(returncode=0, stdout="")
module.tui = tui
ready = threading.Event(); ready.set()
module.seed_terminal(ready, pathlib.Path(sys.argv[2]))
print(json.dumps([c for c in calls if c.startswith(("terminal list", "workspace create"))]))
`, script, fixture(), listings], { encoding: "utf8", env: { ...process.env, CMUX_PROMPT_RUN_DIR: runDir } });
    const adopted = run(JSON.stringify([[1, ""], [1, ""], [0, '{"terminals":[{"terminal_id":"term_adopted"}]}']]));
    expect(adopted.stderr).toBe("");
    expect(JSON.parse(adopted.stdout)).toEqual(["terminal list --json", "terminal list --json", "terminal list --json"]);
    const empty = run(JSON.stringify([[1, ""], [0, '{"terminals":[]}']]));
    expect(empty.stderr).toBe("");
    expect(JSON.parse(empty.stdout)).toEqual(["terminal list --json", "terminal list --json", "workspace create --name Cloud --json"]);
  });

  test("prompt sync seeds the terminal a warm clone's daemon bound, even before the list shows it", () => {
    const script = path.join(import.meta.dirname, "../services/vms/images/devbox/cmux-prompt-sync");
    const run = path.join(fixture(), "run");
    mkdirSync(run);
    writeFileSync(path.join(run, "bound"), "CMUX_TUI_SESSION_ID=session_clone\nCMUX_TUI_TERMINAL_ID=term_adopted\n");
    const result = spawnSync("python3", ["-c", String.raw`
import importlib.util, importlib.machinery, json, pathlib, sys, threading, types
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("prompt_sync", sys.argv[1])
spec = importlib.util.spec_from_loader("prompt_sync", loader)
module = importlib.util.module_from_spec(spec); loader.exec_module(module)
module.time = types.SimpleNamespace(sleep=lambda _: None, monotonic=module.time.monotonic)
calls = []
def tui(*args):
    calls.append(" ".join(args))
    if args[:2] == ("terminal", "list"):
        return types.SimpleNamespace(returncode=0, stdout='{"terminals":[]}')
    return types.SimpleNamespace(returncode=0, stdout='{"terminal_id":"term_created"}')
module.tui = tui
ready = threading.Event(); ready.set()
module.seed_terminal(ready, pathlib.Path(sys.argv[2]))
print(json.dumps(calls))
`, script, fixture()], { encoding: "utf8", env: { ...process.env, CMUX_PROMPT_RUN_DIR: run } });
    expect(result.stderr).toBe("");
    expect(JSON.parse(result.stdout)).toEqual(["terminal term_adopted history clear --quiet", "terminal term_adopted keys ctrl+c --quiet"]);
  });

  test("the armed template shell waits for its clone binding and replaces the builder's ids", () => {
    const directory = fixture();
    install(directory, "cmux", 100);
    const run = path.join(directory, "run");
    mkdirSync(run);
    writeFileSync(path.join(run, "template-arm"), "");
    // A clone binds 0.3 s after the shell reached its first prompt; the name
    // arrives right after. The builder's ids must be gone, the clone's set.
    const output = bash(directory, `
      export CMUX_PROMPT_RUN_DIR='${run}' CMUX_TUI_SESSION_ID=sess_builder CMUX_TUI_TERMINAL_ID=term_builder
      . '${directory}/prompt.bash'
      ( sleep 0.3; : > '${run}/clone-started'
        printf 'CMUX_TUI_SESSION_ID=sess_clone\\nCMUX_TUI_TERMINAL_ID=term_clone\\n' > '${run}/bound'
        printf 'shiny-cobalt-lizard\\n' > '${directory}/vm-name' ) &
      __cmux_prompt_name >/dev/null
      printf '%s %s %s ' "$CMUX_TUI_SESSION_ID" "$CMUX_TUI_TERMINAL_ID" "$__cmux_vm_name"
      [ -e '${run}/template-arm' ] && printf armed || printf consumed
      [ -e '${run}/first-prompt-named' ] && printf ' named'
      wait
    `);
    expect(output).toBe("sess_clone term_clone shiny-cobalt-lizard consumed named");
  });

  test("without a binding the template shell gives up, drops the builder's ids, and imports a late binding", () => {
    const directory = fixture();
    install(directory, "brave-blue-otter", 100);
    const run = path.join(directory, "run");
    mkdirSync(run);
    writeFileSync(path.join(run, "template-arm"), "");
    writeFileSync(path.join(run, "clone-started"), "");
    // A zero clone deadline gives up at once. The binding then arrives after
    // the first prompt; the next prompt must pick it up.
    const output = bash(directory, `
      export CMUX_PROMPT_RUN_DIR='${run}' CMUX_PROMPT_TEMPLATE_WAIT_US=0 CMUX_TUI_SESSION_ID=sess_builder CMUX_TUI_TERMINAL_ID=term_builder
      . '${directory}/prompt.bash'
      __cmux_prompt_name >/dev/null
      printf '[%s][%s]' "\${CMUX_TUI_SESSION_ID-unset}" "\${CMUX_TUI_TERMINAL_ID-unset}"
      printf 'CMUX_TUI_SESSION_ID=sess_late\\nCMUX_TUI_TERMINAL_ID=term_late\\n' > '${run}/bound'
      __cmux_prompt_name >/dev/null
      printf '[%s][%s]' "\${CMUX_TUI_SESSION_ID-unset}" "\${CMUX_TUI_TERMINAL_ID-unset}"
    `);
    expect(output).toBe("[unset][unset][sess_late][term_late]");
  });

  test("a shell that finds no arm file never waits", () => {
    const directory = fixture();
    install(directory, "brave-blue-otter", 100);
    const run = path.join(directory, "run");
    mkdirSync(run);
    const output = bash(directory, `
      export CMUX_PROMPT_RUN_DIR='${run}' CMUX_TUI_SESSION_ID=sess_live
      . '${directory}/prompt.bash'
      __cmux_prompt_name >/dev/null
      printf '%s' "$CMUX_TUI_SESSION_ID"
    `);
    expect(output).toBe("sess_live");
    // The gate writes template-shell-ready as its first step, so its absence
    // proves this shell never entered the wait.
    expect(existsSync(path.join(run, "template-shell-ready"))).toBe(false);
  });
});
