// cmux share protocol v1 — see PROTOCOL.md for the narrative spec.
// These types are the single source of truth for the DO and the web viewer;
// the Swift host mirrors them in ShareProtocol.swift.

export const PROTO_VERSION = 1;

export type Role = "editor" | "viewer";

export interface PaneRef {
  /** Workspace id as the host reports it, e.g. "workspace:3". */
  ws: string;
  /** Surface id within the workspace, e.g. "surface:7". */
  pane: string;
}

export interface CursorPos extends PaneRef {
  /** Normalized [0,1] within the pane. */
  x: number;
  y: number;
}

export interface Participant {
  /** Stack user id. */
  user: string;
  email: string;
  role: Role;
  /** Index into the shared color palette; host is always 0. */
  color: number;
  /** Workspace this participant is currently viewing, if any. */
  focusWs: string | null;
  connected: boolean;
  isHost: boolean;
}

export interface ChatMessage {
  id: string;
  user: string;
  text: string;
  /** Cursor-bubble anchor; messages typed in the panel have none. */
  bubble?: CursorPos;
  ts: number;
}

/** One entry in the host's shared-workspace declaration. */
export interface SharedWorkspace {
  id: string;
  title: string;
}

/** Pane-tree snapshot for one workspace, mirroring the host's split layout. */
export type LayoutNode =
  | {
      kind: "split";
      axis: "h" | "v";
      /** Fraction of the axis given to `a`, in (0,1). */
      ratio: number;
      a: LayoutNode;
      b: LayoutNode;
    }
  | {
      kind: "pane";
      pane: string;
      /** "agent" is an agent-chat session pane (composer co-editing target). */
      content: "terminal" | "browser" | "agent" | "other";
      /** Terminal geometry so the viewer can size its grid canvas. */
      cols?: number;
      rows?: number;
      title?: string;
    };

export interface WorkspaceLayout {
  ws: string;
  tree: LayoutNode | null;
}

// ---------------------------------------------------------------------------
// Guest -> DO

/** One text edit against a compose field at a specific revision. */
export interface ComposeOp {
  /** Codepoint position the edit applies at. */
  p: number;
  /** Number of codepoints to delete at `p`. */
  d?: number;
  /** Text to insert at `p` (after the delete). */
  i?: string;
}

export interface ComposeCaret {
  user: string;
  start: number;
  end: number;
}

export type GuestMessage =
  | { t: "hello"; proto: number }
  | { t: "cursor"; pos: CursorPos | null }
  | { t: "chat"; text: string; bubble?: CursorPos }
  | { t: "input"; ws: string; pane: string; data: string }
  | { t: "sub"; ws: string; pane: string }
  | { t: "unsub"; ws: string; pane: string }
  | { t: "focus"; ws: string | null }
  | { t: "follow"; user: string | null }
  /**
   * Multiplayer textbox (slice 2): edits against the composer of pane
   * `field`, based on host revision `rev`. The host is the single serializer
   * (rebases stale ops) and answers with `compose-state`. Editor role only.
   */
  | { t: "compose"; field: string; rev: number; ops: ComposeOp[]; caret?: { start: number; end: number } }
  /**
   * Interactive browser panes (slice 3): pointer/keyboard events forwarded
   * into the host's webview. Pane-relative normalized coords. Editor role
   * only; the host re-validates against the shared-surface set.
   */
  | {
      t: "pointer";
      ws: string;
      pane: string;
      action: "move" | "down" | "up" | "wheel";
      x: number;
      y: number;
      button?: number;
      dx?: number;
      dy?: number;
    }
  | {
      t: "webkey";
      ws: string;
      pane: string;
      key: string;
      code: string;
      down: boolean;
      alt?: boolean;
      ctrl?: boolean;
      meta?: boolean;
      shift?: boolean;
    };

// ---------------------------------------------------------------------------
// Host -> DO

export type HostMessage =
  | {
      t: "hello";
      proto: number;
      shared: SharedWorkspace[];
      layouts: WorkspaceLayout[];
    }
  | { t: "layout"; layout: WorkspaceLayout }
  | { t: "shared"; shared: SharedWorkspace[] }
  | { t: "approve"; user: string; role: Role }
  | { t: "deny"; user: string }
  | { t: "kick"; user: string }
  | { t: "role"; user: string; role: Role }
  | { t: "cursor"; pos: CursorPos | null }
  | { t: "chat"; text: string; bubble?: CursorPos }
  /** Which shared workspace the host is viewing (drives follow-the-host). */
  | { t: "focus"; ws: string | null }
  /** Authoritative composer state after applying (rebased) ops. */
  | { t: "compose-state"; field: string; rev: number; text: string; carets: ComposeCaret[] }
  | { t: "end" };

// ---------------------------------------------------------------------------
// DO -> clients

export interface SessionSnapshot {
  t: "session-state";
  proto: number;
  shared: SharedWorkspace[];
  layouts: WorkspaceLayout[];
  participants: Participant[];
  chat: ChatMessage[];
  you: { user: string; role: Role; color: number; isHost: boolean };
}

export type ServerMessage =
  | SessionSnapshot
  | { t: "access-pending" }
  | { t: "access-denied" }
  | { t: "access-request"; user: string; email: string }
  | { t: "presence"; participants: Participant[] }
  | { t: "layout"; layout: WorkspaceLayout }
  | { t: "shared"; shared: SharedWorkspace[] }
  | { t: "cursor"; user: string; pos: CursorPos | null }
  | { t: "chat"; msg: ChatMessage }
  | { t: "role-changed"; role: Role }
  | { t: "kicked" }
  /**
   * The DO was rebuilt after hibernation/eviction and lost volatile state.
   * Guests re-send `focus` + `sub`s + cursor; the host re-sends `hello`
   * (shared set + layouts) and full grid frames for subscribed panes.
   */
  | { t: "resync" }
  | {
      t: "session-ended";
      reason: "host-stopped" | "host-gone" | "expired";
    }
  | { t: "compose-state"; field: string; rev: number; text: string; carets: ComposeCaret[] }
  // Relayed to the host only:
  | { t: "guest-input"; user: string; ws: string; pane: string; data: string }
  | {
      t: "guest-compose";
      user: string;
      field: string;
      rev: number;
      ops: ComposeOp[];
      caret?: { start: number; end: number };
    }
  | {
      t: "guest-pointer";
      user: string;
      ws: string;
      pane: string;
      action: "move" | "down" | "up" | "wheel";
      x: number;
      y: number;
      button?: number;
      dx?: number;
      dy?: number;
    }
  | {
      t: "guest-webkey";
      user: string;
      ws: string;
      pane: string;
      key: string;
      code: string;
      down: boolean;
      alt?: boolean;
      ctrl?: boolean;
      meta?: boolean;
      shift?: boolean;
    }
  | { t: "guest-sub"; ws: string; pane: string; count: number }
  | { t: "error"; code: string; message: string };

// ---------------------------------------------------------------------------
// Binary frames: [kindTag u8][wsLen u8][ws utf8][paneLen u8][pane utf8][payload]

export const BINARY_KIND_GRID = 0x01;
/**
 * Pixel/video frame for non-terminal panes (slice 2). Payload:
 * [codec u8][flags u8][data]. codec 1 = H.264 Annex B (flags bit0 =
 * keyframe; parameter sets inline on keyframes so WebCodecs decodes without
 * out-of-band description), codec 2 = still image (JPEG or WebP; the viewer
 * sniffs, flags unused).
 */
export const BINARY_KIND_PIXEL = 0x02;
export const PIXEL_CODEC_H264_ANNEXB = 1;
export const PIXEL_CODEC_STILL = 2;
export const PIXEL_FLAG_KEYFRAME = 0x01;

export interface BinaryHeader {
  kind: number;
  ws: string;
  pane: string;
  /** Byte offset where the payload starts. */
  payloadOffset: number;
}

export function encodeBinaryHeader(
  kind: number,
  ws: string,
  pane: string,
  payload: Uint8Array,
): Uint8Array {
  const enc = new TextEncoder();
  const wsB = enc.encode(ws);
  const paneB = enc.encode(pane);
  if (wsB.length > 255 || paneB.length > 255) {
    throw new Error("ws/pane id too long for binary header");
  }
  const out = new Uint8Array(3 + wsB.length + paneB.length + payload.length);
  let o = 0;
  out[o++] = kind;
  out[o++] = wsB.length;
  out.set(wsB, o);
  o += wsB.length;
  out[o++] = paneB.length;
  out.set(paneB, o);
  o += paneB.length;
  out.set(payload, o);
  return out;
}

export function decodeBinaryHeader(buf: Uint8Array): BinaryHeader | null {
  if (buf.length < 3) return null;
  const kind = buf[0] ?? 0;
  const wsLen = buf[1] ?? 0;
  const wsStart = 2;
  const paneLenOffset = wsStart + wsLen;
  if (paneLenOffset + 1 > buf.length) return null;
  const paneLen = buf[paneLenOffset] ?? 0;
  const paneStart = paneLenOffset + 1;
  const payloadOffset = paneStart + paneLen;
  if (payloadOffset > buf.length) return null;
  const dec = new TextDecoder();
  const ws = dec.decode(buf.subarray(wsStart, wsStart + wsLen));
  const pane = dec.decode(buf.subarray(paneStart, paneStart + paneLen));
  return { kind, ws, pane, payloadOffset };
}
