import type { Id } from "@cmux/convex/dataModel";
import { z } from "zod";
import { typedZid } from "./utils/typed-zid.js";

// Client to Server Events
export const CreateTerminalSchema = z.object({
  id: z.string().optional(),
  cols: z.number().int().positive().default(80),
  rows: z.number().int().positive().default(24),
});

export const TerminalInputSchema = z.object({
  terminalId: z.string(),
  data: z.string(),
});

export const ResizeSchema = z.object({
  terminalId: z.string(),
  cols: z.number().int().positive(),
  rows: z.number().int().positive(),
});

export const CloseTerminalSchema = z.object({
  terminalId: z.string(),
});

export const StartTaskSchema = z.object({
  repoUrl: z.string().optional(),
  branch: z.string().optional(),
  taskDescription: z.string(),
  projectFullName: z.string(),
  taskId: typedZid("tasks"),
  selectedAgents: z.array(z.string()).optional(),
  isCloudMode: z.boolean().optional().default(false),
  images: z
    .array(
      z.object({
        src: z.string(),
        fileName: z.string().optional(),
        altText: z.string(),
      })
    )
    .optional(),
  theme: z.enum(["dark", "light", "system"]).optional(),
  environmentId: typedZid("environments").optional(),
});

// Server to Client Events
export const TerminalCreatedSchema = z.object({
  terminalId: z.string(),
});

export const TerminalOutputSchema = z.object({
  terminalId: z.string(),
  data: z.string(),
});

export const TerminalExitSchema = z.object({
  terminalId: z.string(),
  exitCode: z.number().int(),
  signal: z.number().int().optional(),
});

export const TerminalClosedSchema = z.object({
  terminalId: z.string(),
});

export const TerminalClearSchema = z.object({
  terminalId: z.string(),
});

export const TerminalRestoreSchema = z.object({
  terminalId: z.string(),
  data: z.string(),
});

export const TaskStartedSchema = z.object({
  taskId: typedZid("tasks"),
  worktreePath: z.string(),
  terminalId: z.string(),
});

export const TaskErrorSchema = z.object({
  taskId: typedZid("tasks"),
  error: z.string(),
});

// Git diff events
export const GitStatusRequestSchema = z.object({
  workspacePath: z.string(),
});

export const GitDiffRequestSchema = z.object({
  workspacePath: z.string(),
  filePath: z.string(),
});

export const GitFullDiffRequestSchema = z.object({
  workspacePath: z.string(),
});

// Compare arbitrary refs within a repository (e.g., branch names or SHAs)
export const GitCompareRefsSchema = z.object({
  // Full repo name, e.g., "owner/name". Server will derive remote URL.
  repoFullName: z.string(),
  ref1: z.string(),
  ref2: z.string(),
});

// Landed diff request: compute what landed on base when head was integrated
export const GitLandedRefsSchema = z.object({
  repoFullName: z.string(),
  baseRef: z.string(),
  headRef: z.string(),
  b0Ref: z.string().optional(),
});

// Smart diff request: returns latest or landed depending on branch state
export const GitSmartRefsSchema = z.object({
  repoFullName: z.string(),
  baseRef: z.string(),
  headRef: z.string(),
  b0Ref: z.string().optional(),
});

export const GitFileSchema = z.object({
  path: z.string(),
  status: z.enum(["added", "modified", "deleted", "renamed"]),
  additions: z.number(),
  deletions: z.number(),
});

export const DiffLineSchema = z.object({
  type: z.enum(["addition", "deletion", "context", "header"]),
  content: z.string(),
  lineNumber: z
    .object({
      old: z.number().optional(),
      new: z.number().optional(),
    })
    .optional(),
});

export const GitStatusResponseSchema = z.object({
  files: z.array(GitFileSchema),
  error: z.string().optional(),
});

export const GitDiffResponseSchema = z.object({
  path: z.string(),
  diff: z.array(DiffLineSchema),
  error: z.string().optional(),
});

export const GitFileChangedSchema = z.object({
  workspacePath: z.string(),
  filePath: z.string(),
});

export const GitFullDiffResponseSchema = z.object({
  diff: z.string(),
  error: z.string().optional(),
});

export const OpenInEditorSchema = z.object({
  editor: z.enum([
    "vscode",
    "cursor",
    "windsurf",
    "finder",
    "iterm",
    "terminal",
    "ghostty",
    "alacritty",
    "xcode",
  ]),
  path: z.string(),
});

export const AvailableEditorsSchema = z.object({
  vscode: z.boolean().optional(),
  cursor: z.boolean().optional(),
  windsurf: z.boolean().optional(),
  finder: z.boolean().optional(),
  iterm: z.boolean().optional(),
  terminal: z.boolean().optional(),
  ghostty: z.boolean().optional(),
  alacritty: z.boolean().optional(),
  xcode: z.boolean().optional(),
});

export const OpenInEditorErrorSchema = z.object({
  error: z.string(),
});

export const OpenInEditorResponseSchema = z.object({
  success: z.boolean(),
  error: z.string().optional(),
});

// File listing events
export const ListFilesRequestSchema = z.object({
  repoPath: z.string(),
  branch: z.string().optional(),
  pattern: z.string().optional(), // Optional glob pattern for filtering
});

export const FileInfoSchema = z.object({
  path: z.string(),
  name: z.string(),
  isDirectory: z.boolean(),
  relativePath: z.string(),
});

export const ListFilesResponseSchema = z.object({
  files: z.array(FileInfoSchema),
  error: z.string().optional(),
});

// VSCode instance events (used for notifications)
export const VSCodeSpawnedSchema = z.object({
  instanceId: z.string(),
  url: z.string(),
  workspaceUrl: z.string(),
  provider: z.enum(["docker", "morph", "daytona"]),
});

export const VSCodeErrorSchema = z.object({
  error: z.string(),
});

// GitHub events
export const GitHubFetchReposSchema = z.object({
  teamSlugOrId: z.string(),
});

export const GitHubFetchBranchesSchema = z.object({
  teamSlugOrId: z.string(),
  repo: z.string(),
});

export const GitHubBranchesResponseSchema = z.object({
  success: z.boolean(),
  branches: z.array(z.string()),
  error: z.string().optional(),
});

export const GitHubReposResponseSchema = z.object({
  success: z.boolean(),
  repos: z
    .record(
      z.string(),
      z.array(
        z.object({
          fullName: z.string(),
          name: z.string(),
        })
      )
    )
    .optional(),
  error: z.string().optional(),
});

export const GitHubAuthResponseSchema = z.object({
  authStatus: z.string().optional(),
  whoami: z.string().optional(),
  home: z.string().optional(),
  ghConfig: z.string().optional(),
  processEnv: z
    .object({
      HOME: z.string().optional(),
      USER: z.string().optional(),
      GH_TOKEN: z.string(),
      GITHUB_TOKEN: z.string(),
    })
    .optional(),
  error: z.string().optional(),
});

// Create draft PR input
export const GitHubCreateDraftPrSchema = z.object({
  taskRunId: typedZid("taskRuns"),
});

// Open PR (create non-draft or convert draft to ready)
export const GitHubOpenPrSchema = z.object({
  taskRunId: typedZid("taskRuns"),
});

// Sync PR state
export const GitHubSyncPrStateSchema = z.object({
  taskRunId: typedZid("taskRuns"),
});

// Merge PR
export const GitHubMergePrSchema = z.object({
  taskRunId: typedZid("taskRuns"),
  method: z.enum(["squash", "rebase", "merge"]),
});

// Merge branch directly
export const GitHubMergeBranchSchema = z.object({
  taskRunId: typedZid("taskRuns"),
});

// Archive task schema
export const ArchiveTaskSchema = z.object({
  taskId: typedZid("tasks"),
});

export const SpawnFromCommentSchema = z.object({
  url: z.string(),
  page: z.string(),
  pageTitle: z.string(),
  nodeId: z.string(), // XPath to the element
  x: z.number(), // Relative position x (0-1)
  y: z.number(), // Relative position y (0-1)
  content: z.string(),
  userId: z.string(),
  commentId: typedZid("comments"),
  profileImageUrl: z.string().optional(),
  selectedAgents: z.array(z.string()).optional(),
  userAgent: z.string().optional(),
  screenWidth: z.number().optional(),
  screenHeight: z.number().optional(),
  devicePixelRatio: z.number().optional(),
});

// Provider status schemas
export const ProviderStatusSchema = z.object({
  name: z.string(),
  isAvailable: z.boolean(),
  missingRequirements: z.array(z.string()).optional(),
});

export const DockerStatusSchema = z.object({
  isRunning: z.boolean(),
  version: z.string().optional(),
  error: z.string().optional(),
  workerImage: z
    .object({
      name: z.string(),
      isAvailable: z.boolean(),
      isPulling: z.boolean().optional(),
    })
    .optional(),
});

export const GitStatusSchema = z.object({
  isAvailable: z.boolean(),
  version: z.string().optional(),
  remoteAccess: z.boolean().optional(),
  error: z.string().optional(),
});

export const GitHubStatusSchema = z.object({
  isConfigured: z.boolean(),
  hasToken: z.boolean(),
  error: z.string().optional(),
});

export const ProviderStatusResponseSchema = z.object({
  success: z.boolean(),
  providers: z.array(ProviderStatusSchema).optional(),
  dockerStatus: DockerStatusSchema.optional(),
  gitStatus: GitStatusSchema.optional(),
  githubStatus: GitHubStatusSchema.optional(),
  error: z.string().optional(),
});

// Default repo event
export const DefaultRepoSchema = z.object({
  repoFullName: z.string(),
  branch: z.string().optional(),
  localPath: z.string(),
});

// Type exports
export type CreateTerminal = z.infer<typeof CreateTerminalSchema>;
export type TerminalInput = z.infer<typeof TerminalInputSchema>;
export type Resize = z.infer<typeof ResizeSchema>;
export type CloseTerminal = z.infer<typeof CloseTerminalSchema>;
export type StartTask = z.infer<typeof StartTaskSchema>;
export type TerminalCreated = z.infer<typeof TerminalCreatedSchema>;
export type TerminalOutput = z.infer<typeof TerminalOutputSchema>;
export type TerminalExit = z.infer<typeof TerminalExitSchema>;
export type TerminalClosed = z.infer<typeof TerminalClosedSchema>;
export type TerminalClear = z.infer<typeof TerminalClearSchema>;
export type TerminalRestore = z.infer<typeof TerminalRestoreSchema>;
export type TaskStarted = z.infer<typeof TaskStartedSchema>;
export type TaskError = z.infer<typeof TaskErrorSchema>;
export type GitStatusRequest = z.infer<typeof GitStatusRequestSchema>;
export type GitDiffRequest = z.infer<typeof GitDiffRequestSchema>;
export type GitFile = z.infer<typeof GitFileSchema>;
export type DiffLine = z.infer<typeof DiffLineSchema>;
export type GitStatusResponse = z.infer<typeof GitStatusResponseSchema>;
export type GitDiffResponse = z.infer<typeof GitDiffResponseSchema>;
export type GitFileChanged = z.infer<typeof GitFileChangedSchema>;
export type GitFullDiffRequest = z.infer<typeof GitFullDiffRequestSchema>;
export type GitCompareRefs = z.infer<typeof GitCompareRefsSchema>;
export type GitFullDiffResponse = z.infer<typeof GitFullDiffResponseSchema>;
export type OpenInEditor = z.infer<typeof OpenInEditorSchema>;
export type OpenInEditorError = z.infer<typeof OpenInEditorErrorSchema>;
export type OpenInEditorResponse = z.infer<typeof OpenInEditorResponseSchema>;
export type AvailableEditors = z.infer<typeof AvailableEditorsSchema>;
export type ListFilesRequest = z.infer<typeof ListFilesRequestSchema>;
export type FileInfo = z.infer<typeof FileInfoSchema>;
export type ListFilesResponse = z.infer<typeof ListFilesResponseSchema>;
export type VSCodeSpawned = z.infer<typeof VSCodeSpawnedSchema>;
export type VSCodeError = z.infer<typeof VSCodeErrorSchema>;
export type GitHubFetchBranches = z.infer<typeof GitHubFetchBranchesSchema>;
export type GitHubBranchesResponse = z.infer<
  typeof GitHubBranchesResponseSchema
>;
export type GitHubReposResponse = z.infer<typeof GitHubReposResponseSchema>;
export type GitHubAuthResponse = z.infer<typeof GitHubAuthResponseSchema>;
export type GitHubCreateDraftPr = z.infer<typeof GitHubCreateDraftPrSchema>;
export type GitHubOpenPr = z.infer<typeof GitHubOpenPrSchema>;
export type GitHubSyncPrState = z.infer<typeof GitHubSyncPrStateSchema>;
export type GitHubMergePr = z.infer<typeof GitHubMergePrSchema>;
export type GitHubMergeBranch = z.infer<typeof GitHubMergeBranchSchema>;
export type ArchiveTask = z.infer<typeof ArchiveTaskSchema>;
export type SpawnFromComment = z.infer<typeof SpawnFromCommentSchema>;
export type ProviderStatus = z.infer<typeof ProviderStatusSchema>;
export type DockerStatus = z.infer<typeof DockerStatusSchema>;
export type GitStatus = z.infer<typeof GitStatusSchema>;
export type GitHubStatus = z.infer<typeof GitHubStatusSchema>;
export type GitHubFetchRepos = z.infer<typeof GitHubFetchReposSchema>;
export type ProviderStatusResponse = z.infer<
  typeof ProviderStatusResponseSchema
>;
export type DefaultRepo = z.infer<typeof DefaultRepoSchema>;

// Socket.io event map types
export interface ClientToServerEvents {
  // Terminal operations
  "start-task": (
    data: StartTask,
    callback: (response: TaskStarted | TaskError) => void
  ) => void;
  "git-diff-smart": (
    data: z.infer<typeof GitSmartRefsSchema>,
    callback: (
      response:
        | {
            ok: true;
            diffs: import("./diff-types.js").ReplaceDiffEntry[];
            strategy?: "latest" | "landed";
          }
        | { ok: false; error: string; diffs?: [] }
    ) => void
  ) => void;
  "git-status": (data: GitStatusRequest) => void;
  "git-diff": (data: GitDiffRequest) => void;
  "git-full-diff": (data: GitFullDiffRequest) => void;
  "git-diff-refs": (
    data: GitCompareRefs,
    callback: (
      response:
        | { ok: true; diffs: import("./diff-types.js").ReplaceDiffEntry[] }
        | { ok: false; error: string; diffs?: [] }
    ) => void
  ) => void;
  "git-diff-landed": (
    data: z.infer<typeof GitLandedRefsSchema>,
    callback: (
      response:
        | { ok: true; diffs: import("./diff-types.js").ReplaceDiffEntry[] }
        | { ok: false; error: string; diffs?: [] }
    ) => void
  ) => void;
  // On-demand diffs for a task run
  "get-run-diffs": (
    data: { taskRunId: Id<"taskRuns"> },
    callback: (
      response:
        | { ok: true; diffs: import("./diff-types.js").ReplaceDiffEntry[] }
        | { ok: false; error: string; diffs: [] }
    ) => void
  ) => void;
  "git-diff-file-contents": (
    data: { taskRunId: Id<"taskRuns">; filePath: string },
    callback: (
      response:
        | {
            ok: true;
            oldContent: string;
            newContent: string;
            isBinary: boolean;
          }
        | { ok: false; error: string }
    ) => void
  ) => void;
  "open-in-editor": (
    data: OpenInEditor,
    callback: (response: OpenInEditorResponse) => void
  ) => void;
  "list-files": (data: ListFilesRequest) => void;
  // GitHub operations
  "github-test-auth": (
    callback: (response: GitHubAuthResponse) => void
  ) => void;
  "github-fetch-repos": (
    data: GitHubFetchRepos,
    callback: (response: GitHubReposResponse) => void
  ) => void;
  "github-fetch-branches": (
    data: GitHubFetchBranches,
    callback: (response: GitHubBranchesResponse) => void
  ) => void;
  // Create a draft pull request for a given task run
  "github-create-draft-pr": (
    data: GitHubCreateDraftPr,
    callback: (response: {
      success: boolean;
      url?: string;
      error?: string;
    }) => void
  ) => void;
  // Open PR: create a normal PR or mark draft ready
  "github-open-pr": (
    data: GitHubOpenPr,
    callback: (response: {
      success: boolean;
      url?: string;
      state?: string;
      error?: string;
    }) => void
  ) => void;
  // Sync PR state with GitHub and update Convex
  "github-sync-pr-state": (
    data: GitHubSyncPrState,
    callback: (response: {
      success: boolean;
      url?: string;
      number?: number;
      state?: string;
      isDraft?: boolean;
      error?: string;
    }) => void
  ) => void;
  // Merge PR with selected method
  "github-merge-pr": (
    data: GitHubMergePr,
    callback: (response: {
      success: boolean;
      merged?: boolean;
      state?: string;
      url?: string;
      error?: string;
    }) => void
  ) => void;
  // Merge branch directly
  "github-merge-branch": (
    data: GitHubMergeBranch,
    callback: (response: {
      success: boolean;
      merged?: boolean;
      commitSha?: string;
      error?: string;
    }) => void
  ) => void;
  // Rust N-API test: returns current time
  "rust-get-time": (
    callback: (
      response: { ok: true; time: string } | { ok: false; error: string }
    ) => void
  ) => void;
  "check-provider-status": (
    callback: (response: ProviderStatusResponse) => void
  ) => void;
  "archive-task": (
    data: ArchiveTask,
    callback: (response: { success: boolean; error?: string }) => void
  ) => void;
  "spawn-from-comment": (
    data: SpawnFromComment,
    callback: (response: {
      success: boolean;
      taskId?: Id<"tasks">;
      taskRunId?: string;
      worktreePath?: string;
      terminalId?: string;
      vscodeUrl?: string;
      error?: string;
    }) => void
  ) => void;
}

export interface ServerToClientEvents {
  "task-started": (data: TaskStarted) => void;
  "task-error": (data: TaskError) => void;
  "git-status-response": (data: GitStatusResponse) => void;
  "git-diff-response": (data: GitDiffResponse) => void;
  "git-file-changed": (data: GitFileChanged) => void;
  "git-full-diff-response": (data: GitFullDiffResponse) => void;
  "open-in-editor-error": (data: OpenInEditorError) => void;
  "list-files-response": (data: ListFilesResponse) => void;
  "vscode-spawned": (data: VSCodeSpawned) => void;
  "vscode-error": (data: VSCodeError) => void;
  "default-repo": (data: DefaultRepo) => void;
  "available-editors": (data: AvailableEditors) => void;
}

// eslint-disable-next-line @typescript-eslint/no-empty-object-type
export interface InterServerEvents {
  // No inter-server events in this application
}

// eslint-disable-next-line @typescript-eslint/no-empty-object-type
export interface SocketData {
  // Additional data attached to each socket
}
