// SPDX-License-Identifier: GPL-3.0-or-later
// cmux share protocol v1. See PROTOCOL.md for the narrative spec.

export const PROTO_VERSION = 1;

/** Wire and state bounds. Keep these in the protocol layer so the DO,
 * deterministic core, and tests enforce the same limits. */
/** Client-to-server JSON stays small so parsing untrusted input is cheap. */
export const MAX_CLIENT_JSON_FRAME_BYTES = 64 * 1024;
/** Compatibility alias for existing callers. */
export const MAX_JSON_FRAME_BYTES = MAX_CLIENT_JSON_FRAME_BYTES;
/** Server JSON at or above this UTF-8 size is an invariant violation. */
export const MAX_SERVER_JSON_FRAME_BYTES = 1024 * 1024;
/** Complete binary grid frame, including kind/id header. The bound is
 * exclusive: byteLength at or above 1 MiB is rejected. */
export const MAX_BINARY_FRAME_BYTES = 1024 * 1024;
export const MAX_SHARED_WORKSPACES = 1;
export const MAX_LAYOUT_PANES = 128;
export const MAX_LAYOUT_DEPTH = 16;
export const MAX_ID_BYTES = 256;
export const MAX_EMAIL_BYTES = 320;
export const MAX_TITLE_BYTES = 512;
export const MAX_CHAT_TEXT_BYTES = 4_000;
export const MAX_TERMINAL_INPUT_BYTES = 16 * 1024;
export const MAX_ACK_NONCE_BYTES = 64;

const encoder = new TextEncoder();

export function utf8ByteLength(value: string): number {
  return encoder.encode(value).byteLength;
}

function boundedString(value: unknown, maxBytes: number, allowEmpty = false): value is string {
  return (
    typeof value === "string" &&
    (allowEmpty || value.length > 0) &&
    value.length <= maxBytes &&
    utf8ByteLength(value) <= maxBytes
  );
}

/** IDs are opaque, but Unicode controls (especially NUL, used in subscription
 * keys) are never valid and would make logs/state ambiguous. */
export function isProtocolId(value: unknown): value is string {
  return (
    boundedString(value, MAX_ID_BYTES) &&
    !/\p{Cc}/u.test(value)
  );
}

export function isIdentityEmail(value: unknown): value is string {
  return boundedString(value, MAX_EMAIL_BYTES, true) && !/\p{Cc}/u.test(value);
}

export type Role = "editor" | "viewer";

export function isRole(value: unknown): value is Role {
  return value === "editor" || value === "viewer";
}

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

/** Pane-tree snapshot for one workspace, mirroring the host's split layout.
 * Non-terminal leaves remain visible placeholders in v1. */
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

export type GuestMessage =
  | { t: "hello"; proto: number }
  | { t: "cursor"; pos: CursorPos | null }
  | { t: "chat"; text: string; bubble?: CursorPos }
  | { t: "input"; ws: string; pane: string; data: string }
  | { t: "sub"; ws: string; pane: string }
  | { t: "unsub"; ws: string; pane: string }
  | { t: "focus"; ws: string | null };

/** Delivery acknowledgements are valid from either client role and are
 * consumed by the Durable Object before the session core sees the message. */
export interface AckMessage {
  t: "ack";
  nonce: string;
}

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
  /** Which shared workspace the host is viewing. */
  | { t: "focus"; ws: string | null }
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
  | { t: "ack-request"; nonce: string }
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
  // Relayed to the host only. The user always comes from the verified socket
  // attachment, never a caller-supplied JSON field.
  | { t: "guest-input"; user: string; ws: string; pane: string; data: string }
  | { t: "guest-sub"; ws: string; pane: string; count: number }
  | { t: "error"; code: string; message: string };

// ---------------------------------------------------------------------------
// Runtime JSON validation

type JsonRecord = Record<string, unknown>;

function record(value: unknown): JsonRecord | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as JsonRecord)
    : null;
}

/** ACK nonces are opaque, short UTF-8 strings. Unicode control characters are
 * excluded so a nonce is safe in logs and every supported client agrees on
 * the same wire bound. */
export function isAckNonce(value: unknown): value is string {
  return (
    boundedString(value, MAX_ACK_NONCE_BYTES) &&
    !/\p{Cc}/u.test(value)
  );
}

export function parseAckMessage(value: unknown): AckMessage | null {
  const obj = record(value);
  return obj &&
    Object.keys(obj).length === 2 &&
    Object.hasOwn(obj, "t") &&
    Object.hasOwn(obj, "nonce") &&
    obj.t === "ack" &&
    isAckNonce(obj.nonce)
    ? { t: "ack", nonce: obj.nonce }
    : null;
}

function finiteNormalized(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;
}

export function parseCursorPos(value: unknown): CursorPos | null {
  const obj = record(value);
  if (
    !obj ||
    !isProtocolId(obj.ws) ||
    !isProtocolId(obj.pane) ||
    !finiteNormalized(obj.x) ||
    !finiteNormalized(obj.y)
  ) {
    return null;
  }
  return { ws: obj.ws, pane: obj.pane, x: obj.x, y: obj.y };
}

export function isCursorPos(value: unknown): value is CursorPos {
  return parseCursorPos(value) !== null;
}

export function parseSharedWorkspaces(value: unknown): SharedWorkspace[] | null {
  if (!Array.isArray(value) || value.length > MAX_SHARED_WORKSPACES) return null;
  const ids = new Set<string>();
  const out: SharedWorkspace[] = [];
  for (const item of value) {
    const obj = record(item);
    if (
      !obj ||
      !isProtocolId(obj.id) ||
      !boundedString(obj.title, MAX_TITLE_BYTES, true) ||
      ids.has(obj.id)
    ) {
      return null;
    }
    ids.add(obj.id);
    out.push({ id: obj.id, title: obj.title });
  }
  return out;
}

function optionalDimension(value: unknown): number | undefined | null {
  if (value === undefined) return undefined;
  return Number.isSafeInteger(value) && (value as number) > 0 && (value as number) <= 10_000
    ? (value as number)
    : null;
}

export function parseWorkspaceLayout(value: unknown): WorkspaceLayout | null {
  const obj = record(value);
  if (!obj || !isProtocolId(obj.ws)) return null;
  if (obj.tree === null) return { ws: obj.ws, tree: null };

  let panes = 0;
  const paneIds = new Set<string>();

  const parseNode = (candidate: unknown, depth: number): LayoutNode | null => {
    if (depth > MAX_LAYOUT_DEPTH) return null;
    const node = record(candidate);
    if (!node) return null;

    if (node.kind === "split") {
      if (
        (node.axis !== "h" && node.axis !== "v") ||
        typeof node.ratio !== "number" ||
        !Number.isFinite(node.ratio) ||
        node.ratio <= 0 ||
        node.ratio >= 1
      ) {
        return null;
      }
      const a = parseNode(node.a, depth + 1);
      const b = parseNode(node.b, depth + 1);
      if (!a || !b) return null;
      return { kind: "split", axis: node.axis, ratio: node.ratio, a, b };
    }

    if (
      node.kind !== "pane" ||
      !isProtocolId(node.pane) ||
      paneIds.has(node.pane) ||
      (node.content !== "terminal" &&
        node.content !== "browser" &&
        node.content !== "agent" &&
        node.content !== "other")
    ) {
      return null;
    }
    panes += 1;
    if (panes > MAX_LAYOUT_PANES) return null;
    paneIds.add(node.pane);
    const cols = optionalDimension(node.cols);
    const rows = optionalDimension(node.rows);
    if (cols === null || rows === null) return null;
    if (node.title !== undefined && !boundedString(node.title, MAX_TITLE_BYTES, true)) return null;
    return {
      kind: "pane",
      pane: node.pane,
      content: node.content,
      ...(cols === undefined ? {} : { cols }),
      ...(rows === undefined ? {} : { rows }),
      ...(node.title === undefined ? {} : { title: node.title }),
    };
  };

  const tree = parseNode(obj.tree, 1);
  return tree ? { ws: obj.ws, tree } : null;
}

export function parseWorkspaceLayouts(value: unknown): WorkspaceLayout[] | null {
  if (!Array.isArray(value) || value.length > MAX_SHARED_WORKSPACES) return null;
  const ids = new Set<string>();
  const out: WorkspaceLayout[] = [];
  for (const item of value) {
    const layout = parseWorkspaceLayout(item);
    if (!layout || ids.has(layout.ws)) return null;
    ids.add(layout.ws);
    out.push(layout);
  }
  return out;
}

/** Iterative lookup avoids trusting layout depth even when called on restored
 * state or directly from a unit test. */
export function isCurrentTerminalPane(
  layouts: readonly WorkspaceLayout[],
  ws: string,
  pane: string,
): boolean {
  const tree = layouts.find((layout) => layout.ws === ws)?.tree;
  if (!tree) return false;
  const stack: LayoutNode[] = [tree];
  let visited = 0;
  while (stack.length > 0 && visited <= MAX_LAYOUT_PANES * 2) {
    const node = stack.pop();
    if (!node) continue;
    visited += 1;
    if (node.kind === "pane") {
      if (node.pane === pane) return node.content === "terminal";
    } else {
      stack.push(node.a, node.b);
    }
  }
  return false;
}

function parseBubble(value: unknown): CursorPos | undefined | null {
  if (value === undefined) return undefined;
  return parseCursorPos(value);
}

export function parseGuestMessage(value: unknown): GuestMessage | null {
  const obj = record(value);
  if (!obj || typeof obj.t !== "string") return null;
  switch (obj.t) {
    case "hello":
      return Number.isSafeInteger(obj.proto) ? { t: "hello", proto: obj.proto as number } : null;
    case "cursor": {
      if (obj.pos === null) return { t: "cursor", pos: null };
      const pos = parseCursorPos(obj.pos);
      return pos ? { t: "cursor", pos } : null;
    }
    case "chat": {
      if (!boundedString(obj.text, MAX_CHAT_TEXT_BYTES, true)) return null;
      const bubble = parseBubble(obj.bubble);
      if (bubble === null) return null;
      return {
        t: "chat",
        text: obj.text,
        ...(bubble === undefined ? {} : { bubble }),
      };
    }
    case "input":
      return isProtocolId(obj.ws) &&
        isProtocolId(obj.pane) &&
        boundedString(obj.data, MAX_TERMINAL_INPUT_BYTES)
        ? { t: "input", ws: obj.ws, pane: obj.pane, data: obj.data }
        : null;
    case "sub":
    case "unsub":
      return isProtocolId(obj.ws) && isProtocolId(obj.pane)
        ? { t: obj.t, ws: obj.ws, pane: obj.pane }
        : null;
    case "focus":
      return obj.ws === null || isProtocolId(obj.ws)
        ? { t: "focus", ws: obj.ws as string | null }
        : null;
    default:
      // Composer, follow, browser control, and other future verbs are not v1.
      return null;
  }
}

export function parseHostMessage(value: unknown): HostMessage | null {
  const obj = record(value);
  if (!obj || typeof obj.t !== "string") return null;
  switch (obj.t) {
    case "hello": {
      if (!Number.isSafeInteger(obj.proto)) return null;
      const shared = parseSharedWorkspaces(obj.shared);
      const layouts = parseWorkspaceLayouts(obj.layouts);
      if (!shared || !layouts) return null;
      const sharedIds = new Set(shared.map((workspace) => workspace.id));
      if (layouts.some((layout) => !sharedIds.has(layout.ws))) return null;
      return { t: "hello", proto: obj.proto as number, shared, layouts };
    }
    case "layout": {
      const layout = parseWorkspaceLayout(obj.layout);
      return layout ? { t: "layout", layout } : null;
    }
    case "shared": {
      const shared = parseSharedWorkspaces(obj.shared);
      return shared ? { t: "shared", shared } : null;
    }
    case "approve":
    case "role":
      return isProtocolId(obj.user) && isRole(obj.role)
        ? { t: obj.t, user: obj.user, role: obj.role }
        : null;
    case "deny":
    case "kick":
      return isProtocolId(obj.user) ? { t: obj.t, user: obj.user } : null;
    case "cursor": {
      if (obj.pos === null) return { t: "cursor", pos: null };
      const pos = parseCursorPos(obj.pos);
      return pos ? { t: "cursor", pos } : null;
    }
    case "chat": {
      if (!boundedString(obj.text, MAX_CHAT_TEXT_BYTES, true)) return null;
      const bubble = parseBubble(obj.bubble);
      if (bubble === null) return null;
      return {
        t: "chat",
        text: obj.text,
        ...(bubble === undefined ? {} : { bubble }),
      };
    }
    case "focus":
      return obj.ws === null || isProtocolId(obj.ws)
        ? { t: "focus", ws: obj.ws as string | null }
        : null;
    case "end":
      return { t: "end" };
    default:
      return null;
  }
}

export function decodeClientJson(text: string): unknown | null {
  if (text.length >= MAX_JSON_FRAME_BYTES || utf8ByteLength(text) >= MAX_JSON_FRAME_BYTES) {
    return null;
  }
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return null;
  }
}

export function decodeGuestMessage(text: string): GuestMessage | null {
  const value = decodeClientJson(text);
  return value === null ? null : parseGuestMessage(value);
}

export function decodeHostMessage(text: string): HostMessage | null {
  const value = decodeClientJson(text);
  return value === null ? null : parseHostMessage(value);
}

// ---------------------------------------------------------------------------
// Binary grid frames: [kindTag u8][wsLen u8][ws utf8][paneLen u8][pane utf8][payload]

export const BINARY_KIND_GRID = 0x01;

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
  if (!Number.isInteger(kind) || kind < 0 || kind > 255 || !isProtocolId(ws) || !isProtocolId(pane)) {
    throw new Error("invalid binary frame header");
  }
  const wsB = encoder.encode(ws);
  const paneB = encoder.encode(pane);
  if (wsB.length > 255 || paneB.length > 255) {
    throw new Error("ws/pane id too long for binary header");
  }
  const length = 3 + wsB.length + paneB.length + payload.length;
  if (length >= MAX_BINARY_FRAME_BYTES) throw new Error("binary frame too large");
  const out = new Uint8Array(length);
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
  if (buf.length < 3 || buf.length >= MAX_BINARY_FRAME_BYTES) return null;
  const kind = buf[0] ?? 0;
  const wsLen = buf[1] ?? 0;
  const wsStart = 2;
  const paneLenOffset = wsStart + wsLen;
  if (paneLenOffset + 1 > buf.length) return null;
  const paneLen = buf[paneLenOffset] ?? 0;
  const paneStart = paneLenOffset + 1;
  const payloadOffset = paneStart + paneLen;
  if (payloadOffset > buf.length) return null;
  try {
    const dec = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });
    const ws = dec.decode(buf.subarray(wsStart, wsStart + wsLen));
    const pane = dec.decode(buf.subarray(paneStart, paneStart + paneLen));
    return isProtocolId(ws) && isProtocolId(pane) ? { kind, ws, pane, payloadOffset } : null;
  } catch {
    return null;
  }
}
