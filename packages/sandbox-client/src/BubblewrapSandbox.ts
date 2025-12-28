import { homedir } from "node:os";
import { Sandbox } from "./Sandbox.js";
import { SandboxdClient } from "./sandboxd-client.js";
import type {
  CreateTerminalOptions,
  ExecOptions,
  ExecResult,
  SandboxConfig,
  SandboxInfo,
} from "./types.js";

interface BubblewrapSandboxConfig extends SandboxConfig {
  /**
   * URL of the cmux-sandboxd server
   * - Local: http://localhost:46831
   * - Cloud: URL from www API (Morph instance)
   */
  sandboxdUrl: string;

  /**
   * For local mode, the host's cmux data directory.
   * This is used to convert host paths to sandboxd container paths.
   * Default: ~/cmux
   */
  hostDataDir?: string;

  /**
   * The cmux data directory inside the sandboxd container.
   * Default: /var/lib/cmux
   */
  containerDataDir?: string;
}

/**
 * Sandbox implementation that uses cmux-sandboxd HTTP API.
 * Works for both local mode (Docker container running sandboxd) and
 * cloud mode (Morph VM running sandboxd).
 */
export class BubblewrapSandbox extends Sandbox {
  private client: SandboxdClient;
  private sandboxId: string | null = null;
  private sandboxIndex: number | null = null;
  private connected: boolean = false;
  private hostDataDir: string;
  private containerDataDir: string;

  constructor(config: BubblewrapSandboxConfig) {
    super(config);
    this.client = new SandboxdClient(config.sandboxdUrl);

    // Set up path mapping for local mode
    // Host: ~/cmux -> Container: /var/lib/cmux
    this.hostDataDir = config.hostDataDir || `${homedir()}/cmux`;
    this.containerDataDir = config.containerDataDir || "/var/lib/cmux";
  }

  /**
   * Convert a host path to a container path.
   * For local mode, this converts ~/cmux/... to /var/lib/cmux/...
   */
  private toContainerPath(hostPath: string | undefined): string | undefined {
    if (!hostPath) return undefined;

    // If the path starts with the host data dir, convert to container path
    if (hostPath.startsWith(this.hostDataDir)) {
      return hostPath.replace(this.hostDataDir, this.containerDataDir);
    }

    // Return as-is (might already be a container path or cloud mode)
    return hostPath;
  }

  async start(): Promise<SandboxInfo> {
    // Convert host workspace path to container path for local mode
    const containerWorkspace = this.toContainerPath(this.config.workspacePath);

    console.log(`[BubblewrapSandbox] Starting sandbox:`);
    console.log(`  Host workspace: ${this.config.workspacePath}`);
    console.log(`  Container workspace: ${containerWorkspace}`);
    console.log(`  Host data dir: ${this.hostDataDir}`);
    console.log(`  Container data dir: ${this.containerDataDir}`);

    // Create sandbox via cmux-sandboxd API
    const sandbox = await this.client.createSandbox({
      name: `cmux-${this.taskRunId}`,
      workspace: containerWorkspace,
      tab_id: String(this.taskRunId),
      env: this.config.envVars
        ? Object.entries(this.config.envVars).map(([key, value]) => ({
            key,
            value,
          }))
        : [],
    });

    this.sandboxId = sandbox.id;
    this.sandboxIndex = sandbox.index;

    console.log(`[BubblewrapSandbox] Sandbox created:`);
    console.log(`  ID: ${this.sandboxId}`);
    console.log(`  Index: ${this.sandboxIndex}`);
    console.log(`  Status: ${sandbox.status}`);

    // Wait for services to be ready if the endpoint exists
    // Note: await-ready endpoint may not be available in all sandboxd versions
    try {
      const readyResponse = await this.client.awaitReady(this.sandboxId, {
        services: ["vscode", "pty"],
        timeout_ms: 30000,
      });

      if (!readyResponse.ready) {
        throw new Error(
          `Services not ready: ${readyResponse.timed_out?.join(", ") || "unknown"}`,
        );
      }
    } catch (error) {
      // If await-ready returns 404, the endpoint doesn't exist - continue anyway
      if (
        error instanceof Error &&
        "statusCode" in error &&
        (error as { statusCode: number }).statusCode === 404
      ) {
        // Endpoint not available, proceed without waiting for services
      } else {
        // Other errors - clean up and rethrow
        await this.cleanupSandbox();
        throw error;
      }
    }

    this.connected = true;

    // Build URLs using subdomain proxy format: {index}-{port}.localhost:46831
    const vscodeUrl = this.client.getSubdomainUrl(this.sandboxIndex, 39378);
    const workspaceUrl = this.getWorkspaceUrl(vscodeUrl);

    return {
      url: vscodeUrl,
      workspaceUrl,
      instanceId: String(this.instanceId),
      taskRunId: this.taskRunId,
      provider: "bubblewrap",
    };
  }

  /**
   * Clean up the sandbox by deleting it from sandboxd.
   * Used internally for cleanup on failure and by stop().
   */
  private async cleanupSandbox(): Promise<void> {
    if (this.sandboxId) {
      try {
        await this.client.deleteSandbox(this.sandboxId);
      } catch (error) {
        console.error(`Failed to delete sandbox ${this.sandboxId}:`, error);
      }
      this.sandboxId = null;
      this.sandboxIndex = null;
    }
  }

  async stop(): Promise<void> {
    await this.cleanupSandbox();
    this.connected = false;
    await this.baseStop();
  }

  async getStatus(): Promise<{ running: boolean; info?: SandboxInfo }> {
    if (!this.sandboxId) {
      return { running: false };
    }

    try {
      const sandbox = await this.client.getSandbox(this.sandboxId);
      if (!sandbox) {
        return { running: false };
      }

      const running = sandbox.status === "Running";

      if (running && this.sandboxIndex !== null) {
        const vscodeUrl = this.client.getSubdomainUrl(this.sandboxIndex, 39378);

        return {
          running: true,
          info: {
            url: vscodeUrl,
            workspaceUrl: this.getWorkspaceUrl(vscodeUrl),
            instanceId: String(this.instanceId),
            taskRunId: this.taskRunId,
            provider: "bubblewrap",
          },
        };
      }

      return { running: false };
    } catch {
      return { running: false };
    }
  }

  getName(): string {
    return `bubblewrap-${this.sandboxId || this.instanceId}`;
  }

  async exec(opts: ExecOptions): Promise<ExecResult> {
    if (!this.sandboxId) {
      throw new Error("Sandbox not started");
    }

    const response = await this.client.exec(
      this.sandboxId,
      {
        command: [opts.command, ...opts.args],
        workdir: opts.cwd || "/workspace",
        env: opts.env
          ? Object.entries(opts.env).map(([key, value]) => ({ key, value }))
          : [],
      },
      opts.timeout ? AbortSignal.timeout(opts.timeout) : undefined,
    );

    return {
      exitCode: response.exit_code,
      stdout: response.stdout,
      stderr: response.stderr,
    };
  }

  async uploadFile(path: string, content: Buffer): Promise<void> {
    if (!this.sandboxId) {
      throw new Error("Sandbox not started");
    }

    // Create a simple tar with just this file
    // For now, use exec to write the file
    const base64Content = content.toString("base64");
    await this.exec({
      command: "sh",
      args: [
        "-c",
        `mkdir -p "$(dirname "${path}")" && echo "${base64Content}" | base64 -d > "${path}"`,
      ],
    });
  }

  async uploadTar(tarBuffer: Buffer | Uint8Array): Promise<void> {
    if (!this.sandboxId) {
      throw new Error("Sandbox not started");
    }

    // Convert Buffer to Uint8Array for the client
    const data =
      tarBuffer instanceof Uint8Array ? tarBuffer : new Uint8Array(tarBuffer);

    await this.client.uploadFiles(this.sandboxId, data);
  }

  async createTerminal(opts: CreateTerminalOptions): Promise<void> {
    if (!this.sandboxId) {
      throw new Error("Sandbox not started");
    }

    // Use cmux-sandboxd's PTY API to create a terminal session
    // Note: cmux-pty expects env as a plain object (HashMap), not EnvVar[]
    await this.client.createPtySession(this.sandboxId, {
      name: opts.terminalId,
      command: opts.command,
      args: opts.args,
      cols: opts.cols || 80,
      rows: opts.rows || 24,
      cwd: opts.cwd || "/workspace",
      env: opts.env,
    });

    // Handle auth files if provided
    if (opts.authFiles && opts.authFiles.length > 0) {
      for (const file of opts.authFiles) {
        await this.uploadFile(file.path, Buffer.from(file.content));
        if (file.mode) {
          await this.exec({
            command: "chmod",
            args: [file.mode.toString(8), file.path],
          });
        }
      }
    }

    // Run startup commands if provided
    if (opts.startupCommands && opts.startupCommands.length > 0) {
      for (const cmd of opts.startupCommands) {
        await this.exec({
          command: "sh",
          args: ["-c", cmd],
          cwd: opts.cwd || "/workspace",
        });
      }
    }
  }

  startFileWatch(_worktreePath: string): void {
    // File watching is handled by the worker inside the sandbox
    // For bubblewrap sandboxes, we need to use the PTY/worker connection
    // This will be implemented when we integrate with the worker
    this.emit("file-watch-started");
  }

  stopFileWatch(): void {
    // Stop file watching
    this.emit("file-watch-stopped");
  }

  isConnected(): boolean {
    return this.connected && this.sandboxId !== null;
  }

  /**
   * Get the sandbox ID (useful for debugging)
   */
  getSandboxId(): string | null {
    return this.sandboxId;
  }

  /**
   * Get the sandbox index (used for subdomain routing)
   */
  getSandboxIndex(): number | null {
    return this.sandboxIndex;
  }

  /**
   * Get the underlying sandboxd client for advanced operations
   */
  getClient(): SandboxdClient {
    return this.client;
  }

  /**
   * Override workspace URL for bubblewrap sandboxes.
   * Bubblewrap mounts the workspace at /workspace, not /root/workspace.
   */
  protected getWorkspaceUrl(baseUrl: string): string {
    return `${baseUrl}/?folder=/workspace`;
  }
}

export type { BubblewrapSandboxConfig };
