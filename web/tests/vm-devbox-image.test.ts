import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
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

  test("agent pins match the Blaxel template ARG for ARG", () => {
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
  });

  test("ble.sh highlights stay foreground-only for dark terminal themes", () => {
    expect(bashrc).toContain("ble-face auto_complete=fg=");
    expect(bashrc).toContain("ble-face syntax_error=fg=");
    expect(bashrc).toContain("ble-face argument_error=fg=");
    for (const line of bashrc.split("\n").filter((l) => l.trimStart().startsWith("ble-face"))) {
      expect(line).not.toContain("bg=");
    }
    expect(bashrc).toContain("source /usr/local/share/blesh/ble.sh --noattach");
    expect(bashrc).toContain("ble-attach");
    expect(bashrc).toContain('cp /etc/cmux/seed-history "$HOME/.bash_history"');
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
    expect(devboxBoot).toContain(cmuxTuiDaemonCommand().replace("cd /root && ", ""));
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

  test("freestyle bake and verify ride the beta SDK; the legacy driver stays on 0.1.51", () => {
    expect(readScript("build-devbox-freestyle.ts")).toContain('from "freestyle-beta"');
    expect(readScript("verify-devbox-image.ts")).toContain('from "freestyle-beta"');
    const driver = readFileSync(
      path.join(import.meta.dirname, "../services/vms/drivers/freestyle.ts"),
      "utf8",
    );
    expect(driver).toContain('from "freestyle"');
    expect(driver).not.toContain("freestyle-beta");
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
    expect(dockerfile).toContain("test ! -e /root/.config/cmux/model-plane.env");
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
    } finally {
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
