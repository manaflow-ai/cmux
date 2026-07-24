// Client mirror of the share wire protocol. Source of truth:
// workers/share/src/protocol.ts (+ PROTOCOL.md). Grid frame shapes mirror the
// Swift DTO `MobileTerminalRenderGridFrame` (cmux.render-grid.v1, snake_case
// JSON) in Packages/Shared/CMUXMobileCore.

export const PROTO_VERSION = 1;
/** Server JSON frames must stay strictly below this encoded UTF-8 size. */
export const MAX_SERVER_MESSAGE_BYTES = 1024 * 1024;
/** Complete binary frames must stay strictly below this byte size. */
export const MAX_BINARY_MESSAGE_BYTES = 1024 * 1024;
export const MAX_CHAT_HISTORY = 500;
export const MAX_CHAT_TEXT_CHARS = 4_000;
export const MAX_CHAT_TEXT_BYTES = 4_000;
export const MAX_ACK_NONCE_BYTES = 64;
/** Worker persistence permits 256 guest grants in addition to the host. */
export const MAX_GUEST_GRANTS = 256;
export const MAX_PARTICIPANTS = MAX_GUEST_GRANTS + 1;
export const MAX_CURSORS = 128;
export const MAX_SHARED_WORKSPACES = 1;
export const MAX_LAYOUT_PANES = 128;
export const MAX_LAYOUT_NODES = MAX_LAYOUT_PANES * 2 - 1;
export const MAX_LAYOUT_DEPTH = 16;
export const MAX_TERMINAL_PANES = 64;
export const MAX_TERMINAL_INPUT_BYTES = 16 * 1024;
const MAX_ID_CHARS = 256;
const MAX_ID_BYTES = 256;
const textEncoder = new TextEncoder();

export function utf8ByteLength(value: string): number {
  return textEncoder.encode(value).byteLength;
}

export function truncateUtf8(value: string, maxBytes: number): string {
  if (utf8ByteLength(value) <= maxBytes) return value;
  let result = "";
  let bytes = 0;
  for (const character of value) {
    const nextBytes = utf8ByteLength(character);
    if (bytes + nextBytes > maxBytes) break;
    result += character;
    bytes += nextBytes;
  }
  return result;
}

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
      content: "terminal" | "browser" | "agent" | "other";
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
  | { t: "ack"; nonce: string }
  | { t: "cursor"; pos: CursorPos | null }
  | { t: "chat"; text: string; bubble?: CursorPos }
  | { t: "input"; ws: string; pane: string; data: string }
  | { t: "sub"; ws: string; pane: string }
  | { t: "unsub"; ws: string; pane: string }
  | { t: "focus"; ws: string | null };

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
  | { t: "resync" }
  | { t: "session-ended"; reason: "host-stopped" | "host-gone" | "expired" }
  | { t: "error"; code: string; message: string };

export const BINARY_KIND_GRID = 0x01;

export interface BinaryFrame {
  kind: number;
  ws: string;
  pane: string;
  payload: Uint8Array;
}

export function decodeBinaryFrame(buf: Uint8Array): BinaryFrame | null {
  if (buf.length < 3 || buf.length >= MAX_BINARY_MESSAGE_BYTES) return null;
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
    const dec = new TextDecoder("utf-8", { fatal: true });
    const ws = dec.decode(buf.subarray(wsStart, wsStart + wsLen));
    const pane = dec.decode(buf.subarray(paneStart, paneStart + paneLen));
    if (!wireId(ws) || !wireId(pane)) return null;
    return {
      kind,
      ws,
      pane,
      payload: buf.subarray(payloadOffset),
    };
  } catch {
    return null;
  }
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

const MAX_GRID_COLUMNS = 1_000;
const MAX_GRID_ROWS = 500;
const MAX_GRID_STYLES = 4_096;
const MAX_GRID_PALETTE_COLORS = 256;
const MAX_GRID_SPANS = 20_000;
const MAX_GRID_SPAN_CHARS = 8_192;
const MAX_GRID_TOTAL_CHARS = 1_000_000;
const INVALID_LAYOUT = Symbol("invalid-layout");

type UnknownRecord = Record<string, unknown>;

function record(value: unknown): UnknownRecord | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as UnknownRecord)
    : null;
}

function boundedString(value: unknown, max: number): string | null {
  return typeof value === "string" && value.length <= max ? value : null;
}

function boundedUtf8String(value: unknown, maxBytes: number): string | null {
  return typeof value === "string" &&
    value.length <= maxBytes &&
    utf8ByteLength(value) <= maxBytes
    ? value
    : null;
}

export function wireId(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= MAX_ID_CHARS &&
    utf8ByteLength(value) <= MAX_ID_BYTES &&
    !/\p{Cc}/u.test(value)
  );
}

export function wireEmail(value: unknown): string | null {
  const email = boundedUtf8String(value, 320);
  return email !== null && !/\p{Cc}/u.test(email) ? email : null;
}

function integer(value: unknown, min: number, max: number): number | null {
  return Number.isSafeInteger(value) && Number(value) >= min && Number(value) <= max
    ? Number(value)
    : null;
}

function finite(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function role(value: unknown): Role | null {
  return value === "editor" || value === "viewer" ? value : null;
}

function ackNonce(value: unknown): string | null {
  return typeof value === "string" &&
    value.length > 0 &&
    value.length <= MAX_ACK_NONCE_BYTES &&
    utf8ByteLength(value) <= MAX_ACK_NONCE_BYTES &&
    !/\p{Cc}/u.test(value)
    ? value
    : null;
}

function cursorPos(value: unknown): CursorPos | null {
  const input = record(value);
  if (!input || !wireId(input.ws) || !wireId(input.pane)) return null;
  const x = finite(input.x);
  const y = finite(input.y);
  if (x === null || y === null || x < 0 || x > 1 || y < 0 || y > 1) return null;
  return {
    ws: input.ws,
    pane: input.pane,
    x,
    y,
  };
}

function participant(value: unknown): Participant | null {
  const input = record(value);
  if (!input || !wireId(input.user)) return null;
  const email = wireEmail(input.email);
  const participantRole = role(input.role);
  const color = integer(input.color, 0, 1_000_000);
  const focusWs =
    input.focusWs === null ? null : wireId(input.focusWs) ? input.focusWs : undefined;
  if (
    email === null ||
    participantRole === null ||
    color === null ||
    focusWs === undefined ||
    typeof input.connected !== "boolean" ||
    typeof input.isHost !== "boolean"
  ) {
    return null;
  }
  return {
    user: input.user,
    email,
    role: participantRole,
    color,
    focusWs,
    connected: input.connected,
    isHost: input.isHost,
  };
}

function chatMessage(value: unknown): ChatMessage | null {
  const input = record(value);
  if (!input || !wireId(input.id) || !wireId(input.user)) return null;
  const text = boundedUtf8String(input.text, MAX_CHAT_TEXT_BYTES);
  const ts = finite(input.ts);
  if (text === null || ts === null) return null;
  const bubble =
    input.bubble === undefined || input.bubble === null
      ? undefined
      : cursorPos(input.bubble);
  if (input.bubble !== undefined && input.bubble !== null && !bubble) return null;
  return {
    id: input.id,
    user: input.user,
    text,
    ts,
    ...(bubble ? { bubble } : {}),
  };
}

function sharedWorkspaces(value: unknown): SharedWorkspace[] | null {
  if (!Array.isArray(value) || value.length > MAX_SHARED_WORKSPACES) return null;
  const first = value[0];
  if (first === undefined) return [];
  const input = record(first);
  if (!input || !wireId(input.id)) return null;
  const title = boundedUtf8String(input.title, 512);
  if (title === null) return null;
  return [{ id: input.id, title }];
}

function layoutNode(
  value: unknown,
  depth: number,
  limits: { nodes: number; panes: number; paneIds: Set<string> },
): LayoutNode | typeof INVALID_LAYOUT {
  if (depth > MAX_LAYOUT_DEPTH || limits.nodes >= MAX_LAYOUT_NODES) return INVALID_LAYOUT;
  const input = record(value);
  if (!input) return INVALID_LAYOUT;
  limits.nodes += 1;
  if (input.kind === "split") {
    if (input.axis !== "h" && input.axis !== "v") return INVALID_LAYOUT;
    const ratio = finite(input.ratio);
    if (ratio === null || ratio <= 0 || ratio >= 1) return INVALID_LAYOUT;
    const a = layoutNode(input.a, depth + 1, limits);
    const b = layoutNode(input.b, depth + 1, limits);
    if (a === INVALID_LAYOUT || b === INVALID_LAYOUT) return INVALID_LAYOUT;
    return { kind: "split", axis: input.axis, ratio, a, b };
  }
  if (
    input.kind !== "pane" ||
    !wireId(input.pane) ||
    limits.panes >= MAX_LAYOUT_PANES ||
    limits.paneIds.has(input.pane) ||
    (input.content !== "terminal" &&
      input.content !== "browser" &&
      input.content !== "agent" &&
      input.content !== "other")
  ) {
    return INVALID_LAYOUT;
  }
  limits.panes += 1;
  limits.paneIds.add(input.pane);
  const cols =
    input.cols === undefined ? undefined : integer(input.cols, 1, 10_000);
  const rows = input.rows === undefined ? undefined : integer(input.rows, 1, 10_000);
  const title =
    input.title === undefined ? undefined : boundedUtf8String(input.title, 512);
  if (
    (input.cols !== undefined && cols === null) ||
    (input.rows !== undefined && rows === null) ||
    (input.title !== undefined && title === null)
  ) {
    return INVALID_LAYOUT;
  }
  const paneNode: Extract<LayoutNode, { kind: "pane" }> = {
    kind: "pane",
    pane: input.pane,
    content: input.content,
  };
  if (cols !== undefined && cols !== null) paneNode.cols = cols;
  if (rows !== undefined && rows !== null) paneNode.rows = rows;
  if (title !== undefined && title !== null) paneNode.title = title;
  return paneNode;
}

function workspaceLayout(value: unknown): WorkspaceLayout | null {
  const input = record(value);
  if (!input || !wireId(input.ws)) return null;
  if (input.tree === null) return { ws: input.ws, tree: null };
  const tree = layoutNode(input.tree, 1, {
    nodes: 0,
    panes: 0,
    paneIds: new Set(),
  });
  return tree === INVALID_LAYOUT ? null : { ws: input.ws, tree };
}

function participants(value: unknown): Participant[] | null {
  if (!Array.isArray(value) || value.length > MAX_PARTICIPANTS) return null;
  const result: Participant[] = [];
  const users = new Set<string>();
  for (const entry of value) {
    const parsed = participant(entry);
    if (!parsed || users.has(parsed.user)) return null;
    users.add(parsed.user);
    result.push(parsed);
  }
  return result;
}

function chatHistory(value: unknown): ChatMessage[] | null {
  if (!Array.isArray(value) || value.length > MAX_CHAT_HISTORY) return null;
  const result: ChatMessage[] = [];
  const ids = new Set<string>();
  for (const entry of value) {
    const parsed = chatMessage(entry);
    if (!parsed || ids.has(parsed.id)) return null;
    ids.add(parsed.id);
    result.push(parsed);
  }
  return result;
}

/**
 * Runtime boundary for untrusted WebSocket JSON. Invalid messages are
 * ignored, while bounded collections are copied into client-owned values.
 */
export function normalizeServerMessage(value: unknown): ServerMessage | null {
  try {
    const input = record(value);
    if (!input || typeof input.t !== "string") return null;
    switch (input.t) {
      case "session-state": {
        const proto = integer(input.proto, 0, 1_000_000);
        const shared = sharedWorkspaces(input.shared);
        const parsedParticipants = participants(input.participants);
        const chat = chatHistory(input.chat);
        const you = record(input.you);
        const youRole = role(you?.role);
        const color = integer(you?.color, 0, 1_000_000);
        if (
          proto !== PROTO_VERSION ||
          shared === null ||
          parsedParticipants === null ||
          chat === null ||
          !you ||
          !wireId(you.user) ||
          youRole === null ||
          color === null ||
          you.isHost !== false ||
          !Array.isArray(input.layouts) ||
          input.layouts.length > MAX_SHARED_WORKSPACES
        ) {
          return null;
        }
        const selectedWs = shared[0]?.id;
        const layouts: WorkspaceLayout[] = [];
        if (input.layouts.length === 1) {
          const layout = workspaceLayout(input.layouts[0]);
          if (!layout || !selectedWs || layout.ws !== selectedWs) return null;
          layouts.push(layout);
        }
        return {
          t: "session-state",
          proto,
          shared,
          layouts,
          participants: parsedParticipants,
          chat,
          you: {
            user: you.user,
            role: youRole,
            color,
            isHost: you.isHost,
          },
        };
      }
      case "access-pending":
      case "access-denied":
      case "kicked":
      case "resync":
        return { t: input.t };
      case "ack-request": {
        const nonce = ackNonce(input.nonce);
        return nonce ? { t: "ack-request", nonce } : null;
      }
      case "access-request": {
        const email = wireEmail(input.email);
        return wireId(input.user) && email !== null
          ? { t: "access-request", user: input.user, email }
          : null;
      }
      case "presence": {
        const parsed = participants(input.participants);
        return parsed ? { t: "presence", participants: parsed } : null;
      }
      case "layout": {
        const layout = workspaceLayout(input.layout);
        return layout ? { t: "layout", layout } : null;
      }
      case "shared": {
        const shared = sharedWorkspaces(input.shared);
        return shared ? { t: "shared", shared } : null;
      }
      case "cursor": {
        if (!wireId(input.user)) return null;
        if (input.pos === null) return { t: "cursor", user: input.user, pos: null };
        const pos = cursorPos(input.pos);
        return pos ? { t: "cursor", user: input.user, pos } : null;
      }
      case "chat": {
        const msg = chatMessage(input.msg);
        return msg ? { t: "chat", msg } : null;
      }
      case "role-changed": {
        const changedRole = role(input.role);
        return changedRole ? { t: "role-changed", role: changedRole } : null;
      }
      case "session-ended":
        return input.reason === "host-stopped" ||
          input.reason === "host-gone" ||
          input.reason === "expired"
          ? { t: "session-ended", reason: input.reason }
          : null;
      case "error": {
        const code = boundedString(input.code, 256);
        const message = boundedString(input.message, 4_000);
        return code !== null && message !== null ? { t: "error", code, message } : null;
      }
      default:
        return null;
    }
  } catch {
    return null;
  }
}

function optionalColor(value: unknown): string | undefined {
  return typeof value === "string" && value.length <= 64 ? value : undefined;
}

function gridStyle(value: unknown): GridStyle | null {
  const input = record(value);
  const id = integer(input?.id, 0, 1_000_000);
  if (!input || id === null) return null;
  const result: GridStyle = { id };
  for (const key of [
    "bold",
    "faint",
    "italic",
    "underline",
    "blink",
    "inverse",
    "invisible",
    "strikethrough",
    "overline",
  ] as const) {
    if (typeof input[key] === "boolean") result[key] = input[key];
  }
  const foreground = optionalColor(input.foreground);
  const background = optionalColor(input.background);
  if (foreground !== undefined) result.foreground = foreground;
  if (background !== undefined) result.background = background;
  return result;
}

function gridCursor(value: unknown): GridCursor | undefined {
  const input = record(value);
  const row = integer(input?.row, 0, MAX_GRID_ROWS);
  const column = integer(input?.column, 0, MAX_GRID_COLUMNS);
  if (!input || row === null || column === null) return undefined;
  const style =
    input.style === "block" ||
    input.style === "bar" ||
    input.style === "underline" ||
    input.style === "block_hollow"
      ? input.style
      : undefined;
  return {
    row,
    column,
    ...(typeof input.visible === "boolean" ? { visible: input.visible } : {}),
    ...(style ? { style } : {}),
    ...(typeof input.blinking === "boolean" ? { blinking: input.blinking } : {}),
  };
}

function gridTheme(value: unknown): GridTheme | undefined {
  const input = record(value);
  const background = optionalColor(input?.background);
  const foreground = optionalColor(input?.foreground);
  const cursor = optionalColor(input?.cursor);
  if (!input || background === undefined || foreground === undefined || cursor === undefined) {
    return undefined;
  }
  let palette: string[] | undefined;
  if (input.palette !== undefined) {
    if (
      !Array.isArray(input.palette) ||
      input.palette.length > MAX_GRID_PALETTE_COLORS
    ) {
      return undefined;
    }
    const colors = input.palette.map(optionalColor);
    if (colors.some((color) => color === undefined)) return undefined;
    palette = colors as string[];
  }
  return { background, foreground, cursor, ...(palette ? { palette } : {}) };
}

/**
 * Copies an untrusted render-grid frame into a bounded shape before the
 * model allocates rows or retains text/styles.
 */
export function normalizeRenderGridFrame(value: unknown): RenderGridFrame | null {
  try {
    const input = record(value);
    if (!input || input.format !== RENDER_GRID_FORMAT || !wireId(input.surface_id)) return null;
    const stateSeq = integer(input.state_seq, 0, Number.MAX_SAFE_INTEGER);
    const columns = integer(input.columns, 0, MAX_GRID_COLUMNS);
    const rows = integer(input.rows, 0, MAX_GRID_ROWS);
    if (
      stateSeq === null ||
      columns === null ||
      rows === null ||
      !Array.isArray(input.row_spans) ||
      input.row_spans.length > MAX_GRID_SPANS
    ) {
      return null;
    }
    const rowSpans: GridRowSpan[] = [];
    let totalChars = 0;
    for (const value of input.row_spans) {
      const span = record(value);
      const row = integer(span?.row, 0, Math.max(0, rows - 1));
      const column = integer(span?.column, 0, MAX_GRID_COLUMNS);
      const styleId = integer(span?.style_id, 0, 1_000_000);
      const text =
        typeof span?.text === "string" && span.text.length <= MAX_GRID_SPAN_CHARS
          ? span.text
          : null;
      const cellWidth =
        span?.cell_width === undefined
          ? undefined
          : integer(span.cell_width, 0, MAX_GRID_COLUMNS * 4);
      if (
        !span ||
        row === null ||
        column === null ||
        styleId === null ||
        text === null ||
        (span.cell_width !== undefined && cellWidth === null)
      ) {
        return null;
      }
      totalChars += text.length;
      if (totalChars > MAX_GRID_TOTAL_CHARS) return null;
      const rowSpan: GridRowSpan = {
        row,
        column,
        style_id: styleId,
        text,
      };
      if (cellWidth !== undefined && cellWidth !== null) rowSpan.cell_width = cellWidth;
      rowSpans.push(rowSpan);
    }
    if (
      input.styles !== undefined &&
      (!Array.isArray(input.styles) || input.styles.length > MAX_GRID_STYLES)
    ) {
      return null;
    }
    const styles = Array.isArray(input.styles)
      ? input.styles.map(gridStyle)
      : undefined;
    if (styles?.some((style) => style === null)) return null;
    if (
      input.cleared_rows !== undefined &&
      (!Array.isArray(input.cleared_rows) ||
        input.cleared_rows.length > MAX_GRID_ROWS)
    ) {
      return null;
    }
    const clearedRows = Array.isArray(input.cleared_rows)
      ? input.cleared_rows.map((row) =>
          integer(row, 0, Math.max(0, rows - 1)),
        )
      : undefined;
    if (clearedRows?.some((row) => row === null)) return null;
    const cursor = input.cursor === undefined ? undefined : gridCursor(input.cursor);
    if (input.cursor !== undefined && cursor === undefined) return null;
    const theme = input.terminal_theme === undefined ? undefined : gridTheme(input.terminal_theme);
    if (input.terminal_theme !== undefined && theme === undefined) return null;
    const terminalForeground = optionalColor(input.terminal_foreground);
    const terminalBackground = optionalColor(input.terminal_background);
    const terminalCursorColor = optionalColor(input.terminal_cursor_color);
    return {
      format: RENDER_GRID_FORMAT,
      surface_id: input.surface_id,
      state_seq: stateSeq,
      columns,
      rows,
      row_spans: rowSpans,
      ...(typeof input.full === "boolean" ? { full: input.full } : {}),
      ...(clearedRows ? { cleared_rows: clearedRows as number[] } : {}),
      ...(styles ? { styles: styles as GridStyle[] } : {}),
      ...(cursor ? { cursor } : {}),
      ...(terminalForeground !== undefined
        ? { terminal_foreground: terminalForeground }
        : {}),
      ...(terminalBackground !== undefined
        ? { terminal_background: terminalBackground }
        : {}),
      ...(terminalCursorColor !== undefined
        ? { terminal_cursor_color: terminalCursorColor }
        : {}),
      ...(theme ? { terminal_theme: theme } : {}),
    };
  } catch {
    return null;
  }
}
