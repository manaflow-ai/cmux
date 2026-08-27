import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  DEVBOX_SERVE_COMMAND,
  devboxAgentPins,
} from "../scripts/devbox-image-common";

// Contract tests for the shared cmux Cloud devbox image template
// (services/vms/images/devbox), consumed by build-devbox-e2b.ts,
// build-devbox-daytona.ts, and build-devbox-freestyle.ts. These pin the
// pieces other code depends on: the cmuxd-remote attach contract each driver
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
const cloudShell = read("cmux-cloud-shell");
const daytonaEntrypoint = read("cmux-daytona-entrypoint");

// Comment/blank stripping: the devbox copies of the Blaxel-shared files may
// differ only in their header comments (each names its parity source).
const body = (text: string): string =>
  text
    .split("\n")
    .filter((line) => line.trim() !== "" && !line.trimStart().startsWith("#"))
    .join("\n");

describe("devbox image template", () => {
  test("template directory contains exactly the expected files", () => {
    const entries = readdirSync(templateDir)
      .filter((name) => name !== ".build")
      .sort();
    expect(entries).toEqual([
      ".gitignore",
      "Dockerfile",
      "README.md",
      "agent-config.sh",
      "chrome-managed-policy.json",
      "cmux-bashrc",
      "cmux-cloud-shell",
      "cmux-daytona-entrypoint",
      "cmux-zshrc",
      "seed-history",
    ]);
  });

  test("every shell file parses", () => {
    for (const name of ["cmux-bashrc", "agent-config.sh"]) {
      const result = spawnSync("bash", ["-n", path.join(templateDir, name)]);
      expect({ name, status: result.status }).toEqual({ name, status: 0 });
    }
    for (const name of ["cmux-cloud-shell", "cmux-daytona-entrypoint"]) {
      const result = spawnSync("sh", ["-n", path.join(templateDir, name)]);
      expect({ name, status: result.status }).toEqual({ name, status: 0 });
    }
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
    expect(devboxAgentPins(dockerfile).map((pin) => pin.spec)).toEqual([
      `@anthropic-ai/claude-code@${/CMUX_IMAGE_CLAUDE_CODE_VERSION=(\S+)/.exec(dockerfile)![1]}`,
      `@openai/codex@${/CMUX_IMAGE_CODEX_VERSION=(\S+)/.exec(dockerfile)![1]}`,
      `opencode-ai@${/CMUX_IMAGE_OPENCODE_VERSION=(\S+)/.exec(dockerfile)![1]}`,
      `@earendil-works/pi-coding-agent@${/CMUX_IMAGE_PI_VERSION=(\S+)/.exec(dockerfile)![1]}`,
      `agent-browser@${/CMUX_IMAGE_AGENT_BROWSER_VERSION=(\S+)/.exec(dockerfile)![1]}`,
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
    // into a template start command (each build script owns the boot
    // command), and needs a literal PATH.
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

  test("bakes the cmuxd-remote attach control plane every driver expects", () => {
    expect(dockerfile).toContain(
      "COPY .build/cmuxd-remote-linux-amd64 /usr/local/bin/cmuxd-remote",
    );
    expect(dockerfile).toContain("COPY cmux-cloud-shell /usr/local/bin/cmux-cloud-shell");
    expect(dockerfile).toContain(
      "COPY cmux-daytona-entrypoint /usr/local/bin/cmux-daytona-entrypoint",
    );
    expect(dockerfile).toContain("ln -sf /usr/local/bin/cmuxd-remote /usr/local/bin/cmux");
    expect(read(".gitignore")).toContain(".build/");
  });

  test("one serve command across providers, matching the driver lease contract", () => {
    // Port and lease paths are driver constants
    // (web/services/vms/drivers/{e2b,daytona,freestyle}.ts).
    expect(DEVBOX_SERVE_COMMAND).toContain("--listen 0.0.0.0:7777");
    expect(DEVBOX_SERVE_COMMAND).toContain("--auth-lease-file /tmp/cmux/attach-pty-lease.json");
    expect(DEVBOX_SERVE_COMMAND).toContain(
      "--rpc-auth-lease-file /tmp/cmux/attach-rpc-lease.json",
    );
    expect(DEVBOX_SERVE_COMMAND).toContain("--shell /usr/local/bin/cmux-cloud-shell");
    // The Daytona supervisor runs the identical command.
    expect(daytonaEntrypoint).toContain(DEVBOX_SERVE_COMMAND);
    // The E2B build script boots it as the template start command with a
    // healthz readiness gate; the Freestyle bake uses it as ExecStart for
    // the signed-admin unit.
    const e2bScript = readScript("build-devbox-e2b.ts");
    expect(e2bScript).toContain("DEVBOX_SERVE_COMMAND");
    expect(e2bScript).toContain('waitForURL("http://127.0.0.1:7777/healthz", 200)');
    const freestyleScript = readScript("build-devbox-freestyle.ts");
    expect(freestyleScript).toContain("`ExecStart=${DEVBOX_SERVE_COMMAND}`");
    expect(freestyleScript).toContain("CMUXD_WS_ADMIN_ED25519_PUBLIC_KEY");
    expect(freestyleScript).toContain("bakedFreestyleSignedAdmin: true");
  });

  test("freestyle bake and verify ride the beta SDK; the driver stays legacy", () => {
    // The devbox freestyle bake targets the beta platform
    // (freestyle@0.2.0-beta.7 aliased as freestyle-beta). The shipped
    // driver keeps the legacy 0.1.51 SDK: beta creates drop ports,
    // readySignalTimeoutSeconds, and systemd injection, so the driver
    // migration is a separate change, and mixing the platforms would break
    // live attach.
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

  test("daytona entrypoint self-heals across sandbox restarts", () => {
    expect(daytonaEntrypoint).toContain("mkdir -p /tmp/cmux");
    expect(daytonaEntrypoint).toContain("chmod 700 /tmp/cmux");
    expect(daytonaEntrypoint).toContain("while true; do");
    expect(daytonaEntrypoint).toContain("sleep 2");
    const daytonaScript = readScript("build-devbox-daytona.ts");
    expect(daytonaScript).toContain('entrypoint: ["/usr/local/bin/cmux-daytona-entrypoint"]');
  });

  test("cmux-cloud-shell drops root daemons to cmux and survives non-root daemons", () => {
    expect(cloudShell).toContain("runuser -u cmux -- /bin/bash -l");
    expect(cloudShell).toContain('exec /bin/bash -l');
    expect(cloudShell).toContain('id -u cmux >/dev/null');
    expect(dockerfile).toContain("useradd -m -s /bin/bash cmux");
  });

  test("satisfies the Freestyle managed-shell probe so repair never clobbers bash", () => {
    // web/services/vms/drivers/freestyle.ts readFreestyleCloudShellState
    // requires zsh, /etc/cmux/zshrc, /home/cmux/.zshrc, the cmux user, and a
    // cmuxd-ws service pointing at cmux-cloud-shell; a miss triggers the
    // driver's zsh repair path, overwriting the devbox shell.
    expect(dockerfile).toMatch(/apt-get install[^&]*\bzsh\b/);
    expect(dockerfile).toContain("COPY cmux-zshrc /etc/cmux/zshrc");
    expect(dockerfile).toContain("> /home/cmux/.zshrc");
    const driver = readFileSync(
      path.join(import.meta.dirname, "../services/vms/drivers/freestyle.ts"),
      "utf8",
    );
    for (const probeAsset of ["/etc/cmux/zshrc", "/home/cmux/.zshrc", "cmux-cloud-shell"]) {
      expect(driver).toContain(probeAsset);
    }
  });

  test("agent config generator is sourced for every shell family", () => {
    expect(dockerfile).toContain(
      "'[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' > /etc/profile.d/cmux-agents.sh",
    );
    for (const target of [
      "/etc/bash.bashrc",
      "/etc/skel/.bashrc",
      "/root/.bashrc",
      "/home/cmux/.bashrc",
    ]) {
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
