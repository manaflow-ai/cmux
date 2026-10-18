import { spawn } from "node:child_process";
import {
  ProviderError,
  type CmuxRemoteEndpoint,
  type CmuxRemoteAttachOptions,
  type CreateOptions,
  type ExecOptions,
  type ExecResult,
  type RestoreOptions,
  type SnapshotRef,
  type VMHandle,
  type VMProvider,
} from "./types";

type Env = Readonly<Record<string, string | undefined>>;

export type HugeBlueProviderDependencies = {
  readonly env?: Env;
  readonly run?: (input: {
    readonly host: string;
    readonly command: string;
    readonly options: { readonly user?: string; readonly identityFile?: string; readonly proxyCommand?: string; readonly timeoutMs: number; readonly stdin?: Uint8Array };
  }) => Promise<ExecResult>;
};

const DEFAULT_TIMEOUT_MS = 30_000;
const MAX_TIMEOUT_MS = 120_000;

function bounded(value: string | undefined, name: string, max = 256): string | undefined {
  const trimmed = value?.trim();
  if (!trimmed) return undefined;
  if (trimmed.length > max || /[\u0000-\u001f\u007f]/.test(trimmed)) throw new Error(`${name} is invalid`);
  return trimmed;
}

function timeout(value: number | undefined): number {
  if (value === undefined) return DEFAULT_TIMEOUT_MS;
  if (!Number.isSafeInteger(value) || value < 1 || value > MAX_TIMEOUT_MS) throw new ProviderError("huge-blue", "exec timeout is invalid");
  return value;
}

function defaultRun(input: Parameters<NonNullable<HugeBlueProviderDependencies["run"]>>[0]): Promise<ExecResult> {
  return new Promise((resolve, reject) => {
    const args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new"];
    if (input.options.user) args.push("-o", `User=${input.options.user}`);
    if (input.options.identityFile) args.push("-i", input.options.identityFile);
    if (input.options.proxyCommand) args.push("-o", `ProxyCommand=${input.options.proxyCommand}`);
    args.push(input.host, "--", input.command);
    const child = spawn("ssh", args, { stdio: ["pipe", "pipe", "pipe"] });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    const timer = setTimeout(() => child.kill("SIGTERM"), input.options.timeoutMs);
    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.on("error", (cause) => { clearTimeout(timer); reject(cause); });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      resolve({
        exitCode: code ?? (signal ? 124 : 1),
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8"),
      });
    });
    if (input.options.stdin) child.stdin.end(Buffer.from(input.options.stdin));
    else child.stdin.end();
  });
}

/**
 * Huge Blue is a shared, long-lived Linux host rather than an API-created VM.
 * The provider therefore treats create/pause/resume as logical workspace
 * lifecycle operations and uses the authenticated SSH path for guest work.
 * Destructive VM operations are refused so a workspace cannot tear down the
 * host shared by other tenants.
 */
export class HugeBlueProvider implements VMProvider {
  readonly id = "huge-blue" as const;
  readonly attachTransports = ["cmux-remote"] as const;
  readonly capabilities = {
    snapshot: false,
    restore: false,
    fork: false,
    exec: true,
    stats: false,
    ports: false,
    desktop: false,
    sizing: false,
    persistentHome: false,
    attachTransports: ["cmux-remote"] as const,
  } as const;

  private readonly env: Env;
  private readonly runCommand: NonNullable<HugeBlueProviderDependencies["run"]>;

  constructor(deps: HugeBlueProviderDependencies = {}) {
    this.env = deps.env ?? process.env;
    this.runCommand = deps.run ?? defaultRun;
  }

  private config() {
    const host = bounded(this.env.HUGE_BLUE_SSH_HOST, "HUGE_BLUE_SSH_HOST");
    if (!host) throw new ProviderError("huge-blue", "HUGE_BLUE_SSH_HOST is required");
    const user = bounded(this.env.HUGE_BLUE_SSH_USER, "HUGE_BLUE_SSH_USER");
    const identityFile = bounded(this.env.HUGE_BLUE_SSH_KEY, "HUGE_BLUE_SSH_KEY");
    const proxyCommand = bounded(this.env.HUGE_BLUE_SSH_PROXY_COMMAND, "HUGE_BLUE_SSH_PROXY_COMMAND", 512);
    return {
      host,
      user,
      identityFile,
      proxyCommand,
      vmId: bounded(this.env.HUGE_BLUE_VM_ID, "HUGE_BLUE_VM_ID") ?? `huge-blue:${host}`,
      route: bounded(this.env.HUGE_BLUE_CMUX_REMOTE_URL, "HUGE_BLUE_CMUX_REMOTE_URL", 1024),
      token: bounded(this.env.HUGE_BLUE_CMUX_REMOTE_TOKEN, "HUGE_BLUE_CMUX_REMOTE_TOKEN", 1024),
      session: bounded(this.env.HUGE_BLUE_CMUX_REMOTE_SESSION, "HUGE_BLUE_CMUX_REMOTE_SESSION") ?? "cloud",
      cmuxTuiBin: bounded(this.env.HUGE_BLUE_CMUX_TUI_BIN, "HUGE_BLUE_CMUX_TUI_BIN") ?? "/home/leo/.local/bin/cmux-tui",
      cmuxAgentBin: bounded(this.env.HUGE_BLUE_CMUX_AGENT_BIN, "HUGE_BLUE_CMUX_AGENT_BIN") ?? "/home/leo/.local/bin/cmux",
    };
  }

  async create(options: CreateOptions): Promise<VMHandle> {
    const config = this.config();
    if (!options.image.trim()) throw new ProviderError("huge-blue", "create requires a resolved image");
    return {
      provider: this.id,
      providerVmId: config.vmId,
      status: "running",
      image: options.image,
      createdAt: Date.now(),
      providerMetadata: {
        transport: "ssh",
        host: config.host,
        ...(config.route ? { cmuxRemoteRoute: config.route } : {}),
      },
    };
  }

  async destroy(_vmId: string): Promise<void> {
    throw new ProviderError("huge-blue", "destroy is disabled for the shared host");
  }

  async pause(_vmId: string): Promise<void> {
    // Logical workspace suspension is persisted by the runtime; never suspend the shared host.
  }

  async resume(_vmId: string): Promise<VMHandle> {
    const config = this.config();
    return { provider: this.id, providerVmId: config.vmId, status: "running", image: "huge-blue-host", createdAt: Date.now() };
  }

  async getStatus(_vmId: string) {
    this.config();
    return "running" as const;
  }

  async exec(vmId: string, command: string, opts?: ExecOptions): Promise<ExecResult> {
    if (!vmId || !command || /[\u0000]/.test(command)) throw new ProviderError("huge-blue", "exec requires a VM id and command");
    const config = this.config();
    try {
      const commandForHost = command
        .replaceAll("/usr/local/bin/cmux-tui", config.cmuxTuiBin)
        .replaceAll("/usr/local/bin/cmux", config.cmuxAgentBin)
        .replaceAll("--session 'cloud'", `--session '${config.session}'`);
      return await this.runCommand({
        host: config.host,
        command: commandForHost,
        options: { user: config.user, identityFile: config.identityFile, proxyCommand: config.proxyCommand, timeoutMs: timeout(opts?.timeoutMs), stdin: opts?.stdin ? Buffer.from(opts.stdin.base64(), "base64") : undefined },
      });
    } catch (cause) {
      throw new ProviderError("huge-blue", `exec(${vmId}) failed`, cause);
    }
  }

  async snapshot(_vmId: string, _name?: string): Promise<SnapshotRef> {
    throw new ProviderError("huge-blue", "snapshots are not supported for the shared host");
  }

  async restore(_snapshotId: string, _options?: RestoreOptions): Promise<VMHandle> {
    throw new ProviderError("huge-blue", "restore is not supported for the shared host");
  }

  async openCmuxRemote(_vmId: string, options?: CmuxRemoteAttachOptions): Promise<CmuxRemoteEndpoint> {
    const config = this.config();
    const route = bounded(options?.providerMetadata?.cmuxRemoteRoute as string | undefined, "cmux remote route", 1024) ?? config.route;
    if (!route || !config.token) throw new ProviderError("huge-blue", "HUGE_BLUE_CMUX_REMOTE_URL and HUGE_BLUE_CMUX_REMOTE_TOKEN are required for attach");
    return {
      transport: "cmux-remote",
      route,
      token: config.token,
      expiresAtUnix: Math.floor(Date.now() / 1000) + 300,
      session: config.session,
      trustedCarrier: true,
    };
  }
}
