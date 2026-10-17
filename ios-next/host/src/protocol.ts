// TypeScript models for PROTOCOL.md §2-§4. Keep in sync with CNCore.

export const PROTOCOL_VERSION = 1;

export type ErrorCode = "bad_request" | "not_found" | "unauthorized" | "unavailable" | "internal" | "unsupported";

export type ControlMessage =
  | { t: "req"; id: number; m: string; p?: unknown }
  | { t: "res"; id: number; ok: true; r?: unknown }
  | { t: "res"; id: number; ok: false; e: { code: ErrorCode | string; message: string } }
  | { t: "evt"; topic: string; p?: unknown };

export const FrameKind = {
  termOutput: 1,
  termInput: 2,
  browserFrame: 3,
  fileChunk: 4,
} as const;
export type FrameKind = (typeof FrameKind)[keyof typeof FrameKind];

// --- conversations ---
export interface Participant {
  id: string;
  name: string;
}
export interface Message {
  id: string;
  conversationId: string;
  clientId?: string;
  sender: { id: string; name: string; isMe: boolean };
  text: string;
  sentAt: number;
  status: "sending" | "sent" | "delivered" | "read" | "failed";
  replyTo?: string;
}
export interface Conversation {
  id: string;
  kind: "chief" | "agent" | "group";
  title: string;
  subtitle?: string;
  avatar: { initials: string; tint: string };
  pinned: boolean;
  muted: boolean;
  unread: number;
  lastMessage?: Message;
  updatedAt: number;
  participants: Participant[];
}

// --- agents ---
export type SessionStatus = "idle" | "running" | "waiting" | "error" | "closed";
export interface AgentSession {
  id: string;
  title: string;
  harness: string;
  model?: string;
  mode?: string;
  cwd: string;
  status: SessionStatus;
  createdAt: number;
  updatedAt: number;
  unread: number;
  preview?: string;
}
export interface Harness {
  id: string;
  name: string;
  available: boolean;
  models: { id: string; name: string }[];
  modes: { id: string; name: string }[];
}
export type ToolKindP = "read" | "edit" | "execute" | "search" | "fetch" | "delete" | "think" | "other";
export type TranscriptItem =
  | { id: string; kind: "user"; text: string; attachments: { name: string; mimeType: string }[] }
  | { id: string; kind: "assistant"; text: string; streaming: boolean }
  | { id: string; kind: "thought"; text: string; streaming: boolean; durationMs?: number }
  | {
      id: string;
      kind: "tool";
      toolKind: ToolKindP;
      title: string;
      status: "pending" | "running" | "completed" | "failed";
      input?: string;
      output?: string;
      locations: { path: string; line?: number }[];
      diff?: { path: string; oldText?: string; newText: string }[];
    }
  | {
      id: string;
      kind: "plan";
      entries: { content: string; status: "pending" | "in_progress" | "completed"; priority: string }[];
    }
  | {
      id: string;
      kind: "permission";
      toolCallId: string;
      title: string;
      options: { id: string; name: string; kind: "allow_once" | "allow_always" | "reject_once" | "reject_always" }[];
      /** The chosen option id, or "cancelled" (cancel, turn end, agent exit, host restart). */
      resolved?: string;
    }
  | { id: string; kind: "notice"; level: "info" | "warning" | "error"; text: string }
  | { id: string; kind: "turnEnd"; stopReason: string; durationMs: number };

// --- terminals ---
export interface Terminal {
  id: string;
  title: string;
  cwd: string;
  cols: number;
  rows: number;
  running: boolean;
  createdAt: number;
}

// --- browser ---
export interface Tab {
  id: string;
  url: string;
  title: string;
  loading: boolean;
  progress: number;
  canGoBack: boolean;
  canGoForward: boolean;
  faviconUrl?: string;
  active: boolean;
  /** Mac tabs only (browser.mac.v1): false until the Mac app maps the tab to a target. */
  streamable?: boolean;
  reason?: string;
  /** Mac tabs only: the layout.v1 pane and tab of this browser tab. */
  paneId?: string;
  layoutTabId?: string;
}

// --- layout (PROTOCOL.md §4 layout) ---
export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}
export type LayoutTabKind = "terminal" | "browser" | "agent" | "conversation" | "other";
export interface LayoutTab {
  id: string;
  kind: LayoutTabKind;
  title: string;
  /** terminalId (terminal), browser tab id (browser), agent sessionId (agent). */
  refId?: string;
  /** False when the phone cannot open a live view of this tab (show a placeholder). */
  streamable: boolean;
  url?: string;
  focused: boolean;
  /** Browser tabs: shown on the Mac right now (a hidden tab sends no frames). */
  visibleOnMac?: boolean;
  /** Why the tab is not streamable. */
  reason?: string;
}
export interface LayoutPane {
  id: string;
  /** Normalized rect within its workspace, 0..1. */
  rect: Rect;
  tabs: LayoutTab[];
  focusedTabId?: string;
  active: boolean;
}
export interface LayoutWorkspace {
  id: string;
  title: string;
  color?: string;
  active: boolean;
  activePaneId?: string;
  panes: LayoutPane[];
}
export interface Layout {
  workspaces: LayoutWorkspace[];
}
