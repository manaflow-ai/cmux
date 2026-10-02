// Source data of a Codex thread, as the Codex app-server protocol (v2) defines it.
//
// These types are the subset of `codex app-server generate-ts` output (codex-cli 0.160.0,
// `v2/ThreadItem.ts`, `v2/Turn.ts`, `v2/CommandAction.ts`, `v2/FileUpdateChange.ts`,
// `WebSearchItem.ts`, ...) that the desktop transcript renders. Field names and unions are
// kept verbatim so real app-server payloads and rollout files (see rollout.ts) load without
// renaming. Fields the transcript never reads are omitted, not renamed. See
// docs/codex-data-model.md for the full list and the evidence.

/* ---------------- Thread / turn ---------------- */

export type TurnStatus = "completed" | "interrupted" | "failed" | "inProgress";

export type Turn = {
  /** UUIDv7. */
  id: string;
  /** Items in emission order (user message first). */
  items: ThreadItem[];
  status: TurnStatus;
  error?: { message: string } | null;
  /** Unix seconds. */
  startedAt: number | null;
  completedAt: number | null;
  /** Turn duration in ms; the "Worked for" label of a reloaded thread. */
  durationMs: number | null;
  /**
   * Not protocol: when the final answer started streaming (ms), which the app records from
   * item notifications while a turn runs. A turn watched live reads "Worked for" from the
   * turn's start to this moment (see derive.ts `workedForMs`).
   */
  finalAnswerStartedAtMs?: number | null;
};

/* ---------------- Items ---------------- */

export type ThreadItem =
  | UserMessageItem
  | AgentMessageItem
  | ReasoningItem
  | PlanItem
  | CommandExecutionItem
  | FileChangeItem
  | McpToolCallItem
  | DynamicToolCallItem
  | WebSearchThreadItem
  | ImageViewItem
  | SleepThreadItem
  | ContextCompactionItem;

export type UserInput =
  | { type: "text"; text: string }
  | { type: "image"; url: string }
  | { type: "localImage"; path: string }
  | { type: "skill"; name: string; path: string }
  | { type: "mention"; name: string; path: string };

export type UserMessageItem = { type: "userMessage"; id: string; content: UserInput[] };

/** `commentary` is interim narration inside the activity; `final_answer` closes the turn. */
export type MessagePhase = "commentary" | "final_answer";

export type AgentMessageItem = {
  type: "agentMessage";
  id: string;
  /** Markdown. */
  text: string;
  phase: MessagePhase | null;
};

export type ReasoningItem = {
  type: "reasoning";
  id: string;
  /** Summary paragraphs; the first `**bold**` heading is the live "thinking" row. */
  summary: string[];
  content: string[];
};

export type PlanItem = { type: "plan"; id: string; text: string };

/** Best-effort parse of a shell command (`v2/CommandAction.ts`). */
export type CommandAction =
  | { type: "read"; command: string; name: string; path: string }
  | { type: "listFiles"; command: string; path: string | null }
  | { type: "search"; command: string; query: string | null; path: string | null }
  | { type: "unknown"; command: string };

export type CommandExecutionStatus = "inProgress" | "completed" | "failed" | "declined";

export type CommandExecutionItem = {
  type: "commandExecution";
  id: string;
  /** Shell command line as the model wrote it (the `-lc` argument). */
  command: string;
  cwd: string;
  status: CommandExecutionStatus;
  commandActions: CommandAction[];
  /** stdout + stderr. */
  aggregatedOutput: string | null;
  exitCode: number | null;
  durationMs: number | null;
};

export type PatchChangeKind =
  | { type: "add" }
  | { type: "delete" }
  | { type: "update"; move_path: string | null };

export type FileUpdateChange = {
  path: string;
  kind: PatchChangeKind;
  /** Unified diff (hunks only, no file headers). */
  diff: string;
};

export type PatchApplyStatus = "inProgress" | "completed" | "failed" | "declined";

export type FileChangeItem = {
  type: "fileChange";
  id: string;
  changes: FileUpdateChange[];
  status: PatchApplyStatus;
};

export type McpToolCallStatus = "inProgress" | "completed" | "failed";

/** One block of MCP `content` (text or image). */
export type McpContent = { type: "text"; text: string } | { type: "image"; mimeType?: string };

export type McpToolCallItem = {
  type: "mcpToolCall";
  id: string;
  server: string;
  tool: string;
  status: McpToolCallStatus;
  /** Tool arguments; Computer Use calls carry a human `title`. */
  arguments: Record<string, unknown> | null;
  pluginId: string | null;
  result: {
    content: McpContent[];
    /** `codex/toolSurface` names the app or browser the call drove. */
    _meta?: { "codex/toolSurface"?: ToolSurface } & Record<string, unknown>;
  } | null;
  error: { message: string } | null;
  durationMs: number | null;
};

/** Where a Computer Use call acted (`_meta["codex/toolSurface"]` of the result). */
export type ToolSurface =
  | { kind: "browserUse"; backend?: string; browserId?: string }
  | { kind: "computerUse"; app: { kind: "appId"; appId: string } | null };

export type DynamicToolCallItem = {
  type: "dynamicToolCall";
  id: string;
  namespace: string | null;
  tool: string;
  arguments: unknown;
  status: "inProgress" | "completed" | "failed";
  success: boolean | null;
  durationMs: number | null;
};

export type WebSearchAction =
  | { type: "search"; query: string | null; queries: string[] | null }
  | { type: "openPage"; url: string | null }
  | { type: "findInPage"; url: string | null; pattern: string | null }
  | { type: "other" };

export type WebSearchThreadItem = {
  type: "webSearch";
  id: string;
  /** Display query (already ellipsized by the model, e.g. "… RLM paper agent harness ..."). */
  query: string;
  action: WebSearchAction | null;
};

export type ImageViewItem = { type: "imageView"; id: string; path: string };

export type SleepThreadItem = { type: "sleep"; id: string; durationMs: number };

export type ContextCompactionItem = { type: "contextCompaction"; id: string };
