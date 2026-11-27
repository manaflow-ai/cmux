/**
 * Raw provider transport for the snapshot and terminal clients: JSON requests
 * and WebSocket upgrades with the provider key attached. Like live.ts, lint
 * lets only src/upstream/, src/proofs/ and src/index.ts import it. Only the
 * live upstream client modules call this, and only with an upstream id taken from a minted
 * TenantOwnsResource proof (or returned by a create the caller was proven to
 * be allowed). The key never leaves this closure.
 */
import { Effect, Redacted } from "effect";
import { upstreamIdOf, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import { UpstreamError } from "./client.ts";
import { awaitBackground, BACKGROUND_AFTER_HEADER, BACKGROUND_AFTER_SECS, DEFAULT_BACKGROUND_POLL_MS } from "./live-background.ts";
import { jsonItemsScanner } from "./json-items.ts";
import type { UpstreamConfig } from "./live.ts";
import { timedUpstream } from "./timing.ts";

const MAX_RESPONSE_BYTES = 1024 * 1024;
const MAX_FAILURE_PREFIX_CHARS = 8 * 1024;

/** Read only enough of a failed create response to classify known transient provider overloads. */
const capacityOverloaded = async (response: Response): Promise<boolean> => {
  if (response.body === null) return false;
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let prefix = "";
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      prefix += decoder.decode(value, { stream: true });
      if (prefix.length >= MAX_FAILURE_PREFIX_CHARS) break;
    }
  } catch {
    return false;
  } finally {
    await reader.cancel().catch(() => undefined);
    reader.releaseLock();
  }
  return /infrastructure\s+overloaded|capacity\s+queue\s+wait\s+expired/i.test(prefix);
};

export interface UpstreamHttp {
  /** A JSON request. Resolves with the parsed body, or `null` for an empty (204) response. */
  readonly json: (
    operation: string,
    method: "GET" | "POST" | "PATCH" | "PUT" | "DELETE",
    path: string,
    body?: unknown,
    options?: {
      readonly timeoutMs?: number;
      /**
       * Sends x-freestyle-background-after-secs: a request the provider is still working on after
       * BACKGROUND_AFTER_SECS answers 202, and its stored response is polled until this epoch ms
       * (live-background.ts). Without it, a request held past the provider's edge cut (about 120 s)
       * or `timeoutMs` loses its answer while the provider carries on.
       */
      readonly backgroundUntil?: number;
      /** With `backgroundUntil`: seconds before the provider answers 202 (default BACKGROUND_AFTER_SECS). */
      readonly backgroundAfterSecs?: number;
    },
  ) => Effect.Effect<unknown, UpstreamError>;
  /**
   * A GET of a JSON object whose `field` is an array of objects, read as it streams in (src/upstream/json-items.ts):
   * resolves with what `keep` returned for each item, in order. The 1 MiB cap of `json` does not apply; each item is
   * capped instead, and so is the whole reply.
   */
  readonly items: <A>(
    operation: string,
    path: string,
    field: string,
    keep: (item: unknown) => A,
    options: { readonly timeoutMs: number; readonly maxItemChars: number; readonly maxChars: number },
  ) => Effect.Effect<ReadonlyArray<A>, UpstreamError>;
  /** A WebSocket upgrade. Resolves with the provider's end of the socket, not yet accepted. */
  readonly upgrade: (operation: string, path: string) => Effect.Effect<WebSocket, UpstreamError>;
}

export function makeUpstreamHttp(config: UpstreamConfig): UpstreamHttp {
  const base = new URL(config.baseUrl);
  if (base.protocol !== "https:" || base.username || base.password || base.search || base.hash || base.pathname !== "/") {
    throw new Error("upstream base URL must be a bare HTTPS origin");
  }
  const send = config.fetch ?? ((request: Request) => fetch(request));
  const timeoutMs = config.timeoutMs ?? 10_000;
  const authorization = () => `Bearer ${Redacted.value(config.apiKey)}`;

  /** A 2xx response (body unread); any other status, or no answer, is an UpstreamError. */
  const request = (
    operation: string,
    method: string,
    path: string,
    init: { readonly body?: unknown; readonly timeoutMs: number; readonly headers?: Record<string, string> },
  ): Effect.Effect<Response, UpstreamError> =>
    Effect.tryPromise({
      try: async () => {
        const headers: Record<string, string> = {
          ...init.headers,
          authorization: authorization(),
          accept: "application/json",
        };
        if (init.body !== undefined) headers["content-type"] = "application/json";
        const response = await send(
          new Request(new URL(path, base), {
            method,
            headers,
            ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
            redirect: "manual",
            signal: AbortSignal.timeout(init.timeoutMs),
          }),
        );
        if (!response.ok) {
          const kind = operation === "createVm" && response.status === 429 && (await capacityOverloaded(response))
            ? "capacity_overloaded" as const
            : undefined;
          if (kind !== undefined) return { ok: false as const, status: response.status, kind };
          await response.body?.cancel();
          return { ok: false as const, status: response.status };
        }
        return { ok: true as const, response };
      },
      catch: () => new UpstreamError({ operation, status: null }),
    }).pipe(
      Effect.flatMap((result) =>
        result.ok ? Effect.succeed(result.response) : Effect.fail(new UpstreamError({ operation, status: result.status, ...(result.kind === undefined ? {} : { kind: result.kind }) })),
      ),
    );

  const parse = (operation: string, response: Response): Effect.Effect<unknown, UpstreamError> =>
    Effect.tryPromise({
      try: async () => {
        const bytes = new Uint8Array(await response.arrayBuffer());
        if (bytes.byteLength > MAX_RESPONSE_BYTES) return { ok: false as const, status: response.status };
        if (bytes.byteLength === 0) return { ok: true as const, body: null };
        const parsed: unknown = JSON.parse(new TextDecoder().decode(bytes));
        return { ok: true as const, body: parsed };
      },
      catch: () => new UpstreamError({ operation, status: response.status }),
    }).pipe(
      Effect.flatMap((result) =>
        result.ok ? Effect.succeed(result.body) : Effect.fail(new UpstreamError({ operation, status: result.status })),
      ),
    );

  const json: UpstreamHttp["json"] = (operation, method, path, body, options) => {
    const until = options?.backgroundUntil;
    const sent = request(operation, method, path, {
      body,
      timeoutMs: options?.timeoutMs ?? timeoutMs,
      ...(until === undefined ? {} : { headers: { [BACKGROUND_AFTER_HEADER]: String(options?.backgroundAfterSecs ?? BACKGROUND_AFTER_SECS) } }),
    });
    const settled = until === undefined ? sent : sent.pipe(Effect.flatMap((response) => response.status === 202
      ? awaitBackground((op, at, init) => request(op, init.method, at, { timeoutMs: init.timeoutMs }), operation, response, base.origin, until, config.backgroundPollMs ?? DEFAULT_BACKGROUND_POLL_MS)
      : Effect.succeed(response)));
    return settled.pipe(Effect.flatMap((response) => parse(operation, response)), timedUpstream);
  };

  const items: UpstreamHttp["items"] = (operation, path, field, keep, options) =>
    Effect.tryPromise({
      try: async () => {
        const response = await send(
          new Request(new URL(path, base), {
            method: "GET",
            headers: { authorization: authorization(), accept: "application/json" },
            redirect: "manual",
            signal: AbortSignal.timeout(options.timeoutMs),
          }),
        );
        if (!response.ok || response.body === null) {
          await response.body?.cancel();
          return { ok: false as const, status: response.status };
        }
        const kept: Array<ReturnType<typeof keep>> = [];
        const scanner = jsonItemsScanner(field, options.maxItemChars, (item) => kept.push(keep(item)));
        const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
        let chars = 0;
        try {
          for (;;) {
            const chunk = await reader.read();
            if (chunk.done) break;
            chars += chunk.value.length;
            if (chars > options.maxChars) throw new Error("listing too large");
            scanner.feed(chunk.value);
          }
        } catch (error) {
          await reader.cancel().catch(() => undefined);
          throw error;
        } finally {
          reader.releaseLock();
        }
        scanner.end();
        return { ok: true as const, body: kept };
      },
      catch: () => new UpstreamError({ operation, status: null }),
    }).pipe(
      timedUpstream,
      Effect.flatMap((result) =>
        result.ok ? Effect.succeed(result.body) : Effect.fail(new UpstreamError({ operation, status: result.status })),
      ),
    );

  const upgrade: UpstreamHttp["upgrade"] = (operation, path) =>
    Effect.tryPromise({
      try: async () => {
        // No abort signal: it would cut the live socket, not just the handshake.
        // A handshake slower than the timeout fails, and a socket that arrives
        // after that is closed at once.
        const handshake = send(
          new Request(new URL(path, base), {
            method: "GET",
            headers: { authorization: authorization(), upgrade: "websocket" },
            redirect: "manual",
          }),
        );
        let expire: () => void = () => undefined;
        const deadline = new Promise<"timeout">((resolve) => {
          expire = () => resolve("timeout");
        });
        const timer = setTimeout(() => expire(), timeoutMs);
        const first = await Promise.race([handshake, deadline]);
        clearTimeout(timer);
        if (first === "timeout") {
          void handshake.then(
            (late) => {
              late.webSocket?.close(1000, "");
            },
            () => undefined,
          );
          return { ok: false as const, status: null };
        }
        const response = first;
        const socket = response.webSocket;
        if (response.status !== 101 || socket === null) {
          await response.body?.cancel();
          return { ok: false as const, status: response.status };
        }
        return { ok: true as const, socket };
      },
      catch: () => new UpstreamError({ operation, status: null }),
    }).pipe(
      Effect.flatMap((result) =>
        result.ok ? Effect.succeed(result.socket) : Effect.fail(new UpstreamError({ operation, status: result.status })),
      ),
    );

  return { json, items, upgrade };
}

/** The upstream id a minted ownership proof carries, percent-encoded for a path segment. */
export const proofSegment = <C, R>(owns: TenantOwnsResource<C, R>): string => encodeURIComponent(upstreamIdOf(owns));
