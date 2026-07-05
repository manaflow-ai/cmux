import type { EndpointClass, Family } from "./types";

const HEADER_NAMES = [
  "x-coderouter-session",
  "x-codex-window-id",
  "x-codex-turn-state",
  "x-codex-parent-thread-id",
  "x-session-id",
  "x-conversation-id",
  "x-codex-session-id",
  "x-claude-session-id",
  "x-claude-code-session-id",
  "openai-conversation-id",
  "anthropic-conversation-id",
  "idempotency-key",
];

const QUERY_NAMES = ["session_id", "conversation_id", "thread_id"];
const BODY_NAMES = new Set(["session_id", "conversation_id", "thread_id"]);
const METADATA_SESSION_RE = /_session_([0-9a-f-]{36})/i;
const UUID_PREFIX_RE = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):/i;

const encoder = new TextEncoder();

export async function extractConversationKey(input: {
  endpointClass: EndpointClass;
  family: Family;
  headers: Headers;
  url: URL;
  parsedJson?: unknown;
  ip?: string | null;
  includeQuery?: boolean;
}): Promise<string> {
  const header = firstHeaderValue(input.headers);
  if (header) return prefix(input.endpointClass, normalizeId(header));

  if (input.includeQuery !== false) {
    for (const name of QUERY_NAMES) {
      const value = input.url.searchParams.get(name);
      if (value) return prefix(input.endpointClass, normalizeId(value));
    }
  }

  if (input.parsedJson !== undefined) {
    const body = findBodyValue(input.parsedJson, input.family, 0);
    if (body) return prefix(input.endpointClass, normalizeId(body));
  }

  const hash = await sha256(`${input.ip ?? ""}\0${input.headers.get("user-agent") ?? ""}\0${input.url.pathname}`);
  return prefix(input.endpointClass, `fallback:${hash.slice(0, 24)}`);
}

function firstHeaderValue(headers: Headers): string | null {
  for (const name of HEADER_NAMES) {
    const value = headers.get(name)?.trim();
    if (value) return value;
  }
  return null;
}

function normalizeId(value: string): string {
  const trimmed = value.trim();
  const match = UUID_PREFIX_RE.exec(trimmed);
  return match?.[1] ?? trimmed;
}

function prefix(endpointClass: EndpointClass, value: string): string {
  return `${endpointClass}:${value}`;
}

function findBodyValue(value: unknown, family: Family, depth: number): string | null {
  if (depth > 6 || value === null) return null;
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findBodyValue(item, family, depth + 1);
      if (found) return found;
    }
    return null;
  }
  if (typeof value !== "object") return null;
  const record = value as Record<string, unknown>;
  if (family === "anthropic") {
    const metadata = record.metadata;
    if (metadata && typeof metadata === "object") {
      const userId = (metadata as Record<string, unknown>).user_id;
      if (typeof userId === "string") {
        const match = METADATA_SESSION_RE.exec(userId);
        if (match?.[1]) return match[1];
      }
    }
  }
  for (const [key, item] of Object.entries(record)) {
    if (BODY_NAMES.has(key) && typeof item === "string" && item.trim()) return item;
  }
  for (const item of Object.values(record)) {
    const found = findBodyValue(item, family, depth + 1);
    if (found) return found;
  }
  return null;
}

async function sha256(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(input));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
