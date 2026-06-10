// Canonical agent conversation protocol (P1).
//
// Source of truth for the normalized agent-output layer. The Go producer in
// daemon/remote/agentconv mirrors these shapes (protocol.go); keep both in
// sync with the golden fixtures under daemon/remote/agentconv/testdata.
// Wire format is JSON; all fields use snake_case on the wire.
//
// Design notes (see docs/agent-conversation-protocol.md):
// - Everything in a conversation is an "item" with a lifecycle
//   (started -> updated -> completed). Messages, reasoning, and tool calls
//   are all items; tool results fold into their tool item by tool_use_id.
// - Transcript replay cannot observe token-level streaming, so there is no
//   content.delta event yet; that name stays reserved.
// - `turn.started`/`turn.completed` and `request.opened`/`request.resolved`
//   are produced only by the live hook ingest source (see the "Hook ingest"
//   section of the doc). Content optionality: an item first emitted from a
//   hook frame is sparse (tool name + short title, no input/output); the full
//   content arrives as `item.updated` when the transcript line for the same
//   tool_use_id lands.

export type AgentProviderId = "claude" | "codex" | (string & {});

export interface AgentSessionRef {
  provider: AgentProviderId;
  /** Claude: session uuid. Codex: rollout id (filename stem after `rollout-`). */
  session_id: string;
  /** Absolute path of the transcript on the host that parsed it. */
  transcript_path: string;
  cwd?: string;
  title?: string;
  /** ISO 8601. */
  updated_at?: string;
}

export type ItemType =
  | "user_message"
  | "assistant_message"
  | "reasoning"
  | "plan"
  | "command_execution"
  | "file_change"
  | "mcp_tool_call"
  | "dynamic_tool_call"
  | "web_search"
  | "context_compaction"
  | "interrupted"
  | "error"
  | "unknown";

export type ItemStatus = "in_progress" | "completed" | "failed" | "declined";

export interface ToolOutput {
  text?: string;
  is_error?: boolean;
  /** Image payloads are referenced by id, never inlined. Fetch is a later phase. */
  image_ids?: string[];
}

export interface ConversationItem {
  /** Stable within a session: provider line uuid, tool_use_id, or synthesized. */
  id: string;
  type: ItemType;
  status: ItemStatus;
  /** Message/reasoning/plan body (markdown). */
  text?: string;
  /** Tool-shaped items only. */
  tool_name?: string;
  tool_use_id?: string;
  /** Raw provider-shaped tool input. */
  input?: unknown;
  output?: ToolOutput;
  /** Short one-line label (command line, file path, search query). */
  title?: string;
  /** ISO 8601. */
  created_at?: string;
}

/** Classifies what a pending `request.opened` is waiting on. */
export type RequestType = "tool_approval" | "user_input" | "unknown";

export type AgentEvent =
  | {
      type: "snapshot";
      seq: number;
      session: AgentSessionRef;
      items: ConversationItem[];
    }
  | { type: "item.started"; seq: number; item: ConversationItem }
  | { type: "item.updated"; seq: number; item: ConversationItem }
  | { type: "item.completed"; seq: number; item: ConversationItem }
  | { type: "session.meta"; seq: number; session: AgentSessionRef }
  | { type: "error"; seq: number; message: string; recoverable: boolean }
  // Live hook-sourced events. Turns bracket agent activity between a user
  // prompt and the agent stopping; requests are open while the agent waits on
  // the user (permission prompt, input request).
  | { type: "turn.started"; seq: number; turn_id: string; prompt?: string }
  | { type: "turn.completed"; seq: number; turn_id: string }
  | {
      type: "request.opened";
      seq: number;
      request_id: string;
      request_type: RequestType;
      detail?: string;
    }
  // `decision` is present when the resolution outcome is known (for example
  // "approved"/"denied"); absent when the request was implicitly cleared by
  // the agent making progress.
  | { type: "request.resolved"; seq: number; request_id: string; decision?: string };

// ---------------------------------------------------------------------------
// RPC surface exposed by cmuxd-remote (newline-delimited JSON, same envelope
// as the existing pty.*/session.* verbs: request {id, method, params},
// response {id, ok, result|error}, async frames {event, ...}).
// ---------------------------------------------------------------------------

export interface AgentSessionsListParams {
  provider?: AgentProviderId;
  cwd?: string;
  limit?: number;
}
export interface AgentSessionsListResult {
  sessions: AgentSessionRef[];
}

export interface AgentSessionOpenParams {
  provider: AgentProviderId;
  /** Either session_id (+ cwd to disambiguate Claude project dirs) or transcript_path. */
  session_id?: string;
  cwd?: string;
  transcript_path?: string;
}
export interface AgentSessionOpenResult {
  subscription_id: string;
  session: AgentSessionRef;
}

export interface AgentSessionCloseParams {
  subscription_id: string;
}

/** Async frame: { event: "agent.session.event", subscription_id, payload: AgentEvent } */
export interface AgentSessionEventFrame {
  event: "agent.session.event";
  subscription_id: string;
  payload: AgentEvent;
}

// ---------------------------------------------------------------------------
// WebKit bridge contract for the /agent-chat surface (macOS app <-> webview).
// JS -> Swift: window.webkit.messageHandlers.agentChat.postMessage(...) via
// callNative(method, params). Swift -> JS: window.cmuxAgentChatBridge.receive(msg).
// ---------------------------------------------------------------------------

export interface AgentChatInitResult {
  /** Session the panel was opened for, if the host resolved one. */
  session?: AgentSessionRef;
  daemon_status: "ready" | "unavailable";
  /** Human-readable detail when unavailable. */
  daemon_detail?: string;
}

export type AgentChatBridgeInbound =
  | { type: "agent.event"; event: AgentEvent }
  | { type: "daemon.status"; status: "ready" | "unavailable"; detail?: string };
