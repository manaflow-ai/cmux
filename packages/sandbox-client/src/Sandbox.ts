import type { Id } from "@cmux/convex/dataModel";
import { EventEmitter } from "node:events";
import type {
  CreateTerminalOptions,
  ExecOptions,
  ExecResult,
  SandboxConfig,
  SandboxInfo,
} from "./types.js";

/**
 * Abstract base class for sandbox implementations.
 * Implementations can use different transports (HTTP, socket.io, etc.)
 */
export abstract class Sandbox extends EventEmitter {
  // Static registry of all sandbox instances
  protected static instances = new Map<Id<"taskRuns">, Sandbox>();

  protected config: SandboxConfig;
  protected instanceId: Id<"taskRuns">;
  protected taskRunId: Id<"taskRuns">;
  protected taskId: Id<"tasks">;
  protected teamSlugOrId: string;

  constructor(config: SandboxConfig) {
    super();
    this.config = config;
    this.taskRunId = config.taskRunId;
    this.taskId = config.taskId;
    this.teamSlugOrId = config.teamSlugOrId;
    // Use taskRunId as instanceId for backward compatibility
    this.instanceId = config.taskRunId;

    // Register this instance
    Sandbox.instances.set(this.instanceId, this);
  }

  // Static methods to manage instances
  static getInstances(): Map<Id<"taskRuns">, Sandbox> {
    return Sandbox.instances;
  }

  static getInstance(instanceId: Id<"taskRuns">): Sandbox | undefined {
    return Sandbox.instances.get(instanceId);
  }

  static clearInstances(): void {
    Sandbox.instances.clear();
  }

  // Abstract methods that each implementation must provide
  abstract start(): Promise<SandboxInfo>;
  abstract stop(): Promise<void>;
  abstract getStatus(): Promise<{
    running: boolean;
    info?: SandboxInfo;
  }>;
  abstract getName(): string;

  /**
   * Execute a command in the sandbox
   */
  abstract exec(opts: ExecOptions): Promise<ExecResult>;

  /**
   * Upload a file to the sandbox
   */
  abstract uploadFile(path: string, content: Buffer): Promise<void>;

  /**
   * Upload a tar archive to the sandbox (extracts at root)
   */
  abstract uploadTar(tarBuffer: Buffer): Promise<void>;

  /**
   * Create a terminal session in the sandbox
   */
  abstract createTerminal(opts: CreateTerminalOptions): Promise<void>;

  /**
   * Start watching files for changes in the sandbox
   */
  abstract startFileWatch(worktreePath: string): void;

  /**
   * Stop watching files for changes
   */
  abstract stopFileWatch(): void;

  /**
   * Check if the sandbox is connected/ready
   */
  abstract isConnected(): boolean;

  // Common instance methods
  getInstanceId(): Id<"taskRuns"> {
    return this.instanceId;
  }

  getTaskRunId(): Id<"taskRuns"> {
    return this.taskRunId;
  }

  protected getWorkspaceUrl(baseUrl: string): string {
    return `${baseUrl}/?folder=/root/workspace`;
  }

  /**
   * Base stop implementation - removes from registry
   * Subclasses should call this at the end of their stop() method
   */
  protected async baseStop(): Promise<void> {
    Sandbox.instances.delete(this.instanceId);
  }
}
