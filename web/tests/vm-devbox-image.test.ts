import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  CMUX_TUI_PORT,
  CMUX_TUI_SESSION,
  cmuxTuiDaemonCommand,
  cmuxTuiLayoutSelector,
} from "../services/vms/drivers/cmuxTuiDaemon";
import {
  AGENT_PIN_ARGS,
  DEVBOX_SOURCE_SCHEMA,
  DEVBOX_TEMPLATE_FILES,
  agentPinDrift,
  devboxAgentPins,
  devboxCuaDriverVersion,
  devboxGhosttyVersion,
  devboxWaitForDaemonCommand,
  devboxParkDaemonCommand,
  devboxSourceDigest,
  devboxSourceManifest,
  normalizedBakeScript,
  normalizedDockerfileInstructions,
  rewriteDevboxAgentPins,
} from "../scripts/devbox-image-common";
import { DEVBOX_DESKTOP_USER } from "../services/vms/images/desktop";
import {
  DEVBOX_WORK_HOME,
  DEVBOX_WORK_UID,
  DEVBOX_WORK_USER,
  devboxWorkUserSetupCommand,
} from "../services/vms/images/workUser";

// Contract tests for the shared cmux Cloud devbox image template
// (services/vms/images/devbox), consumed by build-devbox-freestyle.ts,
// which replays its steps over Freestyle exec. These pin the
// pieces other code depends on: the cmux-tui daemon contract each driver
// expects and the Dockerfile portability restrictions. The template IS the
// artifact, so it is pinned here rather than only exercised by a live bake.

const templateDir = path.join(import.meta.dirname, "../services/vms/images/devbox");
const scriptsDir = path.join(import.meta.dirname, "../scripts");
const read = (name: string) => readFileSync(path.join(templateDir, name), "utf8");
const readScript = (name: string) => readFileSync(path.join(scriptsDir, name), "utf8");

const dockerfile = read("Dockerfile");
const bashrc = read("cmux-bashrc");
const devboxBoot = read("cmux-devbox-boot");

// A throwaway local HTTP server standing in for the coderouter opencode
// config endpoint, and a shell run sourcing the generator against it.
const listen = (
  handler: (request: IncomingMessage, response: ServerResponse) => void,
): Promise<{ origin: string; close: () => Promise<void> }> =>
  new Promise((resolve, reject) => {
    const server = createServer(handler);
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address() as AddressInfo;
      resolve({
        origin: `http://127.0.0.1:${address.port}`,
        close: () =>
          new Promise((done) => {
            server.close(() => done());
            server.closeAllConnections();
          }),
      });
    });
  });

const sourceAgentConfig = (home: string, coderouterOrigin: string): Promise<void> =>
  new Promise((resolve, reject) => {
    const child = spawn("bash", ["-c", `. ${path.join(templateDir, "agent-config.sh")}`], {
      env: {
        ...process.env,
        HOME: home,
        OPENAI_BASE_URL: `${coderouterOrigin}/v1`,
        OPENAI_API_KEY: "cmux-vm-edge-placeholder",
        CMUX_CODEROUTER_URL: coderouterOrigin,
      },
      stdio: "ignore",
    });
    child.on("error", reject);
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`agent-config.sh exited ${code}`)),
    );
  });

describe("devbox image template", () => {
  test("template directory contains exactly the expected files", () => {
    expect(readdirSync(templateDir).sort()).toEqual([
      "Dockerfile",
      "README.md",
      "agent-config.sh",
      "chrome-managed-policy.json",
      "cmux-bashrc",
      "cmux-devbox-boot",
      "cmux-motd",
      "cmux-terminfo.sh",
      "cmux-terminfo.src",
      "codex-managed.toml",
      // The desktop layer (Freestyle only); pinned by vm-devbox-desktop.test.ts.
      "desktop",
      "seed-history",
    ]);
    // The bake scripts' preflight covers the same set (minus the README).
    expect([...DEVBOX_TEMPLATE_FILES].sort()).toEqual([
      "Dockerfile",
      "agent-config.sh",
      "chrome-managed-policy.json",
      "cmux-bashrc",
      "cmux-devbox-boot",
      "cmux-motd",
      "cmux-terminfo.sh",
      "cmux-terminfo.src",
      "codex-managed.toml",
      "seed-history",
    ]);
  });

  test("the Ghostty version panes announce comes from the .deb pin and is a release version", () => {
    expect(devboxGhosttyVersion()).toMatch(/^\d+\.\d+\.\d+$/);
    expect(devboxGhosttyVersion("ARG CMUX_IMAGE_GHOSTTY_DEB_URL=https://x/ghostty_1.2.3-0.ppa2_amd64_24.04.deb\n")).toBe("1.2.3");
    expect(() => devboxGhosttyVersion("ARG CMUX_IMAGE_GHOSTTY_DEB_URL=https://x/ghostty.deb\n")).toThrow(/ghostty_<x.y.z>/);
  });

  test("every shell file parses", () => {
    for (const name of ["cmux-bashrc", "agent-config.sh", "cmux-terminfo.sh"]) {
      const result = spawnSync("bash", ["-n", path.join(templateDir, name)]);
      expect({ name, status: result.status }).toEqual({ name, status: 0 });
    }
    for (const name of ["cmux-devbox-boot", "cmux-motd"]) {
      const result = spawnSync("sh", ["-n", path.join(templateDir, name)]);
      expect({ name, status: result.status }).toEqual({ name, status: 0 });
    }
  });

  test("the login banner is cmux's, offline, and installed everywhere the base motd was", () => {
    const motd = read("cmux-motd");
    // The `cmux cloud` chevron logo from the CLI's cloud welcome
    // (CLI/cmux.swift), same gradient and tagline.
    expect(motd).toContain("persistent cloud VM");
    expect(motd).toContain("ready for coding agents");
    for (const rgb of ["0;212;255", "24;181;250", "48;150;245", "72;119;241", "96;88;239", "110;73;238", "124;58;237"]) {
      expect(motd).toContain(`38;2;${rgb}m`);
    }
    expect(readFileSync(path.join(import.meta.dirname, "../../CLI/cmux.swift"), "utf8")).toContain(
      "x cloud\\\\033[0m",
    );
    // Seeds are readable by the work user (the seed pass runs as root and
    // ble.sh creates its cache dir 0700), and Ghostty's TERM is seeded too.
    expect(dockerfile).toContain("chmod -R a+rX /etc/cmux/blesh-cache-seed");
    expect(readScript("build-devbox-freestyle.ts")).toContain("chmod -R a+rX /etc/cmux/blesh-cache-seed");
    expect(readScript("build-devbox-freestyle.ts")).toContain("linux xterm-ghostty; do");
    // Fast and offline: only baked files and cheap local commands.
    for (const forbidden of ["curl", "wget", "npm ", "claude --version", "apt"]) {
      expect({ forbidden, present: motd.includes(forbidden) }).toEqual({ forbidden, present: false });
    }
    // Same sections as `cmux welcome`: shortcuts and the links.
    expect(motd).toContain("Shortcuts");
    for (const line of ["New workspace", "Command palette", "Jump to latest unread", "https://cmux.com/docs", "https://discord.gg/xsgFEVrWCZ", "founders@manaflow.com"]) {
      expect(motd).toContain(line);
    }
    expect(dockerfile).toContain("COPY cmux-motd /etc/update-motd.d/00-cmux");
    const freestyleScript = readScript("build-devbox-freestyle.ts");
    expect(freestyleScript).toContain('"cmux-motd", "/etc/update-motd.d/00-cmux", 0o755');
    // The stock Ubuntu scripts stay in place but silent; the static motd is emptied.
    expect(freestyleScript).toContain("chmod -x");
    expect(freestyleScript).toContain(": > /etc/motd");
  });

  test("the Freestyle bake uses the base's toolchain and pins the agents on top of it", () => {
    // freestyle/ubuntu ships Node LTS under nvm (symlinked into /usr/local/bin),
    // Bun, Python 3.12, uv and Docker, plus its own copies of Claude Code,
    // Codex and OpenCode. The bake keeps that toolchain (no mise) and replaces
    // the agent copies with the exact Dockerfile pins via the base's npm, then
    // symlinks every agent bin into /usr/local/bin so non-login shells (daemon
    // panes) resolve them without a profile.
    const freestyleScript = readScript("build-devbox-freestyle.ts");
    expect(freestyleScript).not.toContain("mise.run");
    expect(freestyleScript).not.toContain("/opt/mise");
    expect(freestyleScript).toContain("readlink /usr/local/bin/node | grep -q /usr/local/nvm/");
    expect(freestyleScript).toContain("npm install -g --foreground-scripts");
    expect(freestyleScript).toContain('nvm_bin="$(dirname "$(readlink -f /usr/local/bin/node)")"');
    expect(freestyleScript).toContain('ln -sfn "$nvm_bin/${pin.binary}" /usr/local/bin/${pin.binary}');
    // The pins are proven from a clean login shell AS the work user during the
    // bake itself (probing as root with the work user's HOME leaves root-owned
    // state dirs that break ble.sh for every later login).
    expect(freestyleScript).toContain("sudo -n -u ${WORK_USER} env -i HOME=${WORK_HOME} USER=${WORK_USER} TERM=xterm bash -lc '${pin.binary} --version' | grep -F '${pin.version}'");
    // Home hygiene: single devshell source, ble.sh state dir, legal notice
    // silenced, home owned by the work user, two silent real logins.
    // Per-user rc files only: after Ubuntu's own PS1, and loaded once.
    expect(freestyleScript).toContain('const rcFiles = ["/etc/skel/.bashrc", "/root/.bashrc", `${WORK_HOME}/.bashrc`]');
    expect(freestyleScript).toContain("chmod a+rwxt /usr/local/share/blesh/state.d");
    expect(freestyleScript).toContain("motd.legal-displayed");
    expect(freestyleScript).toContain("chown -R ${WORK_USER}:${WORK_USER} ${WORK_HOME}");
    // The interactive probe is a real pty (tmux) as the work user and requires the cmux prompt.
    expect(freestyleScript).toContain("interactiveShellProbe(1)");
    expect(freestyleScript).toContain("interactiveShellProbe(2)");
    expect(freestyleScript).toContain('grep -q "λ"');
    expect(readScript("verify-devbox-image.ts")).toContain("work-user-login-silent-");
    expect(readScript("verify-devbox-image.ts")).toContain("home-owned-by-work-user");
    expect(readScript("verify-devbox-image.ts")).toContain("devshell-sourced-once");
    // The verifier checks both shell families without PATH help of its own.
    const verify = readScript("verify-devbox-image.ts");
    expect(verify).toContain("-login-pin-ok");
    expect(verify).toContain("-nonlogin-pin-ok");
    expect(verify).toContain("test ! -e /opt/mise");
  });

  test("one non-root work user named cmux, on a machine named cmux", () => {
    // Half the complaint this answers: a cmux Cloud terminal opened as
    // `root@freestyle-vm`, and `claude --dangerously-skip-permissions` refuses
    // to start as root. The machine's own name is the other half, and its own
    // contract (services/vms/images/identity.ts, vm-devbox-identity.test.ts).
    expect(DEVBOX_WORK_USER).toBe("cmux");
    expect(DEVBOX_WORK_HOME).toBe("/home/cmux");
    // Renamed, not added: the provider's exec default is the uid-1000 account,
    // so a second account would split the machine between two homes.
    expect(DEVBOX_WORK_UID).toBe(1000);
    const setup = devboxWorkUserSetupCommand();
    expect(setup).toContain("usermod -l cmux -d /home/cmux -m \"$old\"");
    expect(setup).toContain("groupmod -n cmux \"$old\"");
    // Idempotent: a re-bake over an already-renamed machine must not fail.
    expect(setup).toContain("if ! id -u cmux >/dev/null 2>&1; then");
    // The base's NOPASSWD policy names the account being renamed away.
    expect(setup).toContain("grep -q '^cmux[[:space:]]' \"$f\" || rm -f \"$f\"");
    expect(setup).toContain("sudo -n -u cmux sudo -n true");
    // Ubuntu's user-private-group umask leaves the daemon's state dir
    // group-writable, and cmux-tui refuses to store its identity under one.
    expect(setup).toContain("USERGROUPS_ENAB no");
    expect(setup).toContain('[ "$(sudo -n -u cmux sh -c umask)" = 0022 ]');
    // The bake sets this up before any layer writes into the home or names
    // the account, and the desktop session runs as the same user.
    const freestyleScript = readScript("build-devbox-freestyle.ts");
    const workUserStep = freestyleScript.indexOf('await step("work-user"');
    expect(workUserStep).toBeGreaterThan(0);
    expect(workUserStep).toBeLessThan(freestyleScript.indexOf('"apt-devtools",'));
    expect(DEVBOX_DESKTOP_USER).toBe(DEVBOX_WORK_USER);
    // The verifier proves the whole chain on a real machine.
    const verify = readScript("verify-devbox-image.ts");
    expect(verify).toContain("one-work-user");
    expect(verify).toContain("hostname-ok");
    expect(verify).toContain("prompt-says-cmux-at-cmux");
    expect(verify).toContain("claude-reaches-the-prompt");
    expect(verify).toContain("daemon-runs-as-work-user");
  });

  test("the image pipeline waits on readiness signals, never on the clock", () => {
    // 30 fixed `sleep 30`s were 15 of the ~26 minutes a full two-ladder
    // refresh took, while the verifier's own log showed the daemon answering
    // in under a second. Every one of them now waits on the daemon's actual
    // readiness, bounded so a daemon that never comes up fails instead of
    // hanging. This is the same rule the repo already applies to runtime code.
    const wait = devboxWaitForDaemonCommand(120);
    expect(wait).toContain("server status --session cloud");
    expect(wait).toContain("grep -qi ':0539 ' /proc/net/tcp6");
    // Bound to THIS machine, not merely present: a clone resumes the source
    // machine's daemon, which answers with the source's identity until the
    // supervisor re-keys it.
    expect(wait).toContain('[ "$(cat /etc/cmux/daemon-instance-id 2>/dev/null)" = "$cmux_instance" ]');
    expect(wait).toContain("latest/meta-data/instance-id");
    // Both sides non-empty: an unreachable metadata service yields an empty id
    // and an unwritten marker reads empty, so a bare comparison would call
    // "" = "" a bound identity and report ready on the first poll.
    expect(wait).toContain('[ -n "$cmux_instance" ]');
    // Bounded and fails closed.
    expect(wait).toContain("seq 1 240");
    expect(wait).toContain("exit 1");
    for (const name of ["build-devbox-freestyle.ts", "verify-devbox-image.ts", "derive-devbox-sizes.ts"]) {
      const script = readScript(name);
      expect({ name, sleeps: /sleep 30\b|setTimeout\(resolve, 30_000\)|sleep\(30_000\)/.test(script) })
        .toEqual({ name, sleeps: false });
      expect({ name, waits: script.includes("devboxWaitForDaemonCommand") }).toEqual({ name, waits: true });
    }
    // The ladder rows are independent, so they run concurrently, and the full
    // Noise/RPC/PTY round trip runs once per ladder instead of on all six.
    const derive = readScript("derive-devbox-sizes.ts");
    expect(derive).toContain("CMUX_DEVBOX_DERIVE_CONCURRENCY");
    expect(derive).toContain("async function deriveSize(");
    expect(derive).toContain("if (name === smokeSize) {");
  });

  test("the readiness wait fails closed when it cannot identify the machine", () => {
    // Runs the generated shell for real on a host with no metadata service and
    // no marker file: the honest answer is "not ready", not an instant pass.
    const script = path.join(mkdtempSync(path.join(tmpdir(), "cmux-ready-")), "wait.sh");
    writeFileSync(script, devboxWaitForDaemonCommand(1));
    const result = spawnSync("/bin/sh", [script], { encoding: "utf8", timeout: 20_000 });
    expect(result.status).toBe(1);
    expect(`${result.stderr}`).toContain("not ready");
  });

  test("ble.sh integration stays minimal: no token highlighting, ghost text only", () => {
    // User feedback 2026-08-31: any token highlighting (colored backgrounds
    // under mistyped commands included) reads as noise. The bashrc turns the
    // highlight layers off entirely and keeps only gray history ghost text.
    expect(bashrc).toContain("bleopt highlight_syntax= highlight_filename= highlight_variable=");
    const faceLines = bashrc.split("\n").filter((l) => l.trimStart().startsWith("ble-face"));
    expect(faceLines).toEqual(["  ble-face auto_complete=fg=245"]);
    for (const line of faceLines) {
      expect(line).not.toContain("bg=");
    }
  });

  test("keeps Alt+Backspace word delete working in ble.sh", () => {
    // Once ble.sh identifies the terminal from its DA2 reply it enables xterm
    // modifyOtherKeys, and then Alt+Backspace does nothing: the legacy ESC DEL
    // binding is gone and CSI 27;3;127~ does not decode back to M-C-?. Cloud
    // panes send the legacy form, so the bashrc pins the legacy encoding and
    // binds both backspace spellings.
    expect(bashrc).toContain(
      "bleopt term_modifyOtherKeys_internal=0 term_modifyOtherKeys_external=0",
    );
    expect(bashrc).toContain("ble-bind -f 'M-C-?' kill-backward-cword");
    expect(bashrc).toContain("ble-bind -f 'M-C-h' kill-backward-cword");
  });

  test("bakes ble.sh cache seeds for every shared devbox provider", () => {
    // The shared bashrc guard is useful only when each bake creates the seed.
    for (const term of ["xterm-256color", "screen-256color", "tmux-256color", "linux"]) {
      expect(dockerfile).toContain(`test -s /etc/cmux/blesh-cache-seed/blesh/*/term.${term}`);
    }
    expect(dockerfile).toContain("/usr/local/share/blesh/cache.d/0");
    expect(readScript("build-devbox-freestyle.ts")).toContain("blesh-cache-seed");
  });

  test("the Dockerfile is the Ubuntu 24.04 recipe the Freestyle bake replays, desktop included", () => {
    // freestyle/ubuntu is Ubuntu 24.04; the reference recipe builds on the
    // same distro so its package names, the Ghostty .deb and the desktop
    // stack are exactly what the bake installs (desktop pins are read from
    // this file: vm-devbox-desktop.test.ts).
    expect(dockerfile).toMatch(/^FROM ubuntu:24\.04$/m);
    expect(dockerfile).toContain("ARG CMUX_IMAGE_DESKTOP_PACKAGES=");
    expect(dockerfile).toContain("ARG CMUX_IMAGE_GHOSTTY_DEB_URL=");
    // The work user is the base's uid-1000 account renamed to cmux, with
    // passwordless sudo, on both recipes (services/vms/images/workUser.ts).
    expect(dockerfile).toContain('usermod -l cmux -d /home/cmux -m "$old" && groupmod -n cmux "$old"');
    expect(dockerfile).toContain('echo "cmux ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/91-cmux-work-user');
    expect(dockerfile).toContain('[ "$(id -u cmux)" = 1000 ]');
    expect(readScript("build-devbox-freestyle.ts")).toContain('await step("work-user", devboxWorkUserSetupCommand());');
    // ss for the desktop's port probes (start-vnc.sh) on both recipes.
    expect(dockerfile).toContain("iproute2");
    expect(readScript("build-devbox-freestyle.ts")).toContain("iproute2");
  });

  test("stays within the Dockerfile portability restrictions", () => {
    // These began as E2B Dockerfile-parser limits and are kept because the
    // Freestyle replay executes the same instructions over exec: backslash
    // escape sequences inside RUN strings are unreliable (printf '\n'
    // corrupts written files), ENTRYPOINT is not the boot mechanism (boot
    // commands come from the build script), and PATH must be literal.
    const instructionLines = dockerfile
      .split("\n")
      .filter((line) => !line.trimStart().startsWith("#"));
    expect(instructionLines.join("\n")).not.toContain("printf");
    expect(dockerfile).not.toMatch(/^ENTRYPOINT/m);
    expect(dockerfile).not.toMatch(/^CMD/m);
    expect(dockerfile).not.toMatch(/^USER/m);
    expect(dockerfile).toContain(
      "PATH=/opt/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    );
  });

  test("cmux-tui is the one session daemon; nothing cmuxd-era survives", () => {
    // The supervisor runs the exact daemon command the drivers use, so the
    // two can never drift apart.
    expect(CMUX_TUI_PORT).toBe(1337);
    expect(CMUX_TUI_SESSION).toBe("cloud");
    // The boot script parameterizes only the listener bind (the env Freestyle
    // public platform's systemd unit sets); everything else must match the drivers'
    // command byte for byte, so passing the shell expansion as the bind
    // reconstructs the script's exact line.
    expect(devboxBoot).toContain(
      cmuxTuiDaemonCommand('"${CMUX_TUI_REMOTE_WS_BIND:-0.0.0.0:1337}"'),
    );
    expect(cmuxTuiDaemonCommand()).toContain("--remote-ws 0.0.0.0:1337");
    // The supervisor reads the daemon layout the same way the command does, so
    // the state it wipes on a clone is the state the daemon actually writes.
    expect(devboxBoot).toContain(cmuxTuiLayoutSelector());
    expect(devboxBoot).toContain('BIN="$CMUX_TUI_BIN"');
    expect(devboxBoot).toContain('if [ -x "$BIN" ]');
    expect(dockerfile).toContain("COPY cmux-devbox-boot /usr/local/bin/cmux-devbox-boot");
    // A Freestyle snapshot is a memory image: the supervisor keys the daemon
    // identity on the platform instance id, wiping cmux-remote's default root
    // state dir on a clone, and holds the daemon on the builder itself.
    expect(devboxBoot).toContain('REMOTE_STATE_DIR="$CMUX_TUI_HOME/.local/state/cmux/remote"');
    expect(devboxBoot).toContain("/latest/meta-data/instance-id");
    expect(devboxBoot).toContain("BOUND_INSTANCE_FILE=/etc/cmux/daemon-instance-id");
    expect(devboxBoot).toContain("BAKE_INSTANCE_FILE=/etc/cmux/bake-instance-id");
    expect(devboxBoot).toContain('rm -rf "$REMOTE_STATE_DIR"');
    // The supervisor owns the daemon as a background child so it can stop a
    // daemon that belongs to another machine (a clone of a live machine).
    expect(devboxBoot).toContain("daemon_pid=$!");
    expect(devboxBoot).toContain("stop_daemon");
    // The desktop it may start (containers only) is a sibling, never wired
    // into the daemon's command or lifecycle.
    expect(devboxBoot).toContain("start_desktop");
    expect(devboxBoot.split("start_desktop").length - 1).toBe(2);
    // The Freestyle bake installs the pin with the driver's own install
    // command, proves the daemon, and parks it before the snapshot; the size
    // derive parks before each of its snapshots too.
    const freestyleBake = readScript("build-devbox-freestyle.ts");
    expect(freestyleBake).toContain('await step("cmux-tui-install", cmuxTuiInstallCommand(cmuxTuiSource));');
    expect(freestyleBake).toContain('await step("cmux-tui-daemon-park", devboxParkDaemonCommand());');
    expect(readScript("derive-devbox-sizes.ts")).toContain("await sh(vm, devboxParkDaemonCommand(), 120_000);");
    expect(devboxParkDaemonCommand()).toContain("> /etc/cmux/bake-instance-id");
    expect(devboxParkDaemonCommand()).toContain("daemon-parked-for-clones");
    // The container image bakes no binary, and the old cmuxd stack is gone everywhere.
    // The image itself carries nothing cmuxd-era, and no bake or verify
    // script installs or launches the old daemon (prose references to the
    // legacy driver are fine).
    expect(dockerfile).not.toContain("cmuxd");
    expect(devboxBoot).not.toContain("cmuxd");
    for (const name of [
      "build-devbox-freestyle.ts",
      "verify-devbox-image.ts",
    ]) {
      expect({ name, installsCmuxd: readScript(name).includes("/usr/local/bin/cmuxd-remote") })
        .toEqual({ name, installsCmuxd: false });
    }
  });

  test("the Freestyle boot path supervises the daemon through systemd", () => {
    const freestyleScript = readScript("build-devbox-freestyle.ts");
    expect(freestyleScript).toContain("ExecStart=/usr/local/bin/cmux-devbox-boot");
    expect(freestyleScript).toContain("cmux-tui-daemon.service");
    expect(freestyleScript).toContain("Restart=always");
  });

  test("the Freestyle replay carries the ble.sh cache bake", () => {
    // The replay embeds its own copy of the Dockerfile bake; pin the guards
    // and both cache targets so the provider-specific path cannot silently
    // drift while the Dockerfile path stays correct.
    const freestyleScript = readScript("build-devbox-freestyle.ts");
    expect(freestyleScript).toContain("mkdir -p /etc/cmux/blesh-cache-seed");
    for (const term of ["xterm-256color", "screen-256color", "tmux-256color", "linux"]) {
      expect(freestyleScript).toContain(
        `test -s /etc/cmux/blesh-cache-seed/blesh/*/term.${term}`,
      );
    }
    expect(freestyleScript).toContain("/usr/local/share/blesh/cache.d/0/");
    expect(freestyleScript).toContain("/usr/local/share/blesh/cache.d/1000/");
    expect(freestyleScript).toContain(
      "chown -R 1000:1000 /usr/local/share/blesh/cache.d/1000",
    );
  });

  test("agent and CUA driver pins are exact and reach the build scripts", () => {
    for (const arg of [
      "CMUX_IMAGE_CLAUDE_CODE_VERSION",
      "CMUX_IMAGE_CODEX_VERSION",
      "CMUX_IMAGE_OPENCODE_VERSION",
      "CMUX_IMAGE_PI_VERSION",
      "CMUX_IMAGE_AGENT_BROWSER_VERSION",
    ]) {
      const devboxPin = new RegExp(`^ARG ${arg}=(\\S+)$`, "m").exec(dockerfile)?.[1];
      // Ranges and floating tags would make a bake unreproducible.
      expect({ arg, exact: /^\d+\.\d+\.\d+$/.test(devboxPin ?? "") }).toEqual({ arg, exact: true });
    }
    // The build scripts derive their pins from the same ARGs.
    expect(devboxAgentPins(dockerfile).map((pin) => pin.pkg)).toEqual([
      "@anthropic-ai/claude-code",
      "@openai/codex",
      "opencode-ai",
      "@earendil-works/pi-coding-agent",
      "agent-browser",
    ]);

    const devboxCuaVersion = /CUA_DRIVER_RS_VERSION=(\S+)/.exec(dockerfile)?.[1];
    expect(devboxCuaVersion).toBeTruthy();
    expect(devboxCuaDriverVersion(dockerfile)).toBe(devboxCuaVersion!);
    // The Freestyle replay reads the pin through the helper, never a second copy.
    expect(readScript("build-devbox-freestyle.ts")).toContain("CUA_DRIVER_RS_VERSION=${cuaVersion}");
    expect(readScript("build-devbox-freestyle.ts")).toContain("devboxCuaDriverVersion()");
  });

  test("agent pins are bumped through the rewrite helper, exactly and only for baked packages", () => {
    // `bun run devbox:pins:check --write` is the one sanctioned way to bump a
    // pin: it rewrites the ARG line and nothing else, refuses ranges, tags and
    // packages the image does not bake, and fails on a Dockerfile whose ARG
    // table no longer matches.
    const pins = devboxAgentPins(dockerfile);
    const bumped = Object.fromEntries(pins.map((pin) => [pin.pkg, `${pin.version}9`]));
    const rewritten = rewriteDevboxAgentPins(dockerfile, bumped);
    expect(devboxAgentPins(rewritten).map((pin) => [pin.pkg, pin.version])).toEqual(Object.entries(bumped));
    // Every other byte survives: revert the pins and the file is byte-identical.
    expect(rewriteDevboxAgentPins(rewritten, Object.fromEntries(pins.map((pin) => [pin.pkg, pin.version])))).toBe(dockerfile);
    expect(rewriteDevboxAgentPins(dockerfile, {})).toBe(dockerfile);
    for (const bad of ["^2.1.0", "latest", "2.1", "2.1.0-beta.1"]) {
      expect(() => rewriteDevboxAgentPins(dockerfile, { "@openai/codex": bad })).toThrow(/not an exact x\.y\.z release/);
    }
    expect(() => rewriteDevboxAgentPins(dockerfile, { "left-pad": "1.0.0" })).toThrow(/not a devbox agent pin/);
    expect(() => rewriteDevboxAgentPins("FROM ubuntu:24.04\n", { "@openai/codex": "1.0.0" })).toThrow(/missing ARG CMUX_IMAGE_CODEX_VERSION/);
    // The drift report keys by package and flags any pin that is not the registry's latest.
    const latest = Object.fromEntries(pins.map((pin) => [pin.pkg, pin.version]));
    expect(agentPinDrift(pins, latest).every((row) => !row.behind)).toBe(true);
    const codex = pins.find((pin) => pin.pkg === "@openai/codex")!;
    const drift = agentPinDrift(pins, { ...latest, "@openai/codex": `${codex.version}9` });
    expect(drift.filter((row) => row.behind).map((row) => row.pkg)).toEqual(["@openai/codex"]);
    expect(() => agentPinDrift(pins, {})).toThrow(/no registry version/);
    expect(AGENT_PIN_ARGS.map((row) => row.binary)).toEqual(["claude", "codex", "opencode", "pi", "agent-browser"]);
  });

  test("the source digest covers what the Freestyle bake takes from this checkout, per layer set", () => {
    const base = devboxSourceManifest("base", dockerfile);
    const desktop = devboxSourceManifest("desktop", dockerfile);
    // Pins, epoch and the verbatim files: a pin bump, an epoch bump, or a
    // template edit each changes the digest; Dockerfile prose does not.
    expect(DEVBOX_SOURCE_SCHEMA).toBe(2);
    expect(base).toMatchObject({ schema: 2, layers: "base", agentPins: Object.fromEntries(devboxAgentPins(dockerfile).map((pin) => [pin.pkg, pin.version])) });
    expect(typeof base.dockerfileInstructions).toBe("string");
    expect(typeof base.bakeScript).toBe("string");
    expect(Object.keys(base.files as Record<string, string>).sort()).toEqual([...DEVBOX_TEMPLATE_FILES].filter((name) => name !== "Dockerfile").sort());
    expect(base).not.toHaveProperty("desktopFiles");
    expect(desktop).toHaveProperty("desktopFiles");
    expect(desktop).toHaveProperty("desktopPackages");
    expect(devboxSourceDigest("base", dockerfile)).not.toBe(devboxSourceDigest("desktop", dockerfile));
    expect(devboxSourceDigest("base", dockerfile)).toBe(devboxSourceDigest("base", `${dockerfile}\n# a comment changes no machine\n`));
    const codex = devboxAgentPins(dockerfile).find((pin) => pin.pkg === "@openai/codex")!;
    expect(devboxSourceDigest("base", rewriteDevboxAgentPins(dockerfile, { "@openai/codex": `${codex.version}9` }))).not.toBe(devboxSourceDigest("base", dockerfile));
    expect(devboxSourceDigest("base", dockerfile.replace(/^ENV CMUX_IMAGE_EPOCH=.*$/m, "ENV CMUX_IMAGE_EPOCH=1999-01-01-r1"))).not.toBe(devboxSourceDigest("base", dockerfile));
    // Schema 2 also sees a Dockerfile instruction change (a package added to a
    // RUN, no ARG moved) and any non-blank line change in the bake script; a
    // Dockerfile comment moves nothing. Schema 1, the formula the first
    // promoted ladders were recorded with, ignores both.
    const withStep = dockerfile.replace(/^    bubblewrap \\$/m, "    bubblewrap \\\n    cowsay \\");
    expect(withStep).not.toBe(dockerfile);
    expect(devboxSourceDigest("base", withStep)).not.toBe(devboxSourceDigest("base", dockerfile));
    expect(devboxSourceDigest("base", withStep, 1)).toBe(devboxSourceDigest("base", dockerfile, 1));
    expect(devboxSourceDigest("base", `${dockerfile}\n# a comment changes no machine\n`)).toBe(devboxSourceDigest("base", dockerfile));
    const bake = readScript("build-devbox-freestyle.ts");
    const withCode = () => `${bake}\nconsole.log("one more step");\n`;
    // A `*`-prefixed code line (a continued multiplication, a generator
    // method) is code, not a doc block: a change limited to it must move the
    // digest, so no line heuristic drops it.
    const withStar = () => bake.replace(/\nconst STEP_TIMEOUT_MS = 300_000;\n/, "\nconst STEP_TIMEOUT_MS = 300\n  * 1_000;\n");
    const withStarChanged = () => bake.replace(/\nconst STEP_TIMEOUT_MS = 300_000;\n/, "\nconst STEP_TIMEOUT_MS = 300\n  * 2_000;\n");
    expect(withStar()).not.toBe(bake);
    expect(devboxSourceDigest("base", dockerfile, 2, withCode)).not.toBe(devboxSourceDigest("base", dockerfile, 2, () => bake));
    expect(devboxSourceDigest("base", dockerfile, 2, withStarChanged)).not.toBe(devboxSourceDigest("base", dockerfile, 2, withStar));
    // A comment edit to the bake script moves it too (stated trade-off: no lexer).
    expect(devboxSourceDigest("base", dockerfile, 2, () => `${bake}\n// one more comment\n`)).not.toBe(devboxSourceDigest("base", dockerfile, 2, () => bake));
    expect(devboxSourceDigest("base", dockerfile, 1, withCode)).toBe(devboxSourceDigest("base", dockerfile, 1, () => bake));
    expect(() => devboxSourceDigest("base", dockerfile, 3)).toThrow(/unknown devbox source schema/);
    // The normalizers themselves: Dockerfile comments gone by the grammar
    // (a parser directive before the first instruction is kept, a `#` line
    // inside a continued RUN is a comment), bake-script lines kept verbatim
    // but for blank lines and trailing whitespace.
    expect(normalizedDockerfileInstructions("# syntax=docker/dockerfile:1\n# c\n\nFROM ubuntu:24.04  \nRUN apt-get install \\\n  # inside a continuation\n  cowsay\nRUN echo hi # keep\n# escape=`\n")).toBe("# syntax=docker/dockerfile:1\nFROM ubuntu:24.04\nRUN apt-get install \\\n  cowsay\nRUN echo hi # keep");
    expect(normalizedBakeScript("// c\n/**\n * doc\n */\nconst a = 1  \n\n  * 2;\n")).toBe("// c\n/**\n * doc\n */\nconst a = 1\n  * 2;");
    // Both bake entry points record the digest for the layers they baked.
    expect(readScript("build-devbox-freestyle.ts")).toContain('bakeMetadata(preflight, fileURLToPath(import.meta.url), withDesktop ? "desktop" : "base")');
    expect(readScript("promote-devbox-image.ts")).toContain("devboxSourceDriftProblems({ ...next, images: added })");
    expect(readScript("validate-devbox-ladder.ts")).toContain("devboxSourceDriftProblems(manifest)");
    // A promotion records the rows it appended and can replay them onto a
    // manifest that changed underneath it (two ladders in flight), through the
    // same append + demotion rule, never by hand.
    const promote = readScript("promote-devbox-image.ts");
    expect(promote).toContain('argValue("--replay")');
    expect(promote).toContain("appendImageManifestEntries(manifest, rows)");
    expect(promote).toContain("entries: added,");
  });

  test("codex's Linux sandbox prerequisite is installed and the first agent launch is verified", () => {
    // bubblewrap: without the distro bwrap, codex 0.151+ warns on every
    // launch that it is falling back to its bundled copy (seen live on the
    // termid ladder, 2026-09-09). Both recipes install it and prove it.
    expect(dockerfile).toContain("    bubblewrap \\");
    expect(dockerfile).toContain("bwrap --version");
    const bake = readScript("build-devbox-freestyle.ts");
    expect(bake).toContain("util-linux bubblewrap");
    expect(bake).toContain("bwrap --version");
    // The verifier launches the real claude (root) and codex (root and the
    // work user) TUIs and requires the ready composer with no first-run gate text.
    const verify = readScript("verify-devbox-image.ts");
    expect(verify).toContain("bubblewrap-ok");
    // The work user's claude launch is the verifier's own
    // `claude-reaches-the-prompt`; these add root (the provider's exec API
    // runs as root) and codex for both accounts.
    for (const label of ["claude-root-launch", "codex-root-launch", "codex-work-user-launch"]) {
      expect(verify).toContain(`"${label}"`);
    }
    expect(verify).toContain("claude-reaches-the-prompt");
    expect(verify).toContain('const CLAUDE_LAUNCH_MARKER = "bypass permissions on"');
    expect(verify).toContain('const CODEX_LAUNCH_MARKER = "Ask Codex to do anything"');
    expect(verify).toContain("...AGENT_LAUNCH_CHECKS,");
  });

  test("agent PTY readiness handles output, gates, exit, timeout and cancellation", () => {
    const result = spawnSync("python3", [fileURLToPath(new URL("./devbox-agent-launch-test.py", import.meta.url))], {
      encoding: "utf8", timeout: 30_000,
    });
    expect({ status: result.status, output: result.stderr }).toEqual({ status: 0, output: expect.stringContaining("OK") });
  }, 35_000);

  test("one public-platform SDK serves the bake, the verifier, and the driver", () => {
    // There is a single Freestyle arm now: the public platform on freestyle@0.2.x.
    // A stray `freestyle-beta` alias would silently send one of these three at
    // the retired beta-api endpoint.
    expect(readScript("build-devbox-freestyle.ts")).toContain('from "freestyle"');
    expect(readScript("build-devbox-freestyle.ts")).not.toContain("freestyle-beta");
    expect(readScript("verify-devbox-image.ts")).toContain('from "freestyle"');
    expect(readScript("verify-devbox-image.ts")).not.toContain("freestyle-beta");
    // The freestyle bake's systemd unit binds the daemon dual-stack: the
    // driver's route is the VM's public IPv6 straight to port 1337.
    expect(readScript("build-devbox-freestyle.ts")).toContain(
      "Environment=CMUX_TUI_REMOTE_WS_BIND=[::]:1337",
    );
    // Both the bake and the verifier must pin root: the 0.2 API's default guest
    // user is uid 1000, which the devbox image ships.
    expect(readScript("build-devbox-freestyle.ts")).toContain('linuxUser: "root"');
    expect(readScript("verify-devbox-image.ts")).toContain('linuxUser: "root"');
    const driver = readFileSync(
      path.join(import.meta.dirname, "../services/vms/drivers/freestyle.ts"),
      "utf8",
    );
    expect(driver).toContain('from "freestyle"');
    expect(driver).not.toContain("freestyle-beta");
    const packageJson = JSON.parse(
      readFileSync(path.join(import.meta.dirname, "../package.json"), "utf8"),
    ) as { dependencies: Record<string, string> };
    expect(packageJson.dependencies.freestyle).toBe("0.2.10");
    expect(packageJson.dependencies["freestyle-beta"]).toBeUndefined();
  });

  test("agent config generator is sourced for every shell family", () => {
    expect(dockerfile).toContain(
      "'[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' > /etc/profile.d/cmux-agents.sh",
    );
    for (const target of ["/etc/bash.bashrc", "/etc/skel/.bashrc", "/root/.bashrc"]) {
      expect(dockerfile).toContain(
        `'[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> ${target}`,
      );
      expect(dockerfile).toContain(`'[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> ${target}`);
    }
    // The image must prove generation in a throwaway HOME and ship none.
    expect(dockerfile).toContain("test ! -e /root/.codex/config.toml");
    expect(dockerfile).toContain(
      "grep -q 'supports_websockets = false' /tmp/agent-config-check/.codex/config.toml",
    );
    expect(dockerfile).toContain("test ! -e /root/.pi/agent/models.json");
    expect(dockerfile).toContain("test ! -e /root/.config/opencode/opencode.json");
    expect(dockerfile).toContain("test ! -e /root/.config/cmux/model-plane.env");
    // The build check proves the pi config generates with the placeholder JWT
    // and no route-token header (the edge injects it), that every model-plane
    // var is persisted, and that an unreachable config endpoint writes no
    // opencode config. The same check runs in the Freestyle bake and verify.
    for (const check of [
      `grep -qF '"apiKey": "e30.' /tmp/agent-config-check/.pi/agent/models.json`,
      "! grep -q 'x-coderouter-route-token' /tmp/agent-config-check/.pi/agent/models.json",
      "! grep -q 'crt_' /tmp/agent-config-check/.pi/agent/models.json",
      "test ! -e /tmp/agent-config-check/.config/opencode/opencode.json",
      `grep -q "export CMUX_VM_ID='vm-check'" /tmp/agent-config-check/.config/cmux/model-plane.env`,
      `grep -q "export ANTHROPIC_BASE_URL='https://example.invalid'" /tmp/agent-config-check/.config/cmux/model-plane.env`,
    ]) {
      expect(dockerfile).toContain(check);
    }
    for (const script of ["build-devbox-freestyle.ts", "verify-devbox-image.ts"]) {
      const source = readScript(script);
      expect(source).toContain("OPENAI_API_KEY=cmux-vm-edge-placeholder");
      expect(source).toContain("CMUX_VM_ID=vm-check");
      expect(source).toContain("x-coderouter-route-token");
      expect(source).not.toContain("OPENAI_API_KEY=crt_check");
    }
    // No bake self-check may feed a token-shaped key into the generator.
    expect(dockerfile).not.toContain("crt_check");
    expect(dockerfile).not.toContain("crt_persisted");
  });

  test("agent config exports the platform CA to Node only when the file exists", () => {
    const agentConfig = read("agent-config.sh");
    expect(agentConfig).toContain(
      "NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/freestyle-tls.crt",
    );
    // The export is guarded by the file's existence and does not override a
    // user's own setting; on this host the file is absent, so nothing leaks.
    const home = mkdtempSync(path.join(tmpdir(), "cmux-devbox-ca-"));
    try {
      const result = spawnSync(
        "sh",
        ["-c", `. ${path.join(templateDir, "agent-config.sh")}; printf '%s' "\${NODE_EXTRA_CA_CERTS-unset}"`],
        { env: { ...process.env, HOME: home, NODE_EXTRA_CA_CERTS: undefined } },
      );
      expect(result.status).toBe(0);
      expect(result.stdout.toString()).toBe(
        existsSync("/usr/local/share/ca-certificates/freestyle-tls.crt")
          ? "/usr/local/share/ca-certificates/freestyle-tls.crt"
          : "unset",
      );
      const kept = spawnSync(
        "sh",
        ["-c", `. ${path.join(templateDir, "agent-config.sh")}; printf '%s' "$NODE_EXTRA_CA_CERTS"`],
        { env: { ...process.env, HOME: home, NODE_EXTRA_CA_CERTS: "/tmp/mine.crt" } },
      );
      expect(kept.stdout.toString()).toBe("/tmp/mine.crt");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("agent config generator materializes the coderouter plane from boot env", () => {
    const home = mkdtempSync(path.join(tmpdir(), "cmux-devbox-agent-config-"));
    try {
      const result = spawnSync(
        "bash",
        ["-c", `. ${path.join(templateDir, "agent-config.sh")}`],
        {
          env: {
            ...process.env,
            HOME: home,
            OPENAI_BASE_URL: "https://example.invalid/v1",
            OPENAI_API_KEY: "cmux-vm-edge-placeholder",
            CMUX_CODEROUTER_URL: "https://example.invalid",
            ANTHROPIC_BASE_URL: "https://example.invalid",
            ANTHROPIC_API_KEY: "cmux-vm-edge-placeholder",
            CMUX_VM_ID: "11111111-2222-4333-8444-555555555555",
          },
        },
      );
      expect(result.status).toBe(0);
      const codex = readFileSync(path.join(home, ".codex/config.toml"), "utf8");
      expect(codex).toContain('model_provider = "cmux"');
      expect(codex).toContain('base_url = "https://example.invalid/v1"');
      expect(codex).toContain('wire_api = "responses"');
      // The /v1 plane is HTTP-only; pin the Responses WebSocket transport off
      // instead of relying on the custom-provider default.
      expect(codex).toContain("supports_websockets = false");
      expect(codex).toContain('persistence = "save-all"');
      // Every model-plane var is persisted generically, single-quoted.
      const plane = readFileSync(path.join(home, ".config/cmux/model-plane.env"), "utf8");
      expect(plane).toBe(
        [
          "# generated by cmux from machine boot env; managed, do not edit",
          "export OPENAI_BASE_URL='https://example.invalid/v1'",
          "export OPENAI_API_KEY='cmux-vm-edge-placeholder'",
          "export CMUX_CODEROUTER_URL='https://example.invalid'",
          "export ANTHROPIC_BASE_URL='https://example.invalid'",
          "export ANTHROPIC_API_KEY='cmux-vm-edge-placeholder'",
          "export CMUX_VM_ID='11111111-2222-4333-8444-555555555555'",
          "",
        ].join("\n"),
      );
      // pi: the built-in openai-codex provider is pointed at the plane with
      // the public placeholder JWT (pi requires a JWT-shaped key
      // client-side). No route-token header is configured: the edge injects
      // it, so the file carries no secret and no header line.
      const pi = readFileSync(path.join(home, ".pi/agent/models.json"), "utf8");
      expect(JSON.parse(pi)).toEqual({
        providers: {
          "openai-codex": {
            name: "cmux",
            baseUrl: "https://example.invalid/v1",
            apiKey:
              "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiY29kZXJvdXRlciJ9fQ.signature",
          },
        },
      });
      expect(pi).not.toContain("x-coderouter-route-token");
      expect(pi).not.toContain("crt_");
      // claude: env only, nothing generated.
      expect(existsSync(path.join(home, ".claude"))).toBe(false);
      // opencode: the config endpoint is unreachable here, so nothing may be
      // written (the next shell retries).
      expect(existsSync(path.join(home, ".config/opencode/opencode.json"))).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("opencode config is fetched from the coderouter endpoint and de-tokenized", async () => {
    const home = mkdtempSync(path.join(tmpdir(), "cmux-devbox-opencode-"));
    let authorization: string | undefined;
    const server = await listen((request, response) => {
      authorization = request.headers.authorization;
      response.setHeader("content-type", "application/json");
      response.end(
        JSON.stringify({
          provider: {
            go: {
              npm: "@ai-sdk/openai-compatible",
              options: {
                baseURL: "http://127.0.0.1:9/api/coderouter/opencode/proxy/go",
                apiKey: "crt_test-token",
              },
            },
          },
        }),
      );
    });
    try {
      await sourceAgentConfig(home, server.origin);
      // The guest sends only the placeholder; the edge adds the route token.
      expect(authorization).toBe("Bearer cmux-vm-edge-placeholder");
      const configPath = path.join(home, ".config/opencode/opencode.json");
      const written = readFileSync(configPath, "utf8");
      // A route token the endpoint inlined is swapped for a runtime env
      // reference (as is the placeholder itself), so no token lands on disk.
      expect(JSON.parse(written)).toEqual({
        provider: {
          go: {
            npm: "@ai-sdk/openai-compatible",
            options: {
              baseURL: "http://127.0.0.1:9/api/coderouter/opencode/proxy/go",
              apiKey: "{env:OPENAI_API_KEY}",
            },
          },
        },
      });
      expect(written).not.toContain("crt_test-token");
      // Write-if-missing: a second shell leaves the user's file alone.
      authorization = undefined;
      await sourceAgentConfig(home, server.origin);
      expect(authorization).toBeUndefined();
    } finally {
      await server.close();
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("opencode config tolerates a coderouter without a usable account", async () => {
    const home = mkdtempSync(path.join(tmpdir(), "cmux-devbox-opencode-503-"));
    let body = JSON.stringify({ error: "no_usable_account" });
    let status = 503;
    const server = await listen((_request, response) => {
      response.statusCode = status;
      response.setHeader("content-type", "application/json");
      response.end(body);
    });
    try {
      const configPath = path.join(home, ".config/opencode/opencode.json");
      // 503 no_usable_account: nothing written, the shell exits clean.
      await sourceAgentConfig(home, server.origin);
      expect(existsSync(configPath)).toBe(false);
      // An empty catalog is not persisted either (it would block retries).
      body = JSON.stringify({ provider: {} });
      status = 200;
      await sourceAgentConfig(home, server.origin);
      expect(existsSync(configPath)).toBe(false);
    } finally {
      await server.close();
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("claude transcript retention is pinned everywhere", () => {
    expect(dockerfile).toContain('{ "cleanupPeriodDays": 99999, "skipDangerousModePermissionPrompt": true }');
    expect(readScript("build-devbox-freestyle.ts")).toContain('{ "cleanupPeriodDays": 99999, "skipDangerousModePermissionPrompt": true }');
  });

  test("never installs docker (deliberate image-scope choice)", () => {
    // This began as a hard limit: the old sandbox providers could not run
    // Docker at all. Freestyle VMs can (nested virtualization), so this is now
    // a scope choice about image size rather than a platform constraint —
    // revisit it deliberately if the devbox should ship a container runtime.
    expect(dockerfile.toLowerCase()).not.toContain("docker.io");
    expect(dockerfile.toLowerCase()).not.toContain("docker-ce");
    expect(dockerfile.toLowerCase()).not.toContain("get.docker.com");
  });
});

describe("model-plane env reaches provider creates", () => {
  // The workflow provisions coderouter model-plane env (placeholders) into
  // CreateOptions.envs plus the edge rule into CreateOptions.edgeRules; the
  // devbox agent-config generator consumes the env. Freestyle has no VM-level
  // create env, so the driver persists the file the guest sources instead and
  // passes the rule inline on the create.
  test("the model-plane env is baked once, the guest falls back to it, and the edge rule rides inline", () => {
    const driver = readFileSync(
      path.join(import.meta.dirname, "../services/vms/drivers/freestyle.ts"),
      "utf8",
    );
    expect(driver).not.toContain("writeModelPlaneEnv");
    expect(driver).toContain("tls: { rules: tlsRules }");
    expect(readScript("build-devbox-freestyle.ts")).toContain("renderVmGuestModelPlaneEnvFile(vmGuestModelPlaneEnv())");
    expect(readScript("verify-devbox-image.ts")).toContain("test -s /etc/cmux/model-plane.env");
    expect(read("agent-config.sh")).toContain("elif [ -f /etc/cmux/model-plane.env ]; then");
  });
});

// The terminfo overlay the guest resolves TERM against. It is the cmux app's
// Resources/terminfo-overlay (Ghostty's entry under xterm-ghostty and under
// the xterm-256color name cmux exports, bright colors as indexed 38;5;n) as
// infocmp source, because Linux tic cannot read the app's compiled files.
// Compiled here with the local tic and queried like a guest program would.
describe("devbox terminfo overlay", () => {
  const hasNcurses = spawnSync("tic", ["-V"]).status === 0 && spawnSync("infocmp", ["-V"]).status === 0;
  let compiled: string | undefined;
  beforeEach(() => {
    compiled = mkdtempSync(path.join(tmpdir(), "cmux-terminfo-"));
  });
  afterEach(() => {
    if (compiled) rmSync(compiled, { recursive: true, force: true });
    compiled = undefined;
  });
  const tput = (term: string, ...args: string[]) => {
    const result = spawnSync("tput", ["-T", term, ...args], { env: { ...process.env, TERMINFO: compiled!, TERMINFO_DIRS: compiled! } });
    expect({ term, args, status: result.status, stderr: result.stderr.toString() }).toMatchObject({ term, args, status: 0 });
    return result.stdout.toString("latin1");
  };
  const infocmp = (term: string) => {
    const result = spawnSync("infocmp", ["-x", "-A", compiled!, term]);
    expect({ term, status: result.status, stderr: result.stderr.toString() }).toMatchObject({ term, status: 0 });
    return result.stdout.toString();
  };

  (hasNcurses ? test : test.skip)("compiles with tic and serves cmux's capabilities under every exported name", () => {
    const tic = spawnSync("tic", ["-x", "-o", compiled!, path.join(templateDir, "cmux-terminfo.src")]);
    expect({ status: tic.status, stderr: tic.stderr.toString() }).toMatchObject({ status: 0 });
    for (const term of ["xterm-ghostty", "ghostty", "xterm-256color"]) {
      expect(tput(term, "colors").trim()).toBe("256");
      const caps = infocmp(term);
      expect(caps).toMatch(/\bTc\b/);
      expect(caps).toMatch(/\bSu\b/);
      expect(caps).toMatch(/\bfullkbd\b/);
      // Bright black is the indexed sequence, not SGR 90 (invisible ghost text).
      expect(tput(term, "setaf", "8")).toBe("\x1b[38;5;8m");
      expect(tput(term, "setab", "8")).toBe("\x1b[48;5;8m");
      expect(tput(term, "setaf", "7")).toBe("\x1b[37m");
      expect(tput(term, "setaf", "16")).toBe("\x1b[38;5;16m");
    }
  });

  test("the bake installs it before seeding ble.sh's per-TERM tput caches", () => {
    // Both recipes: ble.sh caches tput output per TERM, so a seed taken
    // against stock terminfo would replay stock SGR 90 forever.
    const bake = readScript("build-devbox-freestyle.ts");
    expect(bake.indexOf('await step("terminfo"')).toBeGreaterThan(0);
    expect(bake.indexOf('await step("terminfo"')).toBeLessThan(bake.indexOf('await step(\n    "devshell"'));
    expect(bake).toContain('await put("cmux-terminfo.sh", "/etc/profile.d/cmux-terminfo.sh")');
    expect(dockerfile.indexOf("tic -x -o /etc/terminfo")).toBeGreaterThan(0);
    expect(dockerfile.indexOf("tic -x -o /etc/terminfo")).toBeLessThan(dockerfile.indexOf("blesh-cache-seed"));
    expect(dockerfile).toContain("xterm-ghostty; do");
    expect(readFileSync(path.join(templateDir, "cmux-terminfo.sh"), "utf8")).toContain("TERMINFO_DIRS=/etc/terminfo:");
  });
});
