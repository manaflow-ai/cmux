// Client mirror of the share wire protocol. Source of truth:
// workers/share/src/protocol.ts (+ PROTOCOL.md). Grid frame shapes mirror the
// Swift DTO `MobileTerminalRenderGridFrame` (cmux.render-grid.v1, snake_case
// JSON) in Packages/Shared/CMUXMobileCore.

export const PROTO_VERSION = 1;

export type Role = "editor" | "viewer";

export interface CursorPos {
  ws: string;
  pane: string;
  x: number;
  y: number;
}

export interface Participant {
  user: string;
  email: string;
  role: Role;
  color: number;
  focusWs: string | null;
  connected: boolean;
  isHost: boolean;
}

export interface ChatMessage {
  id: string;
  user: string;
  text: string;
  bubble?: CursorPos;
  ts: number;
}

export interface SharedWorkspace {
  id: string;
  title: string;
}

export type LayoutNode =
  | { kind: "split"; axis: "h" | "v"; ratio: number; a: LayoutNode; b: LayoutNode }
  | {
      kind: "pane";
      pane: string;
      content: "terminal" | "browser" | "other";
      cols?: number;
      rows?: number;
      title?: string;
    };

export interface WorkspaceLayout {
  ws: string;
  tree: LayoutNode | null;
}

export type GuestMessage =
  | { t: "hello"; proto: number }
  | { t: "cursor"; pos: CursorPos | null }
  | { t: "chat"; text: string; bubble?: CursorPos }
  | { t: "input"; ws: string; pane: string; data: string }
  | { t: "sub"; ws: string; pane: string }
  | { t: "unsub"; ws: string; pane: string }
  | { t: "focus"; ws: string | null }
  | { t: "follow"; user: string | null };

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
  | { t: "resync" }
  | { t: "session-ended"; reason: "host-stopped" | "host-gone" | "expired" }
  | { t: "error"; code: string; message: string };

export const BINARY_KIND_GRID = 0x01;
export const BINARY_KIND_PIXEL = 0x02;

export interface BinaryFrame {
  kind: number;
  ws: string;
  pane: string;
  payload: Uint8Array;
}

export function decodeBinaryFrame(buf: Uint8Array): BinaryFrame | null {
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
  return {
    kind,
    ws: dec.decode(buf.subarray(wsStart, wsStart + wsLen)),
    pane: dec.decode(buf.subarray(paneStart, paneStart + paneLen)),
    payload: buf.subarray(payloadOffset),
  };
}

// ---------------------------------------------------------------------------
// Render-grid frame (cmux.render-grid.v1), mirroring the Swift DTO's JSON.

export interface GridStyle {
  id: number;
  foreground?: string;
  background?: string;
  bold?: boolean;
  faint?: boolean;
  italic?: boolean;
  underline?: boolean;
  blink?: boolean;
  inverse?: boolean;
  invisible?: boolean;
  strikethrough?: boolean;
  overline?: boolean;
}

export interface GridRowSpan {
  row: number;
  column: number;
  style_id: number;
  text: string;
  cell_width?: number;
}

export interface GridCursor {
  row: number;
  column: number;
  visible?: boolean;
  style?: "block" | "bar" | "underline" | "block_hollow";
  blinking?: boolean;
}

export interface GridTheme {
  background: string;
  foreground: string;
  cursor: string;
  palette?: string[];
}

export interface RenderGridFrame {
  format: string;
  surface_id: string;
  state_seq: number;
  columns: number;
  rows: number;
  cursor?: GridCursor;
  full?: boolean;
  cleared_rows?: number[];
  styles?: GridStyle[];
  row_spans: GridRowSpan[];
  terminal_foreground?: string;
  terminal_background?: string;
  terminal_cursor_color?: string;
  terminal_theme?: GridTheme;
}

export const RENDER_GRID_FORMAT = "cmux.render-grid.v1";
