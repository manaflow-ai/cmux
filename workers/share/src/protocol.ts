export const SHARE_PROTOCOL_VERSION = 1 as const;
export const SHARE_WEBSOCKET_PROTOCOL = "cmux-share.v1";
export const SHARE_TICKET_PROTOCOL_PREFIX = "cmux-share-ticket.";

export type Participant = {
  readonly connectionId: string;
  readonly userId: string;
  readonly displayName: string;
  readonly color: number;
  readonly role: "host" | "viewer";
};

export type ShareEnvelope<T = unknown> = {
  readonly v: typeof SHARE_PROTOCOL_VERSION;
  readonly type: string;
  readonly seq: number;
  readonly payload: T;
};

export type ClientEnvelope = ShareEnvelope<Record<string, unknown>>;

const HOST_TYPES = new Set([
  "access.decision",
  "share.end",
  "workspace.snapshot",
  "workspace.layout",
  "terminal.vt",
  "panel.frame",
  "presence.pointer",
  "chat.message",
  "textbox.document",
  "textbox.operation",
  "textbox.selection",
  "pong",
]);

const VIEWER_TYPES = new Set([
  "presence.pointer",
  "chat.message",
  "terminal.input",
  "textbox.operation",
  "textbox.selection",
  "workspace.resync.request",
  "pong",
]);

export function allowedClientType(role: "host" | "viewer", approved: boolean, type: string): boolean {
  if (role === "host") return HOST_TYPES.has(type);
  if (!approved) return type === "pong";
  return VIEWER_TYPES.has(type);
}

export function isOrderedHostStreamType(type: string): boolean {
  return type === "terminal.vt";
}

export function parseClientEnvelope(value: unknown): ClientEnvelope | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const candidate = value as Record<string, unknown>;
  if (
    candidate.v !== SHARE_PROTOCOL_VERSION ||
    typeof candidate.type !== "string" ||
    candidate.type.length < 1 ||
    candidate.type.length > 64 ||
    !Number.isSafeInteger(candidate.seq) ||
    (candidate.seq as number) < 0 ||
    !candidate.payload ||
    typeof candidate.payload !== "object" ||
    Array.isArray(candidate.payload)
  ) {
    return null;
  }
  return candidate as ClientEnvelope;
}

export function serverEnvelope(type: string, seq: number, payload: unknown): ShareEnvelope {
  return { v: SHARE_PROTOCOL_VERSION, type, seq, payload };
}
