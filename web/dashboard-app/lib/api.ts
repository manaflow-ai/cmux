import type { z } from "zod";

/**
 * A failed dashboard API call. `code` is the server's `error.code` when the
 * body carries one, so screens can branch on known refusals.
 */
export class DashboardApiError extends Error {
  override readonly name = "DashboardApiError";
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

function errorFromBody(status: number, body: unknown): DashboardApiError {
  const error = typeof body === "object" && body !== null
    ? (body as { error?: unknown }).error
    : undefined;
  if (typeof error === "string") return new DashboardApiError(status, error, error);
  if (typeof error === "object" && error !== null) {
    const { code, message } = error as { code?: unknown; message?: unknown };
    if (typeof code === "string") {
      return new DashboardApiError(status, code, typeof message === "string" ? message : code);
    }
  }
  return new DashboardApiError(status, `http_${status}`, `Request failed with ${status}`);
}

/**
 * Fetch a same-origin dashboard API and parse the JSON body with `schema`.
 * Mutations send the browser origin, which the API routes require.
 */
export async function dashboardFetch<Schema extends z.ZodType>(
  url: string,
  schema: Schema,
  init: RequestInit & { readonly json?: unknown } = {},
): Promise<z.output<Schema>> {
  const { json, headers, ...rest } = init;
  let response: Response;
  try {
    response = await fetch(url, {
      credentials: "same-origin",
      cache: "no-store",
      ...rest,
      headers: {
        accept: "application/json",
        ...(json === undefined ? {} : { "content-type": "application/json" }),
        ...headers,
      },
      body: json === undefined ? rest.body : JSON.stringify(json),
    });
  } catch (cause) {
    if (cause instanceof DOMException && cause.name === "AbortError") throw cause;
    throw new DashboardApiError(0, "network_error", "Network request failed");
  }
  const body: unknown = await response.json().catch(() => null);
  if (!response.ok) throw errorFromBody(response.status, body);
  return schema.parse(body);
}

export function isDashboardApiError(error: unknown, status?: number): error is DashboardApiError {
  return error instanceof DashboardApiError && (status === undefined || error.status === status);
}
