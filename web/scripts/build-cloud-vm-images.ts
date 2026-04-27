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
const CLOUD_SHELL_PACKAGES = [
  "bash",
  "ca-certificates",
  "curl",
  "git",
  "libssl3t64",
  "locales",
  "openssl",
  "python3",
  "sudo",
];
const PRIMARY_LINUX_USER = "cmux";

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

const target = (argValue("--target") ?? "all") as Target;
if (!["e2b", "freestyle", "all"].includes(target)) {
  throw new Error("--target must be e2b, freestyle, or all");
}
const tag = (argValue("--tag") ?? defaultTag()).trim();
const skipCache = hasFlag("--skip-cache");
const binaryPath = path.join(buildRoot, tag, "cmuxd-remote-linux-amd64");

mkdirSync(path.dirname(binaryPath), { recursive: true });

await buildRemoteDaemon(binaryPath);
const imageMetadata = {
  builtAt: new Date().toISOString(),
  cmuxdRemoteCommit: await gitRevParse(path.join(repoRoot, "daemon/remote")),
  binarySha256: sha256File(binaryPath),
  builderScriptVersion: sha256File(fileURLToPath(import.meta.url)),
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
      validationStatus: metadata.validationStatus,
      notes: `binarySha256=${metadata.binarySha256}`,
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
  const fs = new Freestyle();
  const name = `cmuxd-ws-${tag}`;
  const result = await fs.vms.snapshots.create({
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
      validationStatus: metadata.validationStatus,
      notes: `binarySha256=${metadata.binarySha256}`,
    },
  };
}

function cloudRootSetupCommands(): string[] {
  return [
    `printf 'LANG=${UTF8_LOCALE}\\nLC_ALL=${UTF8_LOCALE}\\n' > /etc/default/locale`,
    `useradd -m -s /bin/bash ${PRIMARY_LINUX_USER} || true`,
    `printf '${PRIMARY_LINUX_USER} ALL=(ALL) NOPASSWD:ALL\\n' > /etc/sudoers.d/90-${PRIMARY_LINUX_USER}-nopasswd`,
    `chmod 0440 /etc/sudoers.d/90-${PRIMARY_LINUX_USER}-nopasswd`,
    "if id -u user >/dev/null 2>&1; then printf 'user ALL=(ALL) NOPASSWD:ALL\\n' > /etc/sudoers.d/91-user-nopasswd && chmod 0440 /etc/sudoers.d/91-user-nopasswd; fi",
    "install -d -m 0700 /tmp/cmux",
  ];
}

function cloudImageSmokeTestCommands(): string[] {
  return [
    "openssl version -a >/tmp/cmux-openssl-version.txt",
    "python3 -X faulthandler -c 'import ssl; print(ssl.OPENSSL_VERSION)'",
    "python3 -m http.server --help >/dev/null",
  ];
}

function freestylePythonOpenSSLCommands(): string[] {
  return [
    "apt-get update",
    "mkdir -p /tmp/cmux-libssl /opt/cmux/openssl/lib",
    "cd /tmp/cmux-libssl && apt-get download libssl3t64",
    "dpkg-deb -x /tmp/cmux-libssl/libssl3t64_*.deb /tmp/cmux-libssl/root",
    "cp /tmp/cmux-libssl/root/usr/lib/x86_64-linux-gnu/libssl.so.3 /opt/cmux/openssl/lib/",
    "cp /tmp/cmux-libssl/root/usr/lib/x86_64-linux-gnu/libcrypto.so.3 /opt/cmux/openssl/lib/",
    "cat <<'EOF' >/usr/local/bin/python3\n#!/bin/sh\nexport LD_LIBRARY_PATH=\"/opt/cmux/openssl/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\"\nexec /usr/bin/python3 \"$@\"\nEOF",
    "chmod 0755 /usr/local/bin/python3",
    "ln -sf /usr/local/bin/python3 /usr/local/bin/python",
    "rm -rf /tmp/cmux-libssl /var/lib/apt/lists/*",
  ];
}

function freestyleBaseDockerfileContent(daemonURL: string): string {
  return [
    "FROM ubuntu:24.04",
    `ENV LANG=${UTF8_LOCALE} LC_ALL=${UTF8_LOCALE} LANGUAGE=${UTF8_LOCALE}`,
    `RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${CLOUD_SHELL_PACKAGES.join(" ")} && rm -rf /var/lib/apt/lists/*`,
    ...freestylePythonOpenSSLCommands().map((command) => `RUN ${command}`),
    `RUN curl -fsSL ${shellQuote(daemonURL)} -o /usr/local/bin/cmuxd-remote && chmod 0755 /usr/local/bin/cmuxd-remote`,
    ...cloudRootSetupCommands().map((command) => `RUN ${command}`),
    ...cloudImageSmokeTestCommands().map((command) => `RUN ${command}`),
    "RUN mkdir -p /etc/systemd/system/multi-user.target.wants",
    "RUN cat <<'EOF' >/etc/systemd/system/cmuxd-ws.service\n[Unit]\nDescription=cmuxd websocket daemon\nAfter=network.target\n\n[Service]\nType=simple\nUser=root\nExecStart=/usr/local/bin/cmuxd-remote serve --ws --listen 0.0.0.0:7777 --auth-lease-file /tmp/cmux/attach-pty-lease.json --rpc-auth-lease-file /tmp/cmux/attach-rpc-lease.json --shell /bin/bash\nRestart=always\nRestartSec=1\n\n[Install]\nWantedBy=multi-user.target\nEOF",
    "RUN ln -sf /etc/systemd/system/cmuxd-ws.service /etc/systemd/system/multi-user.target.wants/cmuxd-ws.service",
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

type ImageBuildMetadata = {
  readonly builtAt: string;
  readonly cmuxdRemoteCommit: string;
  readonly binarySha256: string;
  readonly builderScriptVersion: string;
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
