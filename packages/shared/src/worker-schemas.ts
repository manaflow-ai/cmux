import type { Id } from "@cmux/convex/dataModel";
import { z } from "zod";
import { typedZid } from "./utils/typed-zid";

// Auth file schema for file uploads and environment setup
export const AuthFileSchema = z.object({
  destinationPath: z.string(),
  contentBase64: z.string(), // base64 encoded
  mode: z.string().optional(),
});

// Worker Registration
export const WorkerRegisterSchema = z.object({
  workerId: z.string(),
  capabilities: z.object({
    maxConcurrentTerminals: z.number().int().positive(),
    supportedLanguages: z.array(z.string()).optional(),
    gpuAvailable: z.boolean().optional(),
    memoryMB: z.number().int().positive(),
    cpuCores: z.number().int().positive(),
  }),
  containerInfo: z
    .object({
      image: z.string(),
      version: z.string(),
      platform: z.string(),
    })
    .optional(),
});

export const WorkerHeartbeatSchema = z.object({
  workerId: z.string(),
  timestamp: z.number(),
  stats: z.object({
    cpuUsage: z.number().min(0).max(100),
    memoryUsage: z.number().min(0).max(100),
  }),
});

// Terminal Routing
export const TerminalAssignmentSchema = z.object({
  terminalId: z.string(),
  workerId: z.string(),
  taskId: typedZid("tasks").optional(),
});

// Worker Status
export const WorkerStatusSchema = z.object({
  workerId: z.string(),
  status: z.enum(["online", "offline", "busy", "error"]),
  lastSeen: z.number(),
});

export const WorkerTaskRunContextSchema = z.object({
  taskRunToken: z.string(),
  prompt: z.string(),
  convexUrl: z.string(),
});

// Terminal operation schemas for server<>worker communication
export const WorkerCreateTerminalSchema = z.object({
  terminalId: z.string(),
  cols: z.number().int().positive().default(80),
  rows: z.number().int().positive().default(24),
  cwd: z.string().optional(),
  env: z.record(z.string(), z.string()).optional(),
  taskRunContext: WorkerTaskRunContextSchema,
  command: z.string().optional(),
  args: z.array(z.string()).optional(),
  taskId: typedZid("tasks").optional(),
  taskRunId: typedZid("taskRuns").optional(),
  // Validation happens on the server where configs can be updated without
  // rebuilding the worker image.
  agentModel: z.string().optional(),
  authFiles: z.array(AuthFileSchema).optional(),
  startupCommands: z.array(z.string()).optional(),
});

export const WorkerTerminalInputSchema = z.object({
  terminalId: z.string(),
  data: z.string(),
});

export const WorkerResizeTerminalSchema = z.object({
  terminalId: z.string(),
  cols: z.number().int().positive(),
  rows: z.number().int().positive(),
});

export const WorkerCloseTerminalSchema = z.object({
  terminalId: z.string(),
});

// Worker terminal event schemas
export const WorkerTerminalOutputSchema = z.object({
  workerId: z.string(),
  terminalId: z.string(),
  data: z.string(),
});

export const WorkerTerminalExitSchema = z.object({
  workerId: z.string(),
  terminalId: z.string(),
  exitCode: z.number().int(),
  signal: z.number().int().optional(),
});

export const WorkerTerminalCreatedSchema = z.object({
  workerId: z.string(),
  terminalId: z.string(),
});

export const WorkerTerminalClosedSchema = z.object({
  workerId: z.string(),
  terminalId: z.string(),
});

export const WorkerTerminalIdleSchema = z.object({
  workerId: z.string(),
  terminalId: z.string(),
  taskRunId: typedZid("taskRuns").optional(),
  elapsedMs: z.number(),
});

// Task completion detected from project files (e.g., Claude Code)
export const WorkerTaskCompleteSchema = z.object({
  workerId: z.string(),
  taskRunId: typedZid("taskRuns"),
  agentModel: z.string().optional(),
  elapsedMs: z.number(),
});

// Terminal failure event (e.g., tmux spawn/agent command failed)
export const WorkerTerminalFailedSchema = z.object({
  workerId: z.string(),
  terminalId: z.string(),
  taskRunId: typedZid("taskRuns").optional(),
  errorMessage: z.string(),
  elapsedMs: z.number().optional(),
});

// File upload schema for authentication files
export const WorkerUploadFilesSchema = z.object({
  files: z.array(
    z.object({
      sourcePath: z.string(), // Path on host
      destinationPath: z.string(), // Path in container
      content: z.string(), // Base64 encoded file content
      mode: z.string().optional(), // File permissions (e.g., "644")
    })
  ),
  terminalId: z.string().optional(), // Optional terminal context
});

// Git configuration schema
export const WorkerConfigureGitSchema = z.object({
  githubToken: z.string().optional(),
  gitConfig: z.record(z.string(), z.string()).optional(), // Key-value pairs for git config
  sshKeys: z
    .object({
      privateKey: z.string().optional(), // Base64 encoded
      publicKey: z.string().optional(), // Base64 encoded
      knownHosts: z.string().optional(), // Base64 encoded
    })
    .optional(),
});

// Execute command schema for one-off commands
export const WorkerExecSchema = z.object({
  command: z.string(),
  args: z.array(z.string()).optional(),
  cwd: z.string().optional(),
  env: z.record(z.string(), z.string()).optional(),
  timeout: z.number().optional(), // Timeout in milliseconds
});

// Execute command result schema
export const WorkerExecResultSchema = z.object({
  stdout: z.string(),
  stderr: z.string(),
  exitCode: z.number(),
  signal: z.string().optional(),
});

export const WorkerStartScreenshotCollectionSchema = z.object({
  openAiApiKey: z.string().min(1).optional(),
});

// Server to Worker Events
export const ServerToWorkerCommandSchema = z.object({
  command: z.enum(["create-terminal", "destroy-terminal", "execute-command"]),
  payload: z.any(),
});

// Type exports
export type AuthFile = z.infer<typeof AuthFileSchema>;
export type WorkerRegister = z.infer<typeof WorkerRegisterSchema>;
export type WorkerHeartbeat = z.infer<typeof WorkerHeartbeatSchema>;
export type TerminalAssignment = z.infer<typeof TerminalAssignmentSchema>;
export type WorkerStatus = z.infer<typeof WorkerStatusSchema>;
export type WorkerTaskRunContext = z.infer<typeof WorkerTaskRunContextSchema>;
export type ServerToWorkerCommand = z.infer<typeof ServerToWorkerCommandSchema>;
export type WorkerCreateTerminal = z.infer<typeof WorkerCreateTerminalSchema>;
export type WorkerTerminalInput = z.infer<typeof WorkerTerminalInputSchema>;
export type WorkerResizeTerminal = z.infer<typeof WorkerResizeTerminalSchema>;
export type WorkerCloseTerminal = z.infer<typeof WorkerCloseTerminalSchema>;
export type WorkerTerminalOutput = z.infer<typeof WorkerTerminalOutputSchema>;
export type WorkerTerminalExit = z.infer<typeof WorkerTerminalExitSchema>;
export type WorkerTerminalCreated = z.infer<typeof WorkerTerminalCreatedSchema>;
export type WorkerTerminalClosed = z.infer<typeof WorkerTerminalClosedSchema>;
export type WorkerTerminalIdle = z.infer<typeof WorkerTerminalIdleSchema>;
export type WorkerTaskComplete = z.infer<typeof WorkerTaskCompleteSchema>;
export type WorkerTerminalFailed = z.infer<typeof WorkerTerminalFailedSchema>;
export type WorkerUploadFiles = z.infer<typeof WorkerUploadFilesSchema>;
export type WorkerConfigureGit = z.infer<typeof WorkerConfigureGitSchema>;
export type WorkerExec = z.infer<typeof WorkerExecSchema>;
export type WorkerExecResult = z.infer<typeof WorkerExecResultSchema>;
export type WorkerStartScreenshotCollection = z.infer<
  typeof WorkerStartScreenshotCollectionSchema
>;

// Socket.io event maps for Server <-> Worker communication
// Docker readiness response type

type ErrorOr<T> = { error: Error; data: null } | { error: null; data: T };
export interface DockerReadinessResponse {
  ready: boolean;
  message?: string;
}

export interface ServerToWorkerEvents {
  // Terminal operations from server to worker
  "worker:create-terminal": (
    data: WorkerCreateTerminal,
    callback: (result: ErrorOr<WorkerTerminalCreated>) => void
  ) => void;

  // Terminal input
  "worker:terminal-input": (data: WorkerTerminalInput) => void;

  // File operations
  "worker:upload-files": (data: WorkerUploadFiles) => void;

  // Git configuration
  "worker:configure-git": (data: WorkerConfigureGit) => void;

  // Execute one-off commands
  "worker:exec": (
    data: WorkerExec,
    callback: (result: ErrorOr<WorkerExecResult>) => void
  ) => void;

  // File watching events
  "worker:start-file-watch": (data: {
    taskRunId: Id<"taskRuns">;
    worktreePath: string;
  }) => void;
  "worker:stop-file-watch": (data: { taskRunId: Id<"taskRuns"> }) => void;
  "worker:start-screenshot-collection": (
    data: WorkerStartScreenshotCollection | undefined
  ) => void;

  // Management events
  "worker:terminal-assignment": (data: TerminalAssignment) => void;
  "worker:command": (data: ServerToWorkerCommand) => void;
  "worker:shutdown": () => void;

  // Health check events with acknowledgment
  "worker:check-docker": (
    callback: (response: DockerReadinessResponse) => void
  ) => void;
}

export interface WorkerFileChange {
  type: "added" | "modified" | "deleted";
  path: string;
  timestamp: number;
}

export interface WorkerFileDiff {
  path: string;
  type: "added" | "modified" | "deleted";
  oldContent: string;
  newContent: string;
  patch: string;
}

export interface WorkerToServerEvents {
  // Registration and health
  "worker:register": (data: WorkerRegister) => void;
  "worker:heartbeat": (data: WorkerHeartbeat) => void;

  // Terminal events from worker to server
  "worker:terminal-created": (data: WorkerTerminalCreated) => void;
  "worker:terminal-output": (data: WorkerTerminalOutput) => void;
  "worker:terminal-exit": (data: WorkerTerminalExit) => void;
  "worker:terminal-closed": (data: WorkerTerminalClosed) => void;
  "worker:terminal-idle": (data: WorkerTerminalIdle) => void;
  "worker:task-complete": (data: WorkerTaskComplete) => void;
  "worker:terminal-failed": (data: WorkerTerminalFailed) => void;

  // File change events
  "worker:file-changes": (data: {
    workerId: string;
    taskRunId: Id<"taskRuns">;
    changes: WorkerFileChange[];
    gitDiff: string;
    fileDiffs: WorkerFileDiff[];
    timestamp: number;
  }) => void;

  // Error reporting
  "worker:error": (data: { workerId: string; error: string }) => void;
}
export type WorkerToServerEventNames = keyof WorkerToServerEvents;

// For worker's internal socket server (client connections)
export interface WorkerSocketData {
  workerId: string;
  assignedTerminals: Set<string>;
}
