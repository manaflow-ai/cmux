/**
 * Canonical types for cmux101. This is the contract every component agrees on.
 *
 * If you find yourself wanting to widen these, do it here once and propagate.
 * Provider adapters normalize INTO these types; tools and the runner only see
 * these types. UI layers consume StreamEvent for live rendering.
 */

import type { ZodTypeAny } from "zod";

// ----------------------------------------------------------------------------
// Messages & content
// ----------------------------------------------------------------------------

export type Role = "system" | "user" | "assistant" | "tool";

export type ContentBlock =
  | TextBlock
  | ToolUseBlock
  | ToolResultBlock
  | ImageBlock
  | ThinkingBlock;

export interface TextBlock {
  type: "text";
  text: string;
}

export interface ToolUseBlock {
  type: "tool_use";
  id: string;
  name: string;
  input: unknown; // validated against tool's inputSchema at invocation time
}

export interface ToolResultBlock {
  type: "tool_result";
  tool_use_id: string;
  /** When the tool returned an error, set is_error=true. content is human-readable. */
  is_error?: boolean;
  content: string | Array<TextBlock | ImageBlock>;
}

export interface ImageBlock {
  type: "image";
  source:
    | { kind: "base64"; mediaType: string; data: string }
    | { kind: "url"; url: string };
}

/**
 * Thinking / reasoning block. Anthropic emits these natively; OpenAI o-series
 * exposes redacted reasoning summaries; Gemini uses thought parts. Adapters
 * map provider-native shapes into this normalized form.
 */
export interface ThinkingBlock {
  type: "thinking";
  thinking: string;
  /** Opaque signature/ID from provider, required to round-trip back to it. */
  signature?: string;
}

export interface Message {
  role: Role;
  content: ContentBlock[];
}

// ----------------------------------------------------------------------------
// Streaming events (provider -> runner -> UI)
// ----------------------------------------------------------------------------

export type StreamEvent =
  | { kind: "message_start"; messageId: string }
  | { kind: "text_delta"; text: string }
  | { kind: "thinking_delta"; text: string; signature?: string }
  | { kind: "tool_call_start"; id: string; name: string }
  | { kind: "tool_call_input_delta"; id: string; jsonDelta: string }
  | { kind: "tool_call_end"; id: string; input: unknown }
  | { kind: "usage"; inputTokens: number; outputTokens: number; cacheReadTokens?: number; cacheCreationTokens?: number }
  | { kind: "message_stop"; reason: StopReason }
  | { kind: "error"; error: ProviderError };

export type StopReason =
  | "end_turn"
  | "tool_use"
  | "max_tokens"
  | "stop_sequence"
  | "refusal"
  | "error";

export class ProviderError extends Error {
  constructor(
    message: string,
    readonly provider: string,
    readonly status?: number,
    readonly retryable: boolean = false,
    readonly cause?: unknown,
  ) {
    super(message);
    this.name = "ProviderError";
  }
}

// ----------------------------------------------------------------------------
// Provider abstraction
// ----------------------------------------------------------------------------

export interface ProviderRequest {
  model: string;
  messages: Message[];
  system?: string;
  tools?: ToolSchema[];
  maxTokens?: number;
  temperature?: number;
  topP?: number;
  stopSequences?: string[];
  /** Provider-specific options pass through opaquely. */
  providerOptions?: Record<string, unknown>;
  abortSignal?: AbortSignal;
}

export interface ToolSchema {
  name: string;
  description: string;
  /** JSON Schema (derived from zod) shown to the model. */
  inputSchema: Record<string, unknown>;
}

export interface ModelInfo {
  id: string;
  displayName: string;
  contextWindow: number;
  maxOutput: number;
  supportsTools: boolean;
  supportsVision: boolean;
  supportsThinking: boolean;
}

export interface Provider {
  /** Unique short ID, e.g. "anthropic". */
  readonly id: string;
  /** Human-readable name. */
  readonly displayName: string;
  /** List models the provider exposes (may be cached). */
  listModels(): Promise<ModelInfo[]>;
  /** Stream a completion. Implementations MUST honor request.abortSignal. */
  stream(request: ProviderRequest): AsyncIterable<StreamEvent>;
}

export interface ProviderFactory {
  readonly id: string;
  /** Try to construct a provider from env / config. Returns null if unconfigured. */
  fromEnv(env: NodeJS.ProcessEnv): Provider | null;
  /** Construct from an explicit config blob (used by `cmux101 auth`). */
  fromConfig(config: Record<string, unknown>): Provider;
}

// ----------------------------------------------------------------------------
// Tools
// ----------------------------------------------------------------------------

export interface Tool<I = unknown, O = unknown> {
  /** Stable name shown to the model. snake_case. */
  name: string;
  /** Description shown to the model. Keep crisp; this counts as context. */
  description: string;
  /** zod schema for input validation + JSON Schema generation. */
  inputSchema: ZodTypeAny;
  /**
   * Run the tool. If the tool wants to stream intermediate output (e.g. shell
   * output), it can yield ToolEvents instead of returning a single ToolResult.
   */
  run(input: I, ctx: ToolContext): Promise<ToolResult<O>> | AsyncIterable<ToolEvent<O>>;
  /** Optional permission check that runs BEFORE the runner asks the user. */
  defaultPermission?: PermissionLevel;
  /** Optional: this tool only loads when this predicate returns true. */
  available?: () => Promise<boolean>;
}

export type ToolEvent<O = unknown> =
  | { kind: "log"; text: string }
  | { kind: "output_delta"; text: string }
  | { kind: "result"; result: ToolResult<O> };

export interface ToolResult<O = unknown> {
  /** Human-readable string content the model sees as tool_result. */
  content: string | Array<TextBlock | ImageBlock>;
  /** Set when the tool failed; the runner marks the tool_result as is_error. */
  isError?: boolean;
  /** Structured output. Optional. Not all tools have this. */
  data?: O;
}

export interface ToolContext {
  session: SessionHandle;
  permissions: Permissions;
  abortSignal: AbortSignal;
  cwd: string;
  /** Spawn a subagent. Provided here to avoid circular imports. */
  spawnSubagent: SubagentDispatcher;
  /** Look up other tools (for tool composition). */
  toolRegistry: ToolRegistry;
  /** Hooks fire-event helper. */
  emitHook: (event: HookEvent) => Promise<HookResponse>;
  /** Logger for tool output that's not part of the model-visible result. */
  log: (level: "debug" | "info" | "warn" | "error", text: string) => void;
}

export interface ToolRegistry {
  get(name: string): Tool | undefined;
  list(): Tool[];
  /** JSON Schema list to pass to the provider. */
  toSchemas(filter?: (t: Tool) => boolean): ToolSchema[];
}

// ----------------------------------------------------------------------------
// Permissions
// ----------------------------------------------------------------------------

export type PermissionLevel =
  | "allow" // run without asking
  | "ask" // prompt the user
  | "deny"; // refuse and return is_error

export interface Permissions {
  /** Resolve the effective level for a (toolName, input) pair. */
  resolve(toolName: string, input: unknown): PermissionLevel;
  /** Persist a "yes always" / "no always" decision for this session. */
  remember(toolName: string, level: PermissionLevel, scope?: "session" | "project"): void;
  /** Returns a narrowed Permissions object for a subagent. */
  narrow(allowedTools: string[]): Permissions;
}

// ----------------------------------------------------------------------------
// Sessions
// ----------------------------------------------------------------------------

export interface SessionMeta {
  id: string;
  cwd: string;
  startedAt: string; // ISO8601
  providerId: string;
  model: string;
  system?: string;
}

/** What tools/runner see. Sessions on disk store more (transcript, snapshots). */
export interface SessionHandle {
  readonly meta: SessionMeta;
  readonly messages: ReadonlyArray<Message>;
  /** Append a new message (assistant turns, tool results, user messages). */
  append(message: Message): Promise<void>;
  /** Record an arbitrary event (telemetry, hook firing, etc). */
  recordEvent(event: { kind: string; data: unknown }): Promise<void>;
}

// ----------------------------------------------------------------------------
// Subagents
// ----------------------------------------------------------------------------

export interface SubagentRequest {
  /** Short label used in UI ("Reviewing PR"). */
  label: string;
  /** Prompt the subagent receives as its user message. */
  prompt: string;
  /** Optional override of the system prompt. */
  system?: string;
  /** Whitelist of tool names this subagent can use. */
  tools?: string[];
  /** Optional model override. */
  model?: string;
  /** Worktree isolation? "worktree" => `git worktree add` into a tmp dir. */
  isolation?: "none" | "worktree";
}

export interface SubagentResult {
  /** Final assistant text content joined. */
  text: string;
  /** Total tokens used. */
  usage: { inputTokens: number; outputTokens: number };
  /** Path to the transcript file for inspection. */
  transcriptPath: string;
  /** True if the subagent ran to completion; false if aborted/errored. */
  ok: boolean;
}

export type SubagentDispatcher = (req: SubagentRequest) => Promise<SubagentResult>;

// ----------------------------------------------------------------------------
// Hooks
// ----------------------------------------------------------------------------

export type HookEventName =
  | "session.start"
  | "session.end"
  | "user.message"
  | "assistant.message"
  | "tool.pre"
  | "tool.post"
  | "permission.ask";

export interface HookEvent {
  event: HookEventName;
  sessionId: string;
  data: unknown;
}

export interface HookResponse {
  /** "block" cancels the action; "transform" replaces the data; "pass" continues. */
  action: "pass" | "block" | "transform";
  data?: unknown;
  message?: string;
}

export interface HookConfig {
  event: HookEventName;
  command: string; // shell command
  matcher?: string; // optional regex against tool name / content
}

// ----------------------------------------------------------------------------
// Skills (slash commands)
// ----------------------------------------------------------------------------

export interface Skill {
  name: string;
  description: string;
  /** Body is a prompt template with {{args}} substitution. */
  body: string;
  /** Optional shell-script form: when present, executed and stdout is the prompt. */
  shell?: string;
  /** Optional list of tool names this skill auto-allows. */
  allowedTools?: string[];
}

// ----------------------------------------------------------------------------
// Configuration
// ----------------------------------------------------------------------------

export interface Config {
  defaultProvider: string;
  defaultModel: string;
  providers: Record<string, Record<string, unknown>>;
  hooks?: HookConfig[];
  mcp?: McpServerConfig[];
  permissions?: {
    allow?: string[];
    ask?: string[];
    deny?: string[];
  };
}

export interface McpServerConfig {
  name: string;
  /** stdio: command + args. http: url. */
  transport: "stdio" | "sse" | "http";
  command?: string;
  args?: string[];
  url?: string;
  env?: Record<string, string>;
}
