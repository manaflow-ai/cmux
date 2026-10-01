// Wire protocol between clients (web, native, link) and a mux server.

import type {
  Conversation,
  DeliveryStatus,
  ID,
  Instant,
  Message,
  Part,
  Participant,
  PartRef,
} from "./chat.ts";

/** A conversation row in the viewer's list. */
export interface ConversationSummary {
  id: ID;
  title: string;
  preview: string;
  lastAt: Instant;
}

export interface Viewer {
  id: ID;
  displayName: string;
}

// REST

export interface CreateConversationRequest {
  title?: string;
  /** Muxes to add; the server adds the viewer's default mux when empty. */
  muxIds?: ID[];
}

export interface CreateConversationResponse {
  conversation: Conversation;
}

// Conversation WebSocket: /api/conversations/:id/ws

export type ClientFrame =
  | { type: "send"; clientId: string; parts: Part[]; replyTo?: PartRef }
  | { type: "typing"; on: boolean };

export type ServerFrame =
  | { type: "snapshot"; conversation: Conversation }
  | { type: "message"; message: Message; clientId?: string }
  | { type: "status"; messageId: ID; status: DeliveryStatus }
  | { type: "typing"; participantId: ID; on: boolean }
  | { type: "participants"; participants: Participant[] }
  | { type: "error"; message: string };

// Account event stream: /api/events (optional; servers without it refuse the socket)

export type AccountFrame = { type: "conversations" };

export function parseClientFrame(data: unknown): ClientFrame | undefined {
  if (typeof data !== "string") return undefined;
  let value: unknown;
  try {
    value = JSON.parse(data);
  } catch {
    return undefined;
  }
  if (!isRecord(value)) return undefined;
  if (value.type === "send" && typeof value.clientId === "string" && Array.isArray(value.parts)) {
    const parts = value.parts.filter(isTextPart);
    if (parts.length === 0) return undefined;
    return { type: "send", clientId: value.clientId, parts };
  }
  if (value.type === "typing" && typeof value.on === "boolean")
    return { type: "typing", on: value.on };
  return undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isTextPart(value: unknown): value is Part {
  return (
    isRecord(value) &&
    value.type === "text" &&
    typeof value.text === "string" &&
    value.text.length > 0
  );
}
