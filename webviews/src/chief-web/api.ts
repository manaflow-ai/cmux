import { ChiefAccessError, ExpiredSession, type ChiefIdentity, type ChiefTicket } from "./wire";

/** A typed API failure returned by the Chief gateway. */
export class ChiefApiError extends Error {
  readonly status: number;
  readonly code?: string;

  constructor(status: number, message: string, code?: string) {
    super(message);
    this.name = "ChiefApiError";
    this.status = status;
    this.code = code;
  }
}

/** The account is signed in, but this URL is not its Chief (403/404). */
export class ChiefAccessDenied extends ChiefAccessError {
  readonly status: 403 | 404;
  readonly code?: string;

  constructor(status: 403 | 404, message: string, code?: string) {
    super(message);
    this.status = status;
    this.code = code;
    this.name = "ChiefAccessDenied";
  }
}

/** The Chief gateway is temporarily unavailable (503); callers may retry with backoff. */
export class ChiefUnavailable extends ChiefApiError {
  constructor(message = "Chief is unavailable", code?: string) {
    super(503, message, code);
    this.name = "ChiefUnavailable";
  }
}

/** Same-origin session cookie; short-lived wire tickets never enter a URL or storage. */
export interface ChiefApi {
  me(signal: AbortSignal): Promise<ChiefIdentity>;
  ticket(signal: AbortSignal): Promise<ChiefTicket>;
  send(text: string, clientId: string, signal: AbortSignal): Promise<void>;
}

/** A message was rejected, including an HTTP-200 response with `ok: false`. */
export class SendRefused extends Error {
  readonly code?: string;

  constructor(message = "Message was rejected", code?: string) {
    super(message);
    this.name = "SendRefused";
    this.code = code;
  }
}

export class InvalidClientMessageId extends TypeError {
  constructor() {
    super("clientMessageId must match [A-Za-z0-9_-]{1,128}");
    this.name = "InvalidClientMessageId";
  }
}

type ApiErrorBody = { code?: unknown; message?: unknown };
type JsonObject = Record<string, unknown>;

const object = (value: unknown): value is JsonObject => !!value && typeof value === "object" && !Array.isArray(value);

async function bodyOf(response: Response): Promise<JsonObject> {
  if (response.status === 204) return {};
  try {
    const value: unknown = await response.json();
    return object(value) ? value : {};
  } catch {
    return {};
  }
}

function messageOf(body: JsonObject, fallback: string): { message: string; code?: string } {
  const error = body as ApiErrorBody;
  return {
    message: typeof error.message === "string" && error.message ? error.message : fallback,
    ...(typeof error.code === "string" && error.code ? { code: error.code } : {}),
  };
}

function requestSignal(signal: AbortSignal): AbortSignal {
  // Keep every request bounded while preserving cancellation from unmount/retry.
  return AbortSignal.any([signal, AbortSignal.timeout(30_000)]);
}

async function request(
  path: string,
  method: "GET" | "POST",
  signal: AbortSignal,
  body?: JsonObject,
): Promise<JsonObject> {
  const response = await fetch(path, {
    method,
    credentials: "include",
    signal: requestSignal(signal),
    ...(body
      ? {
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        }
      : {}),
  });
  const payload = await bodyOf(response);
  if (response.status === 401) throw new ExpiredSession();
  if (response.status === 403 || response.status === 404) {
    const error = messageOf(payload, response.status === 404 ? "Chief not found" : "Chief access denied");
    throw new ChiefAccessDenied(response.status, error.message, error.code);
  }
  if (response.status === 503) {
    const error = messageOf(payload, "Chief is unavailable");
    throw new ChiefUnavailable(error.message, error.code);
  }
  if (!response.ok) {
    const error = messageOf(payload, `Chief request failed (${response.status})`);
    throw new ChiefApiError(response.status, error.message, error.code);
  }
  return payload;
}

export const chiefApi: ChiefApi = {
  async me(signal) {
    const raw = await request("/v1/chief/me", "GET", signal);
    if (typeof raw.chiefId !== "string" || typeof raw.mainConversationId !== "string" || typeof raw.handle !== "string")
      throw new ChiefApiError(502, "Chief returned an invalid identity");
    return {
      chiefId: raw.chiefId,
      mainConversationId: raw.mainConversationId,
      handle: raw.handle,
    };
  },
  async ticket(signal) {
    const raw = await request("/v1/chief/ticket", "POST", signal);
    if (typeof raw.ticket !== "string" || typeof raw.websocketUrl !== "string")
      throw new ChiefApiError(502, "Chief returned an invalid socket ticket");
    return { ticket: raw.ticket, websocketUrl: raw.websocketUrl };
  },
  async send(text, clientId, signal) {
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(clientId)) throw new InvalidClientMessageId();
    const raw = await request("/v1/chief/messages", "POST", signal, {
      text,
      clientMessageId: clientId,
    });
    if (raw.ok !== true) {
      const error = messageOf(raw, "Message was rejected");
      throw new SendRefused(error.message, error.code);
    }
    if (typeof raw.clientMessageId !== "string" || raw.clientMessageId !== clientId)
      throw new ChiefApiError(502, "Chief returned an invalid message receipt");
  },
};
