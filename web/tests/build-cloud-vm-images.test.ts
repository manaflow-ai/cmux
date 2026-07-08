import { describe, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Freestyle } from "freestyle";
import {
  cloudAgentToolPackageSpecs,
  cloudImageRuntimeEnvironment,
  cloudImageSmokeTestCommands,
  cloudShellPackageNames,
  cloudToolInstallCommands,
  daytonaEntrypointCommands,
  toDockerfileRunCommand,
  daytonaSnapshotImage,
  findFreestyleSnapshotByName,
  freestyleBaseDockerfileContent,
  freestyleRecoveryWindowStart,
  pinnedNpmPackageVersion,
  positiveIntFromEnv,
  semverFromEnv,
  systemdEnvironmentLines,
  waitForFreestyleSnapshotByName,
  waitForRetryInterval,
} from "../scripts/build-cloud-vm-images";

describe("Cloud VM image build helpers", () => {
  test("disabled tool env values skip the tool install", () => {
    const previous = process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC;
    process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC = "none";
    try {
      expect(cloudAgentToolPackageSpecs().some((tool) => tool.name === "claude")).toBe(false);
    } finally {
      if (previous === undefined) {
        delete process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC;
      } else {
        process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC = previous;
      }
    }
  });

  test("enabled tool specs must be pinned to exact versions", () => {
    const previous = process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC;
    process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC = "@anthropic-ai/claude-code";
    try {
      expect(() => cloudAgentToolPackageSpecs()).toThrow("must be pinned");
    } finally {
      if (previous === undefined) {
        delete process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC;
      } else {
        process.env.CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC = previous;
      }
    }
  });

  test("pinned package specs reject npm tags and ranges", () => {
    expect(pinnedNpmPackageVersion("@openai/codex@0.130.0")).toBe("0.130.0");
    expect(pinnedNpmPackageVersion("@openai/codex@1.2.3-rc.1+build.123")).toBe(
      "1.2.3-rc.1+build.123",
    );
    expect(pinnedNpmPackageVersion("@openai/codex@latest")).toBeNull();
    expect(pinnedNpmPackageVersion("@openai/codex@^0.130.0")).toBeNull();
    expect(pinnedNpmPackageVersion("@openai/codex@beta")).toBeNull();
  });

  test("positive integer env overrides fail closed when malformed", () => {
    const key = "CMUX_TEST_POSITIVE_INT";
    const previous = process.env[key];
    try {
      delete process.env[key];
      expect(positiveIntFromEnv(key, 42)).toBe(42);

      process.env[key] = "17";
      expect(positiveIntFromEnv(key, 42)).toBe(17);

      process.env[key] = "10ms";
      expect(() => positiveIntFromEnv(key, 42)).toThrow("must be a positive integer");

      process.env[key] = "0";
      expect(() => positiveIntFromEnv(key, 42)).toThrow("must be a positive integer");
    } finally {
      if (previous === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = previous;
      }
    }
  });

  test("semver env overrides fail closed when malformed", () => {
    const key = "CMUX_TEST_SEMVER";
    const previous = process.env[key];
    try {
      delete process.env[key];
      expect(semverFromEnv(key, "1.2.3")).toBe("1.2.3");

      process.env[key] = "1.2.3-rc.1";
      expect(semverFromEnv(key, "1.2.3")).toBe("1.2.3-rc.1");

      process.env[key] = "latest";
      expect(() => semverFromEnv(key, "1.2.3")).toThrow("must be an exact semver");
    } finally {
      if (previous === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = previous;
      }
    }
  });

  test("Bun install command is version-pinned and checksum-verified", () => {
    const bunInstall = cloudToolInstallCommands().find((command) =>
      command.includes("cmux-bun-install.txt")
    );
    expect(bunInstall).toContain("bun-v1.3.13");
    expect(bunInstall).toContain("SHASUMS256.txt.asc");
    expect(bunInstall).toContain("sha256sum -c");
  });

  test("base image installs native build and Python packaging apt tools", () => {
    const packages = cloudShellPackageNames();

    for (const packageName of [
      "build-essential",
      "pkg-config",
      "python3-pip",
      "python3-venv",
      "golang-go",
    ]) {
      expect(packages.includes(packageName)).toBe(true);
    }
  });

  test("GitHub CLI is installed from the official apt repository", () => {
    const commands = cloudToolInstallCommands().join("\n");

    expect(commands).toContain("https://cli.github.com/packages/githubcli-archive-keyring.gpg");
    expect(commands).toContain("https://cli.github.com/packages stable main");
    expect(commands).toContain("apt-get install -y --no-install-recommends gh nodejs");
  });

  test("mise installs Node LTS through system shims", () => {
    const commands = cloudToolInstallCommands().join("\n");

    expect(commands).toContain("MISE_INSTALL_PATH=/usr/local/bin/mise");
    expect(commands).toContain("node = \"lts\"");
    expect(commands).toContain("mise install --system node@lts");
    expect(commands).toContain("MISE_DATA_DIR=/usr/local/share/mise mise reshim --force");
    expect(cloudImageRuntimeEnvironment().PATH.split(":")).toContain("/usr/local/share/mise/shims");
  });

  test("rustup uses a minimal stable toolchain in the shared cargo path", () => {
    const commands = cloudToolInstallCommands().join("\n");

    expect(commands).toContain("https://sh.rustup.rs");
    expect(commands).toContain("--profile minimal --default-toolchain stable --no-modify-path");
    expect(commands).toContain("RUSTUP_HOME='/opt/rustup'");
    expect(commands).toContain("CARGO_HOME='/opt/cargo'");
    expect(cloudImageRuntimeEnvironment().PATH.split(":")).toContain("/opt/cargo/bin");
    expect(cloudImageRuntimeEnvironment()).not.toHaveProperty("CARGO_HOME");
  });

  test("toolchain profile and environment are wired for non-login commands", () => {
    const profileInstall = cloudToolInstallCommands().find((command) =>
      command.includes("/etc/profile.d/cmux-toolchains.sh")
    );

    expect(profileInstall).toContain("/etc/environment");
    expect(profileInstall).toContain("/usr/local/share/mise/shims:/opt/cargo/bin");
    expect(cloudImageRuntimeEnvironment()).toMatchObject({
      RUSTUP_HOME: "/opt/rustup",
    });
    expect(profileInstall).not.toContain("export CARGO_HOME=");
  });

  test("Freestyle systemd service inherits toolchain runtime environment", () => {
    const dockerfile = freestyleBaseDockerfileContent("https://example.com/cmuxd-remote");
    const systemdEnv = systemdEnvironmentLines(cloudImageRuntimeEnvironment());

    for (const line of systemdEnv) {
      expect(dockerfile).toContain(line);
    }
    expect(dockerfile).toContain("Environment=PATH=/usr/local/share/mise/shims:/opt/cargo/bin");
    expect(dockerfile).toContain("Environment=RUSTUP_HOME=/opt/rustup");
    expect(dockerfile).not.toContain("Environment=CARGO_HOME=");
  });

  test("image smoke checks exercise the cmux browser entrypoint without a daemon", () => {
    const browserSmoke = cloudImageSmokeTestCommands().find((command) =>
      command.includes("cmux-browser-help.txt")
    );
    expect(browserSmoke).toContain("--socket /tmp/cmux-browser-smoke.sock browser");
    expect(browserSmoke).toContain("requires a subcommand");
  });

  test("image smoke checks include useful shell tools", () => {
    const smoke = cloudImageSmokeTestCommands().join("\n");
    expect(smoke).toContain("gh --version");
    expect(smoke).toContain("htop --version");
    expect(smoke).toContain("btop --version");
    expect(smoke).toContain("tmux -V");
    expect(smoke).toContain("zsh --version");
    expect(smoke).toContain("/usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh");
  });

  test("image smoke checks require the VM-local cmux CLI on PATH", () => {
    const smoke = cloudImageSmokeTestCommands().join("\n");
    expect(smoke).toContain("test -x /usr/local/bin/cmuxd-remote && test -x /usr/local/bin/cmux");
    expect(smoke).toContain("cmux --help");
  });

  test("Freestyle Dockerfile bakes signed-admin service from public key only", () => {
    const previousPublic = process.env.CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY;
    const previousPrivate = process.env.CMUX_FREESTYLE_ADMIN_SIGNING_PRIVATE_KEY_SEED;
    try {
      process.env.CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY = "LFxQT06qOOAKo9Wr+kaq7npatVr4nYW2kPSb3RoebVQ=";
      process.env.CMUX_FREESTYLE_ADMIN_SIGNING_PRIVATE_KEY_SEED = "private-seed-must-not-be-baked";
      const dockerfile = freestyleBaseDockerfileContent("https://example.com/cmuxd-remote");
      expect(dockerfile).toContain(
        "CMUXD_WS_ADMIN_ED25519_PUBLIC_KEY=LFxQT06qOOAKo9Wr+kaq7npatVr4nYW2kPSb3RoebVQ=",
      );
      expect(dockerfile).toContain("multi-user.target.wants/cmuxd-ws.service");
      expect(dockerfile).not.toContain("private-seed-must-not-be-baked");
    } finally {
      if (previousPublic === undefined) {
        delete process.env.CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY;
      } else {
        process.env.CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY = previousPublic;
      }
      if (previousPrivate === undefined) {
        delete process.env.CMUX_FREESTYLE_ADMIN_SIGNING_PRIVATE_KEY_SEED;
      } else {
        process.env.CMUX_FREESTYLE_ADMIN_SIGNING_PRIVATE_KEY_SEED = previousPrivate;
      }
    }
  });

  test("Daytona image bakes the entrypoint supervisor for cmuxd-remote on 7777", () => {
    // Image.addLocalFile validates the context file at construction time.
    const daemonPath = path.join(tmpdir(), `cmuxd-remote-test-${process.pid}`);
    writeFileSync(daemonPath, "stub");
    const dockerfile = daytonaSnapshotImage(daemonPath).dockerfile;
    expect(dockerfile).toContain("FROM ubuntu:24.04");
    expect(dockerfile).toContain("/usr/local/bin/cmuxd-remote");
    expect(dockerfile).toContain('ENTRYPOINT ["/usr/local/bin/cmux-daytona-entrypoint"]');
    // Every line must be a real Dockerfile instruction: multi-line shell (heredoc profile and
    // entrypoint writers) has to be wrapped by toDockerfileRunCommand, or the Daytona builder
    // fails with "unknown instruction" at snapshot-create time.
    const instruction = /^(#|FROM|RUN|ENV|COPY|ADD|ENTRYPOINT|CMD|WORKDIR|USER|ARG|LABEL|EXPOSE|SHELL)\b/;
    for (const line of dockerfile.split("\n")) {
      if (line.trim() === "") continue;
      expect(line).toMatch(instruction);
    }
    // Daytona attach is preview-URL WebSockets and even Daytona's own SSH gateway
    // terminates in the runner daemon, so no sshd belongs in the image.
    expect(dockerfile).not.toContain("openssh-server");
    expect(dockerfile).not.toContain("sshd");
  });

  test("toDockerfileRunCommand wraps multi-line shell and round-trips it", () => {
    expect(toDockerfileRunCommand("echo one-liner")).toBe("echo one-liner");
    const multi = daytonaEntrypointCommands()[0]!;
    const wrapped = toDockerfileRunCommand(multi);
    expect(wrapped).not.toContain("\n");
    const encoded = wrapped.match(/printf '%s' '([^']+)' \| base64 -d \| sh/)?.[1];
    expect(encoded).toBeTruthy();
    expect(Buffer.from(encoded!, "base64").toString("utf8")).toBe(multi);
  });

  test("Daytona entrypoint restarts the daemon and keeps lease dir private", () => {
    const script = daytonaEntrypointCommands().join("\n");
    expect(script).toContain("mkdir -p /tmp/cmux");
    expect(script).toContain("chmod 700 /tmp/cmux");
    expect(script).toContain("while true; do");
    expect(script).toContain("chmod 0755 /usr/local/bin/cmux-daytona-entrypoint");
  });

  test("image smoke checks cover baked toolchain commands", () => {
    const smoke = cloudImageSmokeTestCommands().join("\n");

    expect(smoke).toContain("gcc /tmp/cmux-build-smoke.c -o /tmp/cmux-build-smoke");
    expect(smoke).toContain("g++ --version");
    expect(smoke).toContain("make --version");
    expect(smoke).toContain("pkg-config --version");
    expect(smoke).toContain("python3 -m pip --version");
    expect(smoke).toContain("python3 -m venv /tmp/cmux-venv-smoke");
    expect(smoke).toContain("test \"$(command -v node)\" = \"/usr/local/share/mise/shims/node\"");
    expect(smoke).toContain("mise which node");
    expect(smoke).toContain("go version");
    expect(smoke).toContain("gh --version");
    expect(smoke).toContain("rustup show active-toolchain");
    expect(smoke).toContain("grep -q '^stable'");
  });

  test("snapshot recovery window tolerates provider clock skew", () => {
    expect(freestyleRecoveryWindowStart(new Date("2026-05-09T05:00:00.000Z"))).toBe(
      "2026-05-09T04:58:00.000Z",
    );
  });

  test("snapshot recovery ignores ready snapshots older than the failed create attempt", async () => {
    const freestyle = {
      fetch: async (_url: string, init?: RequestInit) => {
        expect(init?.signal).toBeInstanceOf(AbortSignal);
        return new Response(JSON.stringify({
          snapshots: [
            {
              snapshotId: "sh-old",
              name: "cmuxd-ws-review",
              state: "ready",
              createdAt: "2026-05-09T04:00:00.000Z",
            },
            {
              snapshotId: "sh-new",
              name: "cmuxd-ws-review",
              state: "ready",
              createdAt: "2026-05-09T05:00:00.000Z",
            },
          ],
        }));
      },
    };

    const recovered = await waitForFreestyleSnapshotByName(
      freestyle as never,
      "cmuxd-ws-review",
      "2026-05-09T04:30:00.000Z",
      100,
    );

    expect(recovered?.snapshotId).toBe("sh-new");
  });

  test("snapshot recovery does not alias only-stale snapshots", async () => {
    const freestyle = {
      fetch: async () =>
        new Response(JSON.stringify({
          snapshots: [
            {
              snapshotId: "sh-stale",
              name: "cmuxd-ws-review",
              state: "ready",
              createdAt: "2026-05-09T04:00:00.000Z",
            },
          ],
        })),
    };

    const recovered = await waitForFreestyleSnapshotByName(
      freestyle as never,
      "cmuxd-ws-review",
      "2026-05-09T04:30:00.000Z",
      10,
    );

    expect(recovered).toBeNull();
  });

  test("snapshot recovery uses Freestyle authenticated fetch transport", async () => {
    const name = "cmuxd-ws-auth";
    let requestUrl = "";
    let requestHeaders = new Headers();
    const freestyle = new Freestyle({
      apiKey: "fs_test_key",
      fetch: async (input, init) => {
        requestUrl = String(input);
        requestHeaders = new Headers(init?.headers);
        return new Response(JSON.stringify({
          snapshots: [
            {
              snapshotId: "sh-auth",
              name,
              state: "ready",
              createdAt: "2026-05-09T05:00:00.000Z",
            },
          ],
        }));
      },
    });

    const recovered = await findFreestyleSnapshotByName(
      freestyle,
      name,
      "2026-05-09T04:30:00.000Z",
      new AbortController().signal,
    );

    expect(recovered?.snapshotId).toBe("sh-auth");
    expect(requestUrl).toStartWith("https://api.freestyle.sh/v1/vms/snapshots");
    expect(requestHeaders.get("authorization")).toBe("Bearer fs_test_key");
    expect(requestHeaders.get("x-freestyle-sdk")).toBeTruthy();
  });

  test("retry waits are abortable", async () => {
    const controller = new AbortController();
    const wait = waitForRetryInterval(10_000, controller.signal);
    controller.abort();

    await expect(wait).rejects.toThrow("operation aborted");
  });
});
