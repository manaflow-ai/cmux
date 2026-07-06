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
  "build-essential",
  "ca-certificates",
  "curl",
  "dirmngr",
  "git",
  "gnupg",
  "golang-go",
  "gpg-agent",
  "libssl3t64",
  "locales",
  "openssl",
  "pkg-config",
  "python3",
  "python3-pip",
  "python3-venv",
  "sudo",
  "unzip",
  "xz-utils",
];
const TOOLCHAIN_SHIMS_DIR = "/usr/local/share/mise/shims";
const RUSTUP_HOME = "/opt/rustup";
const CARGO_HOME = "/opt/cargo";
const TOOLCHAIN_PATH = [
  TOOLCHAIN_SHIMS_DIR,
  `${CARGO_HOME}/bin`,
  "/usr/local/sbin",
  "/usr/local/bin",
  "/usr/sbin",
  "/usr/bin",
  "/sbin",
  "/bin",
].join(":");
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
    .setEnvs(cloudImageRuntimeEnvironment())
    .copy(path.basename(daemonPath), "/usr/local/bin/cmuxd-remote", {
      forceUpload: true,
      mode: 0o755,
    })
    .runCmd(cloudToolInstallCommands(), { user: "root" })
    .runCmd(cloudRootSetupCommands(), { user: "root" })
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
    result = await fs.vms.snapshots.create({
      name,
      template: {
        baseImage: {
          dockerfileContent: freestyleBaseDockerfileContent(daemonURL),
        },
        ports: [{ port: 443, targetPort: 7777 }],
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
    `useradd -m -s /bin/bash ${PRIMARY_LINUX_USER} || true`,
    `printf '${PRIMARY_LINUX_USER} ALL=(ALL) NOPASSWD:ALL\\n' > /etc/sudoers.d/90-${PRIMARY_LINUX_USER}-nopasswd`,
    `chmod 0440 /etc/sudoers.d/90-${PRIMARY_LINUX_USER}-nopasswd`,
    "if id -u user >/dev/null 2>&1; then printf 'user ALL=(ALL) NOPASSWD:ALL\\n' > /etc/sudoers.d/91-user-nopasswd && chmod 0440 /etc/sudoers.d/91-user-nopasswd; fi",
    "mkdir -p /tmp/cmux && chmod 700 /tmp/cmux",
    "ln -sf /usr/local/bin/cmuxd-remote /usr/local/bin/cmux",
  ];
}

export function cloudImageSmokeTestCommands(): string[] {
  const agentToolVersionChecks = cloudAgentToolPackageSpecs().flatMap((tool) =>
    tool.binaries.map((binary) => `${binary} --version >/tmp/cmux-${tool.name}-version.txt 2>&1`)
  );
  const toolchainEnv = toolchainSmokeEnvironmentPrefix();
  return [
    "printf 'int main(void) { return 0; }\\n' >/tmp/cmux-build-smoke.c && gcc /tmp/cmux-build-smoke.c -o /tmp/cmux-build-smoke && /tmp/cmux-build-smoke && g++ --version >/dev/null && make --version >/dev/null && pkg-config --version >/dev/null && rm -f /tmp/cmux-build-smoke.c /tmp/cmux-build-smoke",
    "openssl version -a >/tmp/cmux-openssl-version.txt 2>&1",
    "python3 -X faulthandler -c 'import ssl; print(ssl.OPENSSL_VERSION)'",
    "python3 -m http.server --help >/dev/null",
    "python3 -m pip --version >/tmp/cmux-pip-version.txt 2>&1",
    "python3 -m venv /tmp/cmux-venv-smoke && rm -rf /tmp/cmux-venv-smoke",
    `${toolchainEnv} test "$(command -v node)" = "${TOOLCHAIN_SHIMS_DIR}/node" && node --version >/tmp/cmux-node-version.txt 2>&1 && mise which node >/tmp/cmux-mise-node-path.txt 2>&1`,
    "npm --version >/tmp/cmux-npm-version.txt 2>&1",
    "bun --version >/tmp/cmux-bun-version.txt 2>&1",
    "go version >/tmp/cmux-go-version.txt 2>&1",
    "gh --version >/tmp/cmux-gh-version.txt 2>&1",
    `${toolchainEnv} rustup show active-toolchain >/tmp/cmux-rustup-toolchain.txt 2>&1 && grep -q '^stable' /tmp/cmux-rustup-toolchain.txt && rustc --version >/tmp/cmux-rustc-version.txt 2>&1 && cargo --version >/tmp/cmux-cargo-version.txt 2>&1`,
    "mise --version >/tmp/cmux-mise-version.txt 2>&1",
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
    "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg",
    "chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg",
    "printf '%s\\n' \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" > /etc/apt/sources.list.d/github-cli.list",
    "apt-get update",
    "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gh nodejs",
    "npm config set fund false",
    "npm config set audit false",
    bunInstallCommand(),
    "ln -sf /usr/local/bin/bun /usr/local/bin/bunx",
    toolPackages.length > 0
      ? `npm install -g --omit=dev --no-audit --fund=false ${toolPackages.map((tool) => shellQuote(tool.packageSpec)).join(" ")} >/tmp/cmux-npm-install.txt 2>&1`
      : "true",
    miseInstallCommand(),
    rustupInstallCommand(),
    toolchainProfileCommand(),
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

function miseInstallCommand(): string {
  const commands = [
    "set -eu",
    "install -d -m 0755 /etc/mise /usr/local/share/mise",
    "printf '[tools]\\nnode = \"lts\"\\n' >/etc/mise/config.toml",
    "curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh",
    "MISE_YES=1 mise install --system node@lts",
    "MISE_DATA_DIR=/usr/local/share/mise mise reshim --force",
    "chmod -R a+rX /etc/mise /usr/local/share/mise",
    "rm -rf /root/.cache/mise /usr/local/share/mise/downloads",
  ];
  return `{ ${commands.join(" && ")}; } >/tmp/cmux-mise-install.txt 2>&1`;
}

function rustupInstallCommand(): string {
  const commands = [
    "set -eu",
    `export RUSTUP_HOME=${shellQuote(RUSTUP_HOME)}`,
    `export CARGO_HOME=${shellQuote(CARGO_HOME)}`,
    "curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/cmux-rustup-init.sh",
    "sh /tmp/cmux-rustup-init.sh -y --profile minimal --default-toolchain stable --no-modify-path",
    "rm -f /tmp/cmux-rustup-init.sh",
    "rm -rf \"$RUSTUP_HOME/downloads\" \"$RUSTUP_HOME/tmp\" \"$CARGO_HOME/registry\"",
    "chmod -R a+rX \"$RUSTUP_HOME\" \"$CARGO_HOME\"",
  ];
  return `{ ${commands.join(" && ")}; } >/tmp/cmux-rustup-install.txt 2>&1`;
}

function toolchainProfileCommand(): string {
  const envLines = Object.entries(cloudImageRuntimeEnvironment())
    .map(([key, value]) => `${key}="${value}"`)
    .join("\\n");
  const profile = [
    `export RUSTUP_HOME=${RUSTUP_HOME}`,
    `case ":\${PATH:-}:" in *":${TOOLCHAIN_SHIMS_DIR}:"*) ;; *) PATH="${TOOLCHAIN_SHIMS_DIR}:${CARGO_HOME}/bin:\${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}" ;; esac`,
    "export PATH",
  ].join("\\n");
  return [
    `printf '%b\\n' ${shellQuote(envLines)} >/etc/environment`,
    `printf '%b\\n' ${shellQuote(profile)} >/etc/profile.d/cmux-toolchains.sh`,
    "chmod 0644 /etc/environment /etc/profile.d/cmux-toolchains.sh",
  ].join(" && ");
}

function toolchainSmokeEnvironmentPrefix(): string {
  return [
    `export PATH=${shellQuote(TOOLCHAIN_PATH)}`,
    `RUSTUP_HOME=${shellQuote(RUSTUP_HOME)}`,
  ].join(" ") + "; ";
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
    dockerEnvLine(cloudImageRuntimeEnvironment()),
    `RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${CLOUD_SHELL_PACKAGES.join(" ")} && rm -rf /var/lib/apt/lists/*`,
    ...freestylePythonOpenSSLCommands().map((command) => `RUN ${command}`),
    `RUN curl -fsSL ${shellQuote(daemonURL)} -o /usr/local/bin/cmuxd-remote && chmod 0755 /usr/local/bin/cmuxd-remote`,
    ...cloudToolInstallCommands().map((command) => `RUN ${command}`),
    ...cloudRootSetupCommands().map((command) => `RUN ${command}`),
    ...cloudImageSmokeTestCommands().map((command) => `RUN ${command}`),
    "RUN mkdir -p /etc/systemd/system/multi-user.target.wants",
    `RUN ${freestyleSystemdServiceCommand()}`,
    "RUN ln -sf /etc/systemd/system/cmuxd-ws.service /etc/systemd/system/multi-user.target.wants/cmuxd-ws.service",
  ].join("\n");
}

export function cloudImageRuntimeEnvironment(): Record<string, string> {
  return {
    LANG: UTF8_LOCALE,
    LC_ALL: UTF8_LOCALE,
    LANGUAGE: UTF8_LOCALE,
    PATH: TOOLCHAIN_PATH,
    RUSTUP_HOME,
  };
}

export function cloudShellPackageNames(): readonly string[] {
  return CLOUD_SHELL_PACKAGES;
}

function dockerEnvLine(env: Record<string, string>): string {
  return `ENV ${Object.entries(env).map(([key, value]) => `${key}=${dockerEnvValue(value)}`).join(" ")}`;
}

function dockerEnvValue(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/\s/g, "\\$&");
}

function freestyleSystemdServiceCommand(): string {
  const service = [
    "[Unit]",
    "Description=cmuxd websocket daemon",
    "After=network.target",
    "",
    "[Service]",
    "Type=simple",
    "User=root",
    ...systemdEnvironmentLines(cloudImageRuntimeEnvironment()),
    "ExecStart=/usr/local/bin/cmuxd-remote serve --ws --listen 0.0.0.0:7777 --auth-lease-file /tmp/cmux/attach-pty-lease.json --rpc-auth-lease-file /tmp/cmux/attach-rpc-lease.json --shell /bin/bash",
    "Restart=always",
    "RestartSec=1",
    "",
    "[Install]",
    "WantedBy=multi-user.target",
  ].join("\n");
  return `cat <<'EOF' >/etc/systemd/system/cmuxd-ws.service\n${service}\nEOF`;
}

export function systemdEnvironmentLines(env: Record<string, string>): string[] {
  return Object.entries(env).map(([key, value]) => `Environment=${key}=${systemdEnvironmentValue(value)}`);
}

function systemdEnvironmentValue(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
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
    `nodeSourceMajor=${metadata.nodeMajor}`,
    "nodeDefault=mise-node-lts-shim",
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
