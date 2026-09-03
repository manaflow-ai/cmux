import { describe, expect, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  CMUX_TUI_PORT,
  CMUX_TUI_SESSION,
  cmuxTuiDaemonCommand,
} from "../services/vms/drivers/cmuxTuiDaemon";
import { DEVBOX_TEMPLATE_FILES, devboxAgentPins, devboxCuaDriverVersion, devboxParkDaemonCommand } from "../scripts/devbox-image-common";

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
      "seed-history",
    ]);
  });

  test("every shell file parses", () => {
    for (const name of ["cmux-bashrc", "agent-config.sh"]) {
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
    // bake itself (probing as root with HOME=/home/ubuntu leaves root-owned
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
    expect(readScript("verify-devbox-image.ts")).toContain("ubuntu-login-silent-");
    expect(readScript("verify-devbox-image.ts")).toContain("home-owned-by-ubuntu");
    expect(readScript("verify-devbox-image.ts")).toContain("devshell-sourced-once");
    // The verifier checks both shell families without PATH help of its own.
    const verify = readScript("verify-devbox-image.ts");
    expect(verify).toContain("-login-pin-ok");
    expect(verify).toContain("-nonlogin-pin-ok");
    expect(verify).toContain("test ! -e /opt/mise");
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

  test("bakes ble.sh cache seeds for every shared devbox provider", () => {
    // The shared bashrc guard is useful only when each bake creates the seed.
    for (const term of ["xterm-256color", "screen-256color", "tmux-256color", "linux"]) {
      expect(dockerfile).toContain(`test -s /etc/cmux/blesh-cache-seed/blesh/*/term.${term}`);
    }
    expect(dockerfile).toContain("/usr/local/share/blesh/cache.d/0");
    expect(readScript("build-devbox-freestyle.ts")).toContain("blesh-cache-seed");
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
      cmuxTuiDaemonCommand('"${CMUX_TUI_REMOTE_WS_BIND:-0.0.0.0:1337}"').replace("cd /root && ", ""),
    );
    expect(cmuxTuiDaemonCommand()).toContain("--remote-ws 0.0.0.0:1337");
    expect(devboxBoot).toContain("BIN=/root/.cmux/bin/cmux-tui");
    expect(devboxBoot).toContain('if [ -x "$BIN" ]');
    expect(dockerfile).toContain("COPY cmux-devbox-boot /usr/local/bin/cmux-devbox-boot");
    // A Freestyle snapshot is a memory image: the supervisor keys the daemon
    // identity on the platform instance id, wiping cmux-remote's default root
    // state dir on a clone, and holds the daemon on the builder itself.
    expect(devboxBoot).toContain("REMOTE_STATE_DIR=/root/.local/state/cmux/remote");
    expect(devboxBoot).toContain("/latest/meta-data/instance-id");
    expect(devboxBoot).toContain("BOUND_INSTANCE_FILE=/etc/cmux/daemon-instance-id");
    expect(devboxBoot).toContain("BAKE_INSTANCE_FILE=/etc/cmux/bake-instance-id");
    expect(devboxBoot).toContain('rm -rf "$REMOTE_STATE_DIR"');
    // The supervisor owns the daemon as a background child so it can stop a
    // daemon that belongs to another machine (a clone of a live machine).
    expect(devboxBoot).toContain("daemon_pid=$!");
    expect(devboxBoot).toContain("stop_daemon");
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
    expect(packageJson.dependencies.freestyle).toBe("0.2.9");
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
    expect(dockerfile).toContain('{ "cleanupPeriodDays": 99999 }');
    expect(readScript("build-devbox-freestyle.ts")).toContain('{ "cleanupPeriodDays": 99999 }');
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
  test("freestyle persists the model-plane env file its guests source and passes edge rules inline", () => {
    const driver = readFileSync(
      path.join(import.meta.dirname, "../services/vms/drivers/freestyle.ts"),
      "utf8",
    );
    expect(driver).toContain("renderFreestyleModelPlaneEnvFile");
    expect(driver).toContain("/root/.config/cmux/model-plane.env");
    expect(driver).toContain("tls: { rules: tlsRules }");
  });
});
