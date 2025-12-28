import type { Id } from "@cmux/convex/dataModel";

export interface SandboxConfig {
  workspacePath?: string;
  initialCommand?: string;
  agentName?: string;
  taskRunId: Id<"taskRuns">;
  taskId: Id<"tasks">;
  theme?: "dark" | "light" | "system";
  teamSlugOrId: string;
  // Optional: for hydrating repo on start
  repoUrl?: string;
  branch?: string;
  newBranch?: string;
  // Optional: when starting from an environment
  environmentId?: Id<"environments"> | string;
  // Optional: JWT token for crown workflow authentication
  taskRunJwt?: string;
  // Optional: environment variables to pass to the sandbox
  envVars?: Record<string, string>;
}

export interface SandboxInfo {
  url: string;
  workspaceUrl: string;
  instanceId: string;
  taskRunId: Id<"taskRuns">;
  provider: "docker" | "morph" | "daytona" | "bubblewrap";
  /** If true, sandbox URLs were already persisted to Convex */
  vscodePersisted?: boolean;
}

export interface ExecOptions {
  command: string;
  args: string[];
  cwd?: string;
  env?: Record<string, string>;
  timeout?: number;
}

export interface ExecResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

export interface CreateTerminalOptions {
  terminalId: string;
  command?: string;
  args?: string[];
  cols?: number;
  rows?: number;
  env?: Record<string, string>;
  cwd?: string;
  taskRunId?: string;
  agentModel?: string;
  authFiles?: Array<{ path: string; content: string; mode?: number }>;
  startupCommands?: string[];
  postStartCommands?: Array<{ command: string; timeout?: number }>;
  backend?: "tmux" | "cmux-pty";
  ptyCommand?: string;
  taskRunContext?: {
    taskRunToken: string;
    prompt: string;
    convexUrl: string;
  };
}
