import * as Data from "effect/Data";

export const SHARE_PROTOCOL_VERSION = 2 as const;
export const SHARE_TERMINAL_TRANSPORT_VERSION = 1 as const;

const DEFAULT_SHARE_WORKER_BASE_URL = "wss://share.cmux.dev";
const SHARE_WORKER_HEALTH_TIMEOUT_MS = 1_500;
const SHARE_WORKER_HEALTH_CACHE_TTL_MS = 5_000;
const MAX_SHARE_WORKER_HEALTH_BYTES = 4_096;

export interface ShareWorkerCompatibility {
  readonly protocolVersion: typeof SHARE_PROTOCOL_VERSION;
  readonly terminalTransportVersion:
    typeof SHARE_TERMINAL_TRANSPORT_VERSION;
  readonly deploymentId: string;
}

export class ShareWorkerCompatibilityError extends Data.TaggedError(
  "ShareWorkerCompatibilityError",
)<{
  readonly code: "share_worker_unavailable" | "share_worker_incompatible";
}> {}

interface CompatibilityCacheEntry {
  readonly healthUrl: string;
  readonly expiresAtMs: number;
  readonly value: ShareWorkerCompatibility;
}

interface CompatibilityInFlight {
  readonly healthUrl: string;
  readonly promise: Promise<ShareWorkerCompatibility>;
}

let compatibilityCache: CompatibilityCacheEntry | null = null;
let compatibilityInFlight: CompatibilityInFlight | null = null;

function configuredShareWorkerBaseUrl(override?: string): URL {
  const raw =
    override ??
    process.env.CMUX_SHARE_WS_BASE_URL ??
    DEFAULT_SHARE_WORKER_BASE_URL;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new ShareWorkerCompatibilityError({
      code: "share_worker_unavailable",
    });
  }
  if (
    !["http:", "https:", "ws:", "wss:"].includes(url.protocol) ||
    url.username !== "" ||
    url.password !== "" ||
    url.search !== "" ||
    url.hash !== ""
  ) {
    throw new ShareWorkerCompatibilityError({
      code: "share_worker_unavailable",
    });
  }
  url.pathname = url.pathname.replace(/\/+$/, "");
  return url;
}

export function shareWorkerWebSocketBaseUrl(override?: string): string {
  const url = configuredShareWorkerBaseUrl(override);
  if (url.protocol === "http:") url.protocol = "ws:";
  if (url.protocol === "https:") url.protocol = "wss:";
  return url.toString().replace(/\/$/, "");
}

export function shareWorkerHealthUrl(override?: string): string {
  const url = configuredShareWorkerBaseUrl(override);
  if (url.protocol === "ws:") url.protocol = "http:";
  if (url.protocol === "wss:") url.protocol = "https:";
  const basePath = url.pathname === "/" ? "" : url.pathname;
  url.pathname = `${basePath}/healthz`;
  return url.toString();
}

async function readBoundedJson(response: Response): Promise<unknown> {
  const declaredLength = Number(response.headers.get("content-length"));
  if (
    Number.isFinite(declaredLength) &&
    declaredLength > MAX_SHARE_WORKER_HEALTH_BYTES
  ) {
    throw new ShareWorkerCompatibilityError({
      code: "share_worker_incompatible",
    });
  }
  if (response.body === null) {
    throw new ShareWorkerCompatibilityError({
      code: "share_worker_incompatible",
    });
  }

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > MAX_SHARE_WORKER_HEALTH_BYTES) {
        await reader.cancel();
        throw new ShareWorkerCompatibilityError({
          code: "share_worker_incompatible",
        });
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new ShareWorkerCompatibilityError({
      code: "share_worker_incompatible",
    });
  }
}

function parseCompatibility(value: unknown): ShareWorkerCompatibility {
  if (
    typeof value !== "object" ||
    value === null ||
    (value as { ok?: unknown }).ok !== true ||
    (value as { service?: unknown }).service !== "cmux-share" ||
    (value as { protocolVersion?: unknown }).protocolVersion !==
      SHARE_PROTOCOL_VERSION ||
    (value as { terminalTransportVersion?: unknown })
      .terminalTransportVersion !== SHARE_TERMINAL_TRANSPORT_VERSION
  ) {
    throw new ShareWorkerCompatibilityError({
      code: "share_worker_incompatible",
    });
  }
  const deploymentId = (value as { deploymentId?: unknown }).deploymentId;
  if (
    typeof deploymentId !== "string" ||
    deploymentId.trim() === "" ||
    new TextEncoder().encode(deploymentId).byteLength > 256 ||
    /\p{Cc}/u.test(deploymentId)
  ) {
    throw new ShareWorkerCompatibilityError({
      code: "share_worker_incompatible",
    });
  }
  return {
    protocolVersion: SHARE_PROTOCOL_VERSION,
    terminalTransportVersion: SHARE_TERMINAL_TRANSPORT_VERSION,
    deploymentId,
  };
}

async function fetchCompatibility(input: {
  readonly healthUrl: string;
  readonly fetch: typeof fetch;
  readonly timeoutMs: number;
}): Promise<ShareWorkerCompatibility> {
  let response: Response;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), input.timeoutMs);
  try {
    response = await input.fetch(input.healthUrl, {
      method: "GET",
      headers: { accept: "application/json" },
      cache: "no-store",
      redirect: "error",
      signal: controller.signal,
    });
  } catch {
    throw new ShareWorkerCompatibilityError({
      code: "share_worker_unavailable",
    });
  } finally {
    clearTimeout(timeout);
  }
  if (!response.ok) {
    throw new ShareWorkerCompatibilityError({
      code: "share_worker_unavailable",
    });
  }
  return parseCompatibility(await readBoundedJson(response));
}

export async function requireCompatibleShareWorker(
  options: {
    readonly fetch?: typeof fetch;
    readonly nowMs?: () => number;
    readonly timeoutMs?: number;
    readonly cacheTtlMs?: number;
    readonly baseUrl?: string;
  } = {},
): Promise<ShareWorkerCompatibility> {
  const healthUrl = shareWorkerHealthUrl(options.baseUrl);
  const nowMs = options.nowMs ?? Date.now;
  const now = nowMs();
  if (
    compatibilityCache?.healthUrl === healthUrl &&
    compatibilityCache.expiresAtMs > now
  ) {
    return compatibilityCache.value;
  }
  if (compatibilityInFlight?.healthUrl === healthUrl) {
    return compatibilityInFlight.promise;
  }

  const timeoutMs = options.timeoutMs ?? SHARE_WORKER_HEALTH_TIMEOUT_MS;
  const cacheTtlMs = options.cacheTtlMs ?? SHARE_WORKER_HEALTH_CACHE_TTL_MS;
  const promise = fetchCompatibility({
    healthUrl,
    fetch: options.fetch ?? fetch,
    timeoutMs,
  }).then((value) => {
    compatibilityCache = {
      healthUrl,
      expiresAtMs: nowMs() + cacheTtlMs,
      value,
    };
    return value;
  });
  compatibilityInFlight = { healthUrl, promise };
  try {
    return await promise;
  } finally {
    if (compatibilityInFlight?.promise === promise) {
      compatibilityInFlight = null;
    }
  }
}
