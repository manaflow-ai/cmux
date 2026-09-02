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
import { DEVBOX_TEMPLATE_FILES, devboxAgentPins } from "../scripts/devbox-image-common";

// Contract tests for the shared cmux Cloud devbox image template
// (services/vms/images/devbox), consumed by build-devbox-e2b.ts,
// build-devbox-daytona.ts, and build-devbox-freestyle.ts. These pin the
// pieces other code depends on: the cmux-tui daemon contract each driver
// expects, Blaxel-template parity for the shared shell/agent files, and the
// E2B Dockerfile-parser restrictions. Same rationale as
// vm-blaxel-image.test.ts: the template IS the artifact.

const templateDir = path.join(import.meta.dirname, "../services/vms/images/devbox");
const blaxelDir = path.join(import.meta.dirname, "../services/vms/images/blaxel");
const scriptsDir = path.join(import.meta.dirname, "../scripts");
const read = (name: string) => readFileSync(path.join(templateDir, name), "utf8");
const readBlaxel = (name: string) => readFileSync(path.join(blaxelDir, name), "utf8");
const readScript = (name: string) => readFileSync(path.join(scriptsDir, name), "utf8");

const dockerfile = read("Dockerfile");
const bashrc = read("cmux-bashrc");
const agentConfig = read("agent-config.sh");
const devboxBoot = read("cmux-devbox-boot");

// Comment/blank stripping: the devbox copies of the Blaxel-shared files may
// differ only in their header comments (each names its parity source).
const body = (text: string): string =>
  text
    .split("\n")
    .filter((line) => line.trim() !== "" && !line.trimStart().startsWith("#"))
    .join("\n");

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
        OPENAI_API_KEY: "crt_test-token",
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
      "seed-history",
    ]);
    // The bake scripts' preflight covers the same set (minus the README).
    expect([...DEVBOX_TEMPLATE_FILES].sort()).toEqual([
      "Dockerfile",
      "agent-config.sh",
      "chrome-managed-policy.json",
      "cmux-bashrc",
      "cmux-devbox-boot",
      "seed-history",
    ]);
  });

  test("every shell file parses", () => {
    for (const name of ["cmux-bashrc", "agent-config.sh"]) {
      const result = spawnSync("bash", ["-n", path.join(templateDir, name)]);
      expect({ name, status: result.status }).toEqual({ name, status: 0 });
    }
    const result = spawnSync("sh", ["-n", path.join(templateDir, "cmux-devbox-boot")]);
    expect(result.status).toBe(0);
  });

  test("shared files stay in lockstep with the Blaxel template", () => {
    // Byte-identical data files; comment-normalized shell files (headers
    // name their own parity source).
    expect(read("seed-history")).toBe(readBlaxel("seed-history"));
    expect(read("chrome-managed-policy.json")).toBe(readBlaxel("chrome-managed-policy.json"));
    expect(body(bashrc)).toBe(body(readBlaxel("cmux-bashrc")));
    expect(body(agentConfig)).toBe(body(readBlaxel("agent-config.sh")));
  });

  test("agent and CUA driver pins match the Blaxel template", () => {
    const blaxelDockerfile = readBlaxel("Dockerfile");
    const args = [
      "CMUX_IMAGE_CLAUDE_CODE_VERSION",
      "CMUX_IMAGE_CODEX_VERSION",
      "CMUX_IMAGE_OPENCODE_VERSION",
      "CMUX_IMAGE_PI_VERSION",
      "CMUX_IMAGE_AGENT_BROWSER_VERSION",
    ];
    for (const arg of args) {
      const devboxPin = new RegExp(`^ARG ${arg}=(\\S+)$`, "m").exec(dockerfile)?.[1];
      const blaxelPin = new RegExp(`^ARG ${arg}=(\\S+)$`, "m").exec(blaxelDockerfile)?.[1];
      expect({ arg, pin: devboxPin }).toEqual({ arg, pin: blaxelPin });
      expect(devboxPin).toMatch(/^\d+\.\d+\.\d+$/);
    }
    // The build scripts derive their pins from the same ARGs.
    expect(devboxAgentPins(dockerfile).map((pin) => pin.pkg)).toEqual([
      "@anthropic-ai/claude-code",
      "@openai/codex",
      "opencode-ai",
      "@earendil-works/pi-coding-agent",
      "agent-browser",
    ]);

    const cuaVersion = (source: string): string | undefined =>
      /CUA_DRIVER_RS_VERSION=(\S+)/.exec(source)?.[1];
    const devboxCuaVersion = cuaVersion(dockerfile);
    expect({ tool: "cua-driver", pin: devboxCuaVersion }).toEqual({
      tool: "cua-driver",
      pin: cuaVersion(blaxelDockerfile),
    });
    expect(readScript("build-devbox-freestyle.ts")).toContain(
      `CUA_DRIVER_RS_VERSION=${devboxCuaVersion}`,
    );
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

  test("stays within the E2B Dockerfile-parser restrictions", () => {
    // The E2B translation strips backslash escape sequences inside RUN
    // strings (printf '\n' corrupts written files), would turn ENTRYPOINT
    // into a template start command (provider boot commands come from the
    // build scripts), and needs a literal PATH.
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
    // beta's systemd unit sets); everything else must match the drivers'
    // command byte for byte, so passing the shell expansion as the bind
    // reconstructs the script's exact line.
    expect(devboxBoot).toContain(
      cmuxTuiDaemonCommand('"${CMUX_TUI_REMOTE_WS_BIND:-0.0.0.0:1337}"').replace("cd /root && ", ""),
    );
    expect(cmuxTuiDaemonCommand()).toContain("--remote-ws 0.0.0.0:1337");
    expect(devboxBoot).toContain("if [ -x /root/.cmux/bin/cmux-tui ]");
    expect(dockerfile).toContain("COPY cmux-devbox-boot /usr/local/bin/cmux-devbox-boot");
    // No binary is baked and the old cmuxd stack is gone everywhere.
    // The image itself carries nothing cmuxd-era, and no bake or verify
    // script installs or launches the old daemon (prose references to the
    // legacy driver are fine).
    expect(dockerfile).not.toContain("cmuxd");
    expect(devboxBoot).not.toContain("cmuxd");
    for (const name of [
      "build-devbox-e2b.ts",
      "build-devbox-daytona.ts",
      "build-devbox-freestyle.ts",
      "verify-devbox-image.ts",
    ]) {
      expect({ name, installsCmuxd: readScript(name).includes("/usr/local/bin/cmuxd-remote") })
        .toEqual({ name, installsCmuxd: false });
    }
  });

  test("each provider boot path supervises the daemon per its lifecycle", () => {
    // Daytona: stop kills processes; the registered entrypoint brings the
    // daemon back on start.
    const daytonaScript = readScript("build-devbox-daytona.ts");
    expect(daytonaScript).toContain('entrypoint: ["/usr/local/bin/cmux-devbox-boot"]');
    // E2B: pause/resume preserves processes; the driver starts the daemon,
    // so the template has no start command.
    const e2bScript = readScript("build-devbox-e2b.ts");
    expect(e2bScript).not.toContain("setStartCmd");
    // Freestyle (beta): systemd runs the supervisor.
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

  test("the beta SDK serves the bake, verify, and beta driver arm; the legacy arm stays on 0.1.51", () => {
    expect(readScript("build-devbox-freestyle.ts")).toContain('from "freestyle-beta"');
    expect(readScript("verify-devbox-image.ts")).toContain('from "freestyle-beta"');
    // The freestyle bake's systemd unit binds the daemon dual-stack: the beta
    // driver's route is the VM's public IPv6 straight to port 1337.
    expect(readScript("build-devbox-freestyle.ts")).toContain(
      "Environment=CMUX_TUI_REMOTE_WS_BIND=[::]:1337",
    );
    // The freestyle driver spans both platforms: the legacy arm (existing
    // production machines) keeps the 0.1.51 SDK, the beta arm rides the alias.
    const driver = readFileSync(
      path.join(import.meta.dirname, "../services/vms/drivers/freestyle.ts"),
      "utf8",
    );
    expect(driver).toContain('from "freestyle"');
    expect(driver).toContain('from "./freestyleBeta"');
    const betaArm = readFileSync(
      path.join(import.meta.dirname, "../services/vms/drivers/freestyleBeta.ts"),
      "utf8",
    );
    expect(betaArm).toContain('from "freestyle-beta"');
    expect(betaArm).not.toContain('from "freestyle";');
    const packageJson = JSON.parse(
      readFileSync(path.join(import.meta.dirname, "../package.json"), "utf8"),
    ) as { dependencies: Record<string, string> };
    expect(packageJson.dependencies.freestyle).toBe("0.1.51");
    expect(packageJson.dependencies["freestyle-beta"]).toBe("npm:freestyle@0.2.0-beta.7");
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
    expect(dockerfile).toContain("test ! -e /root/.pi/agent/models.json");
    expect(dockerfile).toContain("test ! -e /root/.config/opencode/opencode.json");
    expect(dockerfile).toContain("test ! -e /root/.config/cmux/model-plane.env");
    // The build check proves the pi config generates and carries no token,
    // and that an unreachable config endpoint writes no opencode config.
    expect(dockerfile).toContain(
      `grep -qF '"x-coderouter-route-token": "$OPENAI_API_KEY"' /tmp/agent-config-check/.pi/agent/models.json`,
    );
    expect(dockerfile).toContain("! grep -q 'crt_check' /tmp/agent-config-check/.pi/agent/models.json");
    expect(dockerfile).toContain(
      "test ! -e /tmp/agent-config-check/.config/opencode/opencode.json",
    );
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
            OPENAI_API_KEY: "crt_test",
            CMUX_CODEROUTER_URL: "https://example.invalid",
          },
        },
      );
      expect(result.status).toBe(0);
      const codex = readFileSync(path.join(home, ".codex/config.toml"), "utf8");
      expect(codex).toContain('model_provider = "cmux"');
      expect(codex).toContain('base_url = "https://example.invalid/v1"');
      expect(codex).toContain('wire_api = "responses"');
      expect(codex).toContain('persistence = "save-all"');
      const plane = readFileSync(path.join(home, ".config/cmux/model-plane.env"), "utf8");
      expect(plane).toContain("export OPENAI_API_KEY='crt_test'");
      expect(plane).toContain("export CMUX_CODEROUTER_URL='https://example.invalid'");
      // pi: the built-in openai-codex provider is pointed at the plane. The
      // route token rides the x-coderouter-route-token header as an env
      // reference pi resolves at request time; the apiKey is the public
      // placeholder JWT (pi requires a JWT-shaped key client-side), so the
      // file carries no secret.
      const pi = readFileSync(path.join(home, ".pi/agent/models.json"), "utf8");
      expect(JSON.parse(pi)).toEqual({
        providers: {
          "openai-codex": {
            name: "cmux",
            baseUrl: "https://example.invalid/v1",
            apiKey:
              "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiY29kZXJvdXRlciJ9fQ.signature",
            headers: { "x-coderouter-route-token": "$OPENAI_API_KEY" },
          },
        },
      });
      expect(pi).not.toContain("crt_test");
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
      expect(authorization).toBe("Bearer crt_test-token");
      const configPath = path.join(home, ".config/opencode/opencode.json");
      const written = readFileSync(configPath, "utf8");
      // The inlined route token is swapped for a runtime env reference, so a
      // resurrected machine with a fresh token needs no rewrite.
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

  test("never installs docker (E2B/Daytona sandboxes cannot run it)", () => {
    expect(dockerfile.toLowerCase()).not.toContain("docker.io");
    expect(dockerfile.toLowerCase()).not.toContain("docker-ce");
    expect(dockerfile.toLowerCase()).not.toContain("get.docker.com");
  });
});

describe("model-plane env reaches provider creates", () => {
  // The vm route mints coderouter model-plane env into CreateOptions.envs
  // for every provider; the devbox agent-config generator consumes it. E2B
  // and Daytona forward it to the provider create call (Freestyle has no
  // VM-level create env; its machines rely on the persisted copy).
  test("e2b create forwards options.envs", () => {
    const driver = readFileSync(
      path.join(import.meta.dirname, "../services/vms/drivers/e2b.ts"),
      "utf8",
    );
    expect(driver).toContain("envs: { ...DEFAULT_SANDBOX_ENVS, ...(options.envs ?? {}) }");
  });

  test("daytona create forwards options.envs", () => {
    const driver = readFileSync(
      path.join(import.meta.dirname, "../services/vms/drivers/daytona.ts"),
      "utf8",
    );
    expect(driver).toContain("envVars: { ...DEFAULT_SANDBOX_ENVS, ...(options.envs ?? {}) }");
  });
});
