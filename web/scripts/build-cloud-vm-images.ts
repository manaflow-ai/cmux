#!/usr/bin/env bun
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  Template,
  defaultBuildLogger,
  waitForURL,
} from "e2b";
import { Freestyle } from "freestyle";

type Target = "e2b" | "freestyle" | "all";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(webRoot, "..");
const buildRoot = path.join(webRoot, ".cmux-cloud-build");
const UTF8_LOCALE = "C.UTF-8";
const STRICT_SEMVER_RE =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/;
const CLOUD_SHELL_PACKAGES = [
  "bash",
  "btop",
  "ca-certificates",
  "curl",
  "dirmngr",
  "gh",
  "git",
  "gnupg",
  "gpg-agent",
  "htop",
  "libssl3t64",
  "locales",
  "openssl",
  "python3",
  "sudo",
  "tmux",
  "unzip",
  "xz-utils",
  "zsh",
  "zsh-autosuggestions",
];
const PRIMARY_LINUX_USER = "cmux";
const NODE_MAJOR = String(positiveIntFromEnv("CMUX_CLOUD_IMAGE_NODE_MAJOR", 22));
const BUN_VERSION = semverFromEnv("CMUX_CLOUD_IMAGE_BUN_VERSION", "1.3.13");
const FREESTYLE_SNAPSHOT_CREATE_TIMEOUT_MS = positiveIntFromEnv(
  "CMUX_FREESTYLE_SNAPSHOT_CREATE_TIMEOUT_MS",
  20 * 60 * 1000,
);
const FREESTYLE_SNAPSHOT_RECOVERY_TIMEOUT_MS = positiveIntFromEnv(
  "CMUX_FREESTYLE_SNAPSHOT_RECOVERY_TIMEOUT_MS",
  10 * 60 * 1000,
);
const FREESTYLE_SNAPSHOT_RECOVERY_POLL_INTERVAL_MS = positiveIntFromEnv(
  "CMUX_FREESTYLE_SNAPSHOT_RECOVERY_POLL_INTERVAL_MS",
  5_000,
);
const FREESTYLE_SNAPSHOT_RECOVERY_CLOCK_SKEW_MS = positiveIntFromEnv(
  "CMUX_FREESTYLE_SNAPSHOT_RECOVERY_CLOCK_SKEW_MS",
  2 * 60 * 1000,
);
const CLOUD_AGENT_TOOLS = [
  {
    name: "claude",
    envVar: "CMUX_CLOUD_IMAGE_CLAUDE_CODE_NPM_SPEC",
    packageSpec: "@anthropic-ai/claude-code@2.1.137",
    binaries: ["claude"],
  },
  {
    name: "opencode",
    envVar: "CMUX_CLOUD_IMAGE_OPENCODE_NPM_SPEC",
    packageSpec: "opencode-ai@1.14.41",
    binaries: ["opencode"],
  },
  {
    name: "codex",
    envVar: "CMUX_CLOUD_IMAGE_CODEX_NPM_SPEC",
    packageSpec: "@openai/codex@0.130.0",
    binaries: ["codex"],
  },
  {
    name: "pi",
    envVar: "CMUX_CLOUD_IMAGE_PI_NPM_SPEC",
    packageSpec: "@earendil-works/pi-coding-agent@0.74.0",
    binaries: ["pi"],
  },
] as const;

function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  if (index === -1) return undefined;
  return process.argv[index + 1];
}

function hasFlag(name: string): boolean {
  return process.argv.includes(name);
}

function defaultTag(): string {
  const stamp = new Date().toISOString()
    .replace(/[-:]/g, "")
    .replace(/\..+$/, "")
    .replace("T", "-");
  return `ws-${stamp}`;
}

if (path.resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  await main();
}

async function main(): Promise<void> {
  const target = (argValue("--target") ?? "all") as Target;
  if (!["e2b", "freestyle", "all"].includes(target)) {
    throw new Error("--target must be e2b, freestyle, or all");
  }
  const tag = (argValue("--tag") ?? defaultTag()).trim();
  const skipCache = hasFlag("--skip-cache");
  const binaryPath = path.join(buildRoot, tag, "cmuxd-remote-linux-amd64");

  mkdirSync(path.dirname(binaryPath), { recursive: true });

  await buildRemoteDaemon(binaryPath);
  const agentTools = cloudAgentToolPackageSpecs();
  const imageMetadata = {
    builtAt: new Date().toISOString(),
    cmuxdRemoteCommit: await gitRevParse(path.join(repoRoot, "daemon/remote")),
    binarySha256: sha256File(binaryPath),
    builderScriptVersion: sha256File(fileURLToPath(import.meta.url)),
    nodeMajor: NODE_MAJOR,
    agentToolPackageSpecs: agentTools.map((tool) => tool.packageSpec),
    agentToolResolvedVersions: Object.fromEntries(
      agentTools.map((tool) => [tool.name, tool.resolvedVersion]),
    ),
    validationStatus: "passed" as const,
  };

  const output: Record<string, unknown> = {
    tag,
    binaryPath,
    ...imageMetadata,
    manifestEntries: [],
  };

  if (target === "e2b" || target === "all") {
    const e2b = await buildE2BTemplate(tag, binaryPath, skipCache, imageMetadata);
    output.e2b = e2b;
    (output.manifestEntries as unknown[]).push(e2b.manifestEntry);
  }
  if (target === "freestyle" || target === "all") {
    const freestyle = await buildFreestyleSnapshot(tag, binaryPath, skipCache, imageMetadata);
    output.freestyle = freestyle;
    (output.manifestEntries as unknown[]).push(freestyle.manifestEntry);
  }

  console.log(JSON.stringify(output, null, 2));
}

async function buildRemoteDaemon(outPath: string): Promise<void> {
  await runCommand(
    "go",
    ["build", "-trimpath", "-ldflags=-s -w", "-o", outPath, "./cmd/cmuxd-remote"],
    {
      cwd: path.join(repoRoot, "daemon/remote"),
      env: { GOOS: "linux", GOARCH: "amd64", CGO_ENABLED: "0" },
    },
  );
}

async function buildE2BTemplate(
  tag: string,
  daemonPath: string,
  skipCache: boolean,
  metadata: ImageBuildMetadata,
): Promise<Record<string, unknown>> {
  if (!process.env.E2B_API_KEY) {
    throw new Error("E2B_API_KEY is required to build the E2B template");
  }
  const fileContextPath = path.dirname(daemonPath);
  const template = Template({ fileContextPath })
    .fromUbuntuImage("24.04")
    .aptInstall(CLOUD_SHELL_PACKAGES, { noInstallRecommends: true })
    .setEnvs({ LANG: UTF8_LOCALE, LC_ALL: UTF8_LOCALE, LANGUAGE: UTF8_LOCALE })
    .copy(path.basename(daemonPath), "/usr/local/bin/cmuxd-remote", {
      forceUpload: true,
      mode: 0o755,
    })
    .runCmd(cloudToolInstallCommands(), { user: "root" })
    .runCmd(cloudRootSetupCommands(), { user: "root" })
    .runCmd(cloudShellProfileCommands(), { user: "root" })
    .runCmd(cloudImageSmokeTestCommands(), { user: "root" })
    .setStartCmd(
      "/usr/local/bin/cmuxd-remote serve --ws --listen 0.0.0.0:7777 --auth-lease-file /tmp/cmux/attach-pty-lease.json --rpc-auth-lease-file /tmp/cmux/attach-rpc-lease.json --shell /bin/bash",
      waitForURL("http://127.0.0.1:7777/healthz", 200),
    );

  const name = `cmuxd-ws:${tag}`;
  const result = await Template.build(template, name, {
    cpuCount: 2,
    memoryMB: 2048,
    skipCache,
    onBuildLogs: defaultBuildLogger({ minLevel: "info" }),
  });
  return {
    name,
    result,
    manifestEntry: {
      provider: "e2b",
      version: `e2b-${tag}`,
      imageId: name,
      envVar: "E2B_CMUXD_WS_TEMPLATE",
      defaultForLocalDev: false,
      cmuxdRemoteCommit: metadata.cmuxdRemoteCommit,
      builtAt: metadata.builtAt,
      builderScriptVersion: metadata.builderScriptVersion,
      agentToolResolvedVersions: metadata.agentToolResolvedVersions,
      validationStatus: metadata.validationStatus,
      notes: imageNotes(metadata),
    },
  };
}

async function buildFreestyleSnapshot(
  tag: string,
  daemonPath: string,
  skipCache: boolean,
  metadata: ImageBuildMetadata,
): Promise<Record<string, unknown>> {
  if (!process.env.FREESTYLE_API_KEY) {
    throw new Error("FREESTYLE_API_KEY is required to build the Freestyle snapshot");
  }
  const daemonURL = await remoteDaemonBuildURL(tag, daemonPath);
  const fs = new Freestyle({ fetch: fetchWithTimeout(FREESTYLE_SNAPSHOT_CREATE_TIMEOUT_MS) });
  const name = `cmuxd-ws-${tag}`;
  const createStartedAt = new Date();
  let result: unknown;
  try {
    result = await createFreestyleSnapshot(fs, {
      name,
      template: {
        baseImage: {
          dockerfileContent: freestyleBaseDockerfileContent(daemonURL),
        },
        discriminator: `cmuxd-ws-${tag}`,
        skipCache,
      },
    });
  } catch (err) {
    const recovered = await waitForFreestyleSnapshotByName(
      fs,
      name,
      freestyleRecoveryWindowStart(createStartedAt),
      FREESTYLE_SNAPSHOT_RECOVERY_TIMEOUT_MS,
    );
    if (!recovered) throw err;
    result = {
      snapshotId: recovered.snapshotId,
      recoveredAfterCreateError: errorSummary(err),
    };
  }
  const imageId = extractProviderId(result);
  if (!imageId) {
    const keys = result && typeof result === "object"
      ? Object.keys(result as unknown as Record<string, unknown>).sort().join(", ")
      : typeof result;
    throw new Error(`Freestyle snapshot build did not return a snapshot id; result keys: ${keys}`);
  }
  return {
    name,
    daemonURL: daemonURL.includes("X-Amz-") ? "<presigned-r2-url>" : daemonURL,
    result,
    manifestEntry: {
      provider: "freestyle",
      version: `freestyle-${tag}`,
      imageId,
      envVar: "FREESTYLE_SANDBOX_SNAPSHOT",
      defaultForLocalDev: false,
      features: process.env.CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY?.trim()
        ? { bakedFreestyleSignedAdmin: true }
        : undefined,
      cmuxdRemoteCommit: metadata.cmuxdRemoteCommit,
      builtAt: metadata.builtAt,
      builderScriptVersion: metadata.builderScriptVersion,
      agentToolResolvedVersions: metadata.agentToolResolvedVersions,
      validationStatus: metadata.validationStatus,
      notes: imageNotes(metadata),
    },
  };
}

type FreestyleSnapshotRecord = {
  readonly snapshotId: string;
  readonly cancelled?: boolean | null;
  readonly createdAt?: string;
  readonly deleted?: boolean | null;
  readonly failed?: boolean | null;
  readonly failureReason?: string | null;
  readonly lost?: boolean | null;
  readonly name?: string | null;
  readonly state?: string | null;
};

type FreestyleSnapshotListResponse = {
  readonly snapshots?: readonly FreestyleSnapshotRecord[] | null;
};

export async function findFreestyleSnapshotByName(
  fs: Freestyle,
  name: string,
  notBefore: string,
  signal: AbortSignal,
): Promise<FreestyleSnapshotRecord | null> {
  // Freestyle#fetch is the SDK API transport. It wraps the configured fetch and
  // injects auth headers before the request reaches the network.
  const response = await fs.fetch(freestyleSnapshotListURL(), {
    method: "GET",
    signal,
  });
  if (!response.ok) {
    throw new Error(`Freestyle snapshot list failed: HTTP ${response.status} ${await response.text()}`);
  }
  const json = await response.json() as FreestyleSnapshotListResponse;
  const matches = (json.snapshots ?? [])
    .filter((snapshot) =>
      snapshot.name === name &&
      snapshot.deleted !== true &&
      typeof snapshot.createdAt === "string" &&
      snapshot.createdAt >= notBefore
    )
    .sort((a, b) => (b.createdAt ?? "").localeCompare(a.createdAt ?? ""));
  const latest = matches[0];
  if (!latest) return null;
  if (latest.failed === true || latest.cancelled === true || latest.lost === true || latest.failureReason) {
    throw new Error(
      `Freestyle snapshot ${name} failed: ${latest.failureReason ?? latest.state ?? "unknown failure"}`,
    );
  }
  if (latest.state !== "ready") return null;
  return latest;
}

export async function waitForFreestyleSnapshotByName(
  fs: Freestyle,
  name: string,
  notBefore: string,
  timeoutMs: number,
): Promise<FreestyleSnapshotRecord | null> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    while (!controller.signal.aborted) {
      const snapshot = await findFreestyleSnapshotByName(fs, name, notBefore, controller.signal);
      if (snapshot) return snapshot;
      await waitForRetryInterval(FREESTYLE_SNAPSHOT_RECOVERY_POLL_INTERVAL_MS, controller.signal);
    }
    return null;
  } catch (err) {
    if (controller.signal.aborted) return null;
    throw err;
  } finally {
    clearTimeout(timeout);
  }
}

function cloudRootSetupCommands(): string[] {
  return [
    `printf 'LANG=${UTF8_LOCALE}\\nLC_ALL=${UTF8_LOCALE}\\n' > /etc/default/locale`,
    `useradd -m -s /bin/zsh ${PRIMARY_LINUX_USER} || true`,
    `printf '${PRIMARY_LINUX_USER} ALL=(ALL) NOPASSWD:ALL\\n' > /etc/sudoers.d/90-${PRIMARY_LINUX_USER}-nopasswd`,
    `chmod 0440 /etc/sudoers.d/90-${PRIMARY_LINUX_USER}-nopasswd`,
    "if id -u user >/dev/null 2>&1; then printf 'user ALL=(ALL) NOPASSWD:ALL\\n' > /etc/sudoers.d/91-user-nopasswd && chmod 0440 /etc/sudoers.d/91-user-nopasswd; fi",
    "mkdir -p /tmp/cmux && chown cmux:cmux /tmp/cmux && chmod 700 /tmp/cmux",
    "ln -sf /usr/local/bin/cmuxd-remote /usr/local/bin/cmux",
  ];
}

function cloudShellProfileCommands(): string[] {
  return [
    "mkdir -p /etc/cmux /home/cmux/.config/cmux /home/cmux/.cmux",
    "cat > /etc/cmux/zshrc <<'CMUX_ZSHRC'\n# cmux default zsh profile. Put personal overrides in ~/.zshrc.local.\nexport PATH=\"/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}\"\nexport SHELL=\"$(command -v zsh)\"\nmkdir -p \"$HOME/.cmux\" 2>/dev/null || true\nprintf '%s' '/tmp/cmux-cloud-cli.sock' > \"$HOME/.cmux/socket_addr\" 2>/dev/null || true\nexport CMUX_SOCKET_PATH=\"${CMUX_SOCKET_PATH:-/tmp/cmux-cloud-cli.sock}\"\nautoload -Uz colors 2>/dev/null && colors\nsetopt prompt_subst interactivecomments no_beep hist_ignore_dups share_history 2>/dev/null || true\nPROMPT_EOL_MARK=''\nunsetopt prompt_sp 2>/dev/null || true\nHISTFILE=\"${HISTFILE:-$HOME/.zsh_history}\"\nHISTSIZE=\"${HISTSIZE:-50000}\"\nSAVEHIST=\"${SAVEHIST:-50000}\"\nbindkey -e 2>/dev/null || true\nif [ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then\n  source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh\n  ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE=\"${ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE:-fg=8}\"\nfi\n: ${CMUX_PROMPT_USER:=cmux-cloud}\n: ${CMUX_PROMPT_CHAR:=$'\\u03bb'}\nPROMPT='%F{magenta}${CMUX_PROMPT_USER}%f in %F{green}%~%f ${CMUX_PROMPT_CHAR} '\nCMUX_ZSHRC",
    "cat > /home/cmux/.zshrc <<'CMUX_USER_ZSHRC'\n# cmux-managed zsh defaults. Edit ~/.zshrc.local for personal overrides.\nmkdir -p \"$HOME/.cmux\" 2>/dev/null || true\nprintf '%s' '/tmp/cmux-cloud-cli.sock' > \"$HOME/.cmux/socket_addr\" 2>/dev/null || true\nexport CMUX_SOCKET_PATH=\"${CMUX_SOCKET_PATH:-/tmp/cmux-cloud-cli.sock}\"\n[ -r /etc/cmux/zshrc ] && source /etc/cmux/zshrc\n[ -r \"$HOME/.zshrc.local\" ] && source \"$HOME/.zshrc.local\"\nif [ \"${CMUX_CLOUD_WELCOME:-1}\" != \"0\" ] && [ -z \"${CMUX_CLOUD_WELCOME_SHOWN:-}\" ] && [ -t 1 ]; then\n  export CMUX_CLOUD_WELCOME_SHOWN=1\n  printf '\\033[38;2;0;212;255m  ::\\033[0m\\n'\n  printf '\\033[38;2;24;181;250m    ::::              \\033[38;2;0;212;255mc\\033[38;2;24;181;250mm\\033[38;2;48;150;245mu\\033[38;2;124;58;237mx cloud\\033[0m\\n'\n  printf '\\033[38;2;48;150;245m      ::::::\\033[0m\\n'\n  printf '\\033[38;2;72;119;241m        ::::::\\033[0m        \\033[38;2;130;130;140mpersistent cloud VM\\033[0m\\n'\n  printf '\\033[38;2;96;88;239m      ::::::\\033[0m          \\033[38;2;130;130;140mready for coding agents\\033[0m\\n'\n  printf '\\033[38;2;110;73;238m    ::::\\033[0m\\n'\n  printf '\\033[38;2;124;58;237m  ::\\033[0m\\n'\n  printf '\\n'\nfi\nCMUX_USER_ZSHRC",
    "cat > /home/cmux/.zshrc.local <<'CMUX_LOCAL_ZSHRC'\n# Personal zsh overrides for this cloud VM.\n# Examples:\n#   CMUX_CLOUD_WELCOME=0\n#   CMUX_PROMPT_USER='cmux-cloud'\n#   CMUX_PROMPT_CHAR='>'\n#   PROMPT='%F{cyan}%n%f:%F{green}%~%f %# '\nCMUX_LOCAL_ZSHRC",
    "cat > /usr/local/bin/cmux-cloud-shell <<'CMUX_CLOUD_SHELL'\n#!/bin/sh\ncd /home/cmux 2>/dev/null || true\nexport HOME=/home/cmux\nexport USER=cmux\nexport LOGNAME=cmux\nexport SHELL=/bin/zsh\nexec runuser -u cmux -- /bin/zsh -l\nCMUX_CLOUD_SHELL\nchmod 0755 /usr/local/bin/cmux-cloud-shell",
    "touch /home/cmux/.hushlogin",
    "chown -R cmux:cmux /home/cmux/.zshrc /home/cmux/.zshrc.local /home/cmux/.hushlogin /home/cmux/.config /home/cmux/.cmux",
  ];
}

function freestyleSignedAdminServiceCommands(): string[] {
  const publicKey = process.env.CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY?.trim();
  if (!publicKey) return [];
  validateFreestyleAdminPublicKey(publicKey);
  return [
    "mkdir -p /tmp/cmux && chmod 700 /tmp/cmux",
    `cat > /etc/systemd/system/cmuxd-ws.service <<'CMUXD_WS_SERVICE'
[Unit]
Description=cmux remote WebSocket daemon
After=network.target

[Service]
Type=simple
User=root
Environment=CMUXD_WS_ADMIN_ED25519_PUBLIC_KEY=${publicKey}
ExecStart=/usr/local/bin/cmuxd-remote serve --ws --listen 0.0.0.0:7777 --auth-lease-file /tmp/cmux/attach-pty-lease.json --rpc-auth-lease-file /tmp/cmux/attach-rpc-lease.json --shell /usr/local/bin/cmux-cloud-shell
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
CMUXD_WS_SERVICE`,
    "mkdir -p /etc/systemd/system/multi-user.target.wants && ln -sf /etc/systemd/system/cmuxd-ws.service /etc/systemd/system/multi-user.target.wants/cmuxd-ws.service",
  ];
}

function validateFreestyleAdminPublicKey(publicKey: string): void {
  const decoded = Buffer.from(publicKey.replace(/-/g, "+").replace(/_/g, "/"), "base64");
  if (decoded.length !== 32) {
    throw new Error("CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY must decode to 32 bytes");
  }
}

export function cloudImageSmokeTestCommands(): string[] {
  const agentToolVersionChecks = cloudAgentToolPackageSpecs().flatMap((tool) =>
    tool.binaries.map((binary) => `${binary} --version >/tmp/cmux-${tool.name}-version.txt 2>&1`)
  );
  return [
    "openssl version -a >/tmp/cmux-openssl-version.txt 2>&1",
    "gh --version >/tmp/cmux-gh-version.txt 2>&1",
    "htop --version >/tmp/cmux-htop-version.txt 2>&1",
    "btop --version >/tmp/cmux-btop-version.txt 2>&1",
    "tmux -V >/tmp/cmux-tmux-version.txt 2>&1",
    "zsh --version >/tmp/cmux-zsh-version.txt 2>&1",
    "test -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh",
    "python3 -X faulthandler -c 'import ssl; print(ssl.OPENSSL_VERSION)'",
    "python3 -m http.server --help >/dev/null",
    "node --version >/tmp/cmux-node-version.txt 2>&1",
    "npm --version >/tmp/cmux-npm-version.txt 2>&1",
    "bun --version >/tmp/cmux-bun-version.txt 2>&1",
    "test -x /usr/local/bin/cmuxd-remote && test -x /usr/local/bin/cmux",
    "cmux --help >/tmp/cmux-cli-help.txt 2>&1",
    "cmux --socket /tmp/cmux-browser-smoke.sock browser >/tmp/cmux-browser-help.txt 2>&1; status=$?; test \"$status\" -eq 2 && grep -q 'requires a subcommand' /tmp/cmux-browser-help.txt",
    "cmuxd-remote version >/tmp/cmuxd-remote-version.txt 2>&1",
    ...agentToolVersionChecks,
  ];
}

type CloudAgentToolPackage = {
  readonly name: string;
  readonly envVar: string;
  readonly packageSpec: string;
  readonly resolvedVersion: string;
  readonly binaries: readonly string[];
};

export function cloudAgentToolPackageSpecs(): CloudAgentToolPackage[] {
  return CLOUD_AGENT_TOOLS.flatMap((tool) => {
    const raw = process.env[tool.envVar]?.trim();
    if (raw && isDisabledValue(raw)) return [];
    const packageSpec = raw || tool.packageSpec;
    const resolvedVersion = pinnedNpmPackageVersion(packageSpec);
    if (!resolvedVersion) {
      throw new Error(`${tool.envVar} must be pinned to an exact npm package version; got ${packageSpec}`);
    }
    return [{ ...tool, packageSpec, resolvedVersion }];
  });
}

export function pinnedNpmPackageVersion(packageSpec: string): string | null {
  const trimmed = packageSpec.trim();
  const versionSeparator = trimmed.startsWith("@")
    ? trimmed.indexOf("@", 1)
    : trimmed.lastIndexOf("@");
  if (versionSeparator <= 0) return null;
  const version = trimmed.slice(versionSeparator + 1).trim();
  if (!STRICT_SEMVER_RE.test(version)) return null;
  return version;
}

export function cloudToolInstallCommands(): string[] {
  const toolPackages = cloudAgentToolPackageSpecs();
  return [
    "install -d -m 0755 /etc/apt/keyrings",
    "rm -f /etc/apt/keyrings/nodesource.gpg",
    "curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg",
    `printf '%s\\n' ${shellQuote(`deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main`)} > /etc/apt/sources.list.d/nodesource.list`,
    "apt-get update",
    "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs",
    "npm config set fund false",
    "npm config set audit false",
    bunInstallCommand(),
    "ln -sf /usr/local/bin/bun /usr/local/bin/bunx",
    toolPackages.length > 0
      ? `npm install -g --omit=dev --no-audit --fund=false ${toolPackages.map((tool) => shellQuote(tool.packageSpec)).join(" ")} >/tmp/cmux-npm-install.txt 2>&1`
      : "true",
    "rm -rf /root/.npm/_cacache /var/lib/apt/lists/*",
  ];
}

function isDisabledValue(value: string): boolean {
  return ["0", "false", "off", "disabled", "none"].includes(value.trim().toLowerCase());
}

function bunInstallCommand(): string {
  const tag = `bun-v${BUN_VERSION}`;
  const commands = [
    "set -eu",
    "rm -rf /tmp/cmux-bun-install",
    "mkdir -p /tmp/cmux-bun-install",
    "cd /tmp/cmux-bun-install",
    "arch=\"$(dpkg --print-architecture)\"",
    "case \"${arch##*-}\" in amd64) build=\"x64-baseline\" ;; arm64) build=\"aarch64\" ;; *) echo \"unsupported architecture: $arch\"; exit 1 ;; esac",
    `tag=${shellQuote(tag)}`,
    "release=\"https://github.com/oven-sh/bun/releases/download/$tag\"",
    "curl -fsSLO --compressed --retry 5 \"$release/bun-linux-$build.zip\"",
    "for key in F3DCC08A8572C0749B3E18888EAB4D40A7B22B59; do gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys \"$key\" || gpg --batch --keyserver keyserver.ubuntu.com --recv-keys \"$key\"; done",
    "curl -fsSLO --compressed --retry 5 \"$release/SHASUMS256.txt.asc\"",
    "gpg --batch --decrypt --output SHASUMS256.txt SHASUMS256.txt.asc",
    "grep \" bun-linux-$build.zip$\" SHASUMS256.txt | sha256sum -c -",
    "unzip -q \"bun-linux-$build.zip\"",
    "install -m 0755 \"bun-linux-$build/bun\" /usr/local/bin/bun",
    "rm -rf /tmp/cmux-bun-install",
  ];
  return `{ ${commands.join(" && ")}; } >/tmp/cmux-bun-install.txt 2>&1`;
}

function freestylePythonOpenSSLCommands(): string[] {
  return [
    "apt-get update",
    "mkdir -p /tmp/cmux-libssl /opt/cmux/openssl/lib",
    "cd /tmp/cmux-libssl && apt-get download libssl3t64",
    "dpkg-deb -x /tmp/cmux-libssl/libssl3t64_*.deb /tmp/cmux-libssl/root",
    "cp /tmp/cmux-libssl/root/usr/lib/*-linux-gnu/libssl.so.3 /opt/cmux/openssl/lib/",
    "cp /tmp/cmux-libssl/root/usr/lib/*-linux-gnu/libcrypto.so.3 /opt/cmux/openssl/lib/",
    "cat <<'EOF' >/usr/local/bin/python3\n#!/bin/sh\nexport LD_LIBRARY_PATH=\"/opt/cmux/openssl/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\"\nexec /usr/bin/python3 \"$@\"\nEOF",
    "chmod 0755 /usr/local/bin/python3",
    "ln -sf /usr/local/bin/python3 /usr/local/bin/python",
    "rm -rf /tmp/cmux-libssl /var/lib/apt/lists/*",
  ];
}

export function freestyleBaseDockerfileContent(daemonURL: string): string {
  return [
    "FROM ubuntu:24.04",
    `ENV LANG=${UTF8_LOCALE} LC_ALL=${UTF8_LOCALE} LANGUAGE=${UTF8_LOCALE}`,
    `RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${CLOUD_SHELL_PACKAGES.join(" ")} && rm -rf /var/lib/apt/lists/*`,
    ...freestylePythonOpenSSLCommands().map((command) => `RUN ${command}`),
    `RUN curl -fsSL ${shellQuote(daemonURL)} -o /usr/local/bin/cmuxd-remote && chmod 0755 /usr/local/bin/cmuxd-remote`,
    ...cloudToolInstallCommands().map((command) => `RUN ${command}`),
    ...cloudRootSetupCommands().map((command) => `RUN ${command}`),
    ...cloudShellProfileCommands().map((command) => `RUN ${command}`),
    ...freestyleSignedAdminServiceCommands().map((command) => `RUN ${command}`),
    ...cloudImageSmokeTestCommands().map((command) => `RUN ${command}`),
  ].join("\n");
}

async function remoteDaemonBuildURL(tag: string, daemonPath: string): Promise<string> {
  const explicit = process.env.CMUX_REMOTE_DAEMON_BUILD_URL?.trim();
  if (explicit) return explicit;

  const required = [
    "R2_ENDPOINT",
    "R2_BUCKET_NAME",
    "R2_PUBLIC_URL",
    "R2_ACCESS_KEY_ID",
    "R2_SECRET_ACCESS_KEY",
  ];
  const missing = required.filter((key) => !process.env[key]?.trim());
  if (missing.length > 0) {
    throw new Error(
      `Freestyle snapshot build needs CMUX_REMOTE_DAEMON_BUILD_URL or R2 env vars; missing ${missing.join(", ")}`,
    );
  }

  const key = `cmux-build-artifacts/cloud-vm/${tag}/cmuxd-remote-linux-amd64`;
  const env = {
    AWS_ACCESS_KEY_ID: process.env.R2_ACCESS_KEY_ID!,
    AWS_SECRET_ACCESS_KEY: process.env.R2_SECRET_ACCESS_KEY!,
    AWS_DEFAULT_REGION: "auto",
    AWS_REGION: "auto",
  };
  await runCommand(
    "aws",
    [
      "s3",
      "cp",
      daemonPath,
      `s3://${process.env.R2_BUCKET_NAME!}/${key}`,
      "--endpoint-url",
      process.env.R2_ENDPOINT!,
      "--content-type",
      "application/octet-stream",
      "--cache-control",
      "no-store",
      "--only-show-errors",
    ],
    { env },
  );

  const presigned = await runCommand(
    "aws",
    [
      "s3",
      "presign",
      `s3://${process.env.R2_BUCKET_NAME!}/${key}`,
      "--endpoint-url",
      process.env.R2_ENDPOINT!,
      "--expires-in",
      "3600",
    ],
    { env },
  );
  return presigned.trim();
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

export function positiveIntFromEnv(key: string, fallback: number): number {
  const raw = process.env[key]?.trim();
  if (!raw) return fallback;
  if (!/^[1-9]\d*$/.test(raw)) {
    throw new Error(`${key} must be a positive integer; got ${raw}`);
  }
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed)) {
    throw new Error(`${key} must be a safe positive integer; got ${raw}`);
  }
  return parsed;
}

export function semverFromEnv(key: string, fallback: string): string {
  const raw = process.env[key]?.trim();
  const value = raw || fallback;
  if (!STRICT_SEMVER_RE.test(value)) {
    throw new Error(`${key} must be an exact semver version; got ${value}`);
  }
  return value;
}

export function freestyleRecoveryWindowStart(startedAt: Date): string {
  return new Date(startedAt.getTime() - FREESTYLE_SNAPSHOT_RECOVERY_CLOCK_SKEW_MS).toISOString();
}

async function createFreestyleSnapshot(
  fs: Freestyle,
  body: Record<string, unknown>,
): Promise<unknown> {
  const base = (process.env.FREESTYLE_API_URL ?? "https://api.freestyle.sh").replace(/\/+$/, "");
  const response = await fs.fetch(`${base}/v1/vms/snapshots`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    throw new Error(`Freestyle snapshot create failed: HTTP ${response.status} ${await response.text()}`);
  }
  return await response.json();
}

function fetchWithTimeout(timeoutMs: number): typeof fetch {
  return async (input, init) => {
    const controller = new AbortController();
    const onAbort = () => controller.abort();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    try {
      if (init?.signal) {
        if (init.signal.aborted) {
          controller.abort();
        } else {
          init.signal.addEventListener("abort", onAbort, { once: true });
        }
      }
      return await fetch(input, {
        ...(init ?? {}),
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timeout);
      init?.signal?.removeEventListener("abort", onAbort);
    }
  };
}

function freestyleSnapshotListURL(): string {
  const base = (process.env.FREESTYLE_API_URL ?? "https://api.freestyle.sh").replace(/\/+$/, "");
  const url = new URL("/v1/vms/snapshots", base);
  url.searchParams.set("includeDeleted", "false");
  url.searchParams.set("includeFailed", "true");
  return url.toString();
}

function errorSummary(err: unknown): string {
  if (err instanceof Error) return `${err.name}: ${err.message}`;
  return String(err);
}

export function waitForRetryInterval(ms: number, signal: AbortSignal): Promise<void> {
  if (signal.aborted) return Promise.reject(abortError());
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      reject(abortError());
    };
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

function abortError(): Error {
  return new Error("operation aborted");
}

function imageNotes(metadata: ImageBuildMetadata): string {
  return [
    `binarySha256=${metadata.binarySha256}`,
    `nodeMajor=${metadata.nodeMajor}`,
    `agentTools=${metadata.agentToolPackageSpecs.join(",")}`,
  ].join(" ");
}

type ImageBuildMetadata = {
  readonly builtAt: string;
  readonly cmuxdRemoteCommit: string;
  readonly binarySha256: string;
  readonly builderScriptVersion: string;
  readonly nodeMajor: string;
  readonly agentToolPackageSpecs: readonly string[];
  readonly agentToolResolvedVersions: Record<string, string>;
  readonly validationStatus: "passed" | "failed" | "unknown";
};

function sha256File(filePath: string): string {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

function extractProviderId(result: unknown): string | null {
  if (!result || typeof result !== "object") return null;
  const record = result as Record<string, unknown>;
  const value = record.snapshotId ?? record.id ?? record.templateId ?? record.name;
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

async function gitRevParse(cwd: string): Promise<string> {
  return (await runCommand("git", ["rev-parse", "HEAD"], { cwd })).trim();
}

function runCommand(
  command: string,
  args: string[],
  options: { cwd?: string; env?: Record<string, string> } = {},
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.once("error", reject);
    child.once("close", (code) => {
      const output = Buffer.concat(stdout).toString();
      const errorOutput = Buffer.concat(stderr).toString();
      if (code === 0) {
        resolve(output);
        return;
      }
      reject(new Error(`${command} ${args.join(" ")} failed with ${code}\n${errorOutput}`));
    });
  });
}
