import {
  HEXCLAVE_API_VERSION_PATH,
  type HexclaveClientConfig,
} from "./config";

/**
 * A Hexclave "known error": a stable machine code the product is expected to
 * branch on. Anything else is an outage and surfaces as a generic failure.
 */
export type HexclaveKnownError = {
  readonly code: string;
  readonly message: string;
};

export type HexclaveResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: HexclaveKnownError };

export class HexclaveRequestError extends Error {
  constructor(
    readonly status: number,
    readonly path: string,
    body: string,
  ) {
    super(`Hexclave ${path} failed with ${status}: ${body.slice(0, 400)}`);
    this.name = "HexclaveRequestError";
  }
}

type HexclaveRequest = {
  readonly config: HexclaveClientConfig;
  readonly path: string;
  readonly body?: unknown;
  readonly method?: "GET" | "POST" | "DELETE";
  /** Sends the call on behalf of a signed-in user. */
  readonly accessToken?: string;
  readonly refreshToken?: string;
};

/**
 * Calls a Hexclave client endpoint and separates known errors from outages.
 *
 * `X-Hexclave-Override-Error-Status` makes the API answer known errors with
 * HTTP 200 plus a code header, so a 4xx/5xx here always means the call itself
 * is broken and belongs in the logs rather than in a form field.
 */
export async function hexclaveClientRequest<T>({
  config,
  path,
  body,
  method = "POST",
  accessToken,
  refreshToken,
}: HexclaveRequest): Promise<HexclaveResult<T>> {
  const headers: Record<string, string> = {
    "X-Hexclave-Override-Error-Status": "true",
    "X-Hexclave-Project-Id": config.projectId,
    "X-Hexclave-Access-Type": "client",
    "X-Hexclave-Publishable-Client-Key": config.publishableClientKey,
  };
  if (accessToken) headers["X-Hexclave-Access-Token"] = accessToken;
  if (refreshToken) headers["X-Hexclave-Refresh-Token"] = refreshToken;
  if (body !== undefined) headers["Content-Type"] = "application/json";

  const response = await fetch(
    `${config.apiBaseURL}${HEXCLAVE_API_VERSION_PATH}${path}`,
    {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: "no-store",
    },
  );

  const knownErrorCode = response.headers.get("x-hexclave-known-error") ??
    response.headers.get("x-stack-known-error");
  const text = await response.text();

  if (knownErrorCode) {
    return {
      ok: false,
      error: { code: knownErrorCode, message: knownErrorMessage(text) },
    };
  }
  if (!response.ok) throw new HexclaveRequestError(response.status, path, text);
  return { ok: true, value: (text ? JSON.parse(text) : {}) as T };
}

/**
 * Reads the human-readable half of a known error. It is used only for logs and
 * telemetry; every string a user sees is chosen from our own catalog by code.
 */
function knownErrorMessage(text: string): string {
  try {
    const parsed = JSON.parse(text) as { error?: unknown };
    return typeof parsed.error === "string" ? parsed.error : text;
  } catch {
    return text;
  }
}
