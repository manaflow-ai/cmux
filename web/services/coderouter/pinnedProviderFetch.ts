import { lookup as dnsLookup, type LookupAddress, type LookupAllOptions } from "node:dns";
import https from "node:https";
import type { ClientRequest, IncomingMessage, RequestOptions } from "node:http";
import type { LookupFunction } from "node:net";
import { Readable } from "node:stream";

/**
 * Outbound HTTP client for provider endpoints named by a remote catalog.
 *
 * A one-time DNS preflight cannot stop DNS rebinding: `fetch` resolves the
 * hostname again when it connects, and it follows redirects to any address.
 * This client checks every address inside the connection's own lookup, so the
 * vetted answer is the one the socket connects to, while TLS still verifies
 * the original hostname. It never follows redirects; a 3xx is returned to the
 * caller as-is.
 */
export type ProviderFetch = (input: string | URL, init: RequestInit) => Promise<Response>;

type BaseLookup = (
  hostname: string,
  options: LookupAllOptions,
  callback: (error: NodeJS.ErrnoException | null, addresses: LookupAddress[]) => void,
) => void;

type RequestFn = (
  url: URL,
  options: RequestOptions,
  callback: (response: IncomingMessage) => void,
) => ClientRequest;

export type PinnedProviderFetchOptions = {
  /** Returns true for an address the provider connection must never reach. */
  readonly isUnsafeAddress: (address: string) => boolean;
  readonly lookup?: BaseLookup;
  /** Test seam; production always uses `https.request`. */
  readonly request?: RequestFn;
  readonly agent?: RequestOptions["agent"];
};

export class UnsafeProviderAddressError extends Error {
  readonly code = "EUNSAFEPROVIDERADDRESS";
  constructor(hostname: string) {
    super(`Provider host ${hostname} resolved to a disallowed address`);
    this.name = "UnsafeProviderAddressError";
  }
}

/** A connection-time lookup that fails when any answer is disallowed. */
export function guardedProviderLookup(
  isUnsafeAddress: (address: string) => boolean,
  base: BaseLookup = dnsLookup as BaseLookup,
): LookupFunction {
  return (hostname, options, callback) => {
    base(hostname, { ...options, all: true }, (error, addresses) => {
      if (error) {
        callback(error, "", 0);
        return;
      }
      if (addresses.length === 0 || addresses.some(({ address }) => isUnsafeAddress(address))) {
        callback(new UnsafeProviderAddressError(hostname), "", 0);
        return;
      }
      if (options.all) {
        (callback as unknown as (error: null, addresses: LookupAddress[]) => void)(null, addresses);
        return;
      }
      const [first] = addresses;
      callback(null, first.address, first.family);
    });
  };
}

const NULL_BODY_STATUSES = new Set([101, 103, 204, 205, 304]);

export function createPinnedProviderFetch(options: PinnedProviderFetchOptions): ProviderFetch {
  const lookup = guardedProviderLookup(options.isUnsafeAddress, options.lookup);
  const request = options.request ?? (https.request as unknown as RequestFn);
  const agent = options.agent ?? new https.Agent({ keepAlive: true });
  return (input, init) => new Promise<Response>((resolve, reject) => {
    const method = (init.method ?? "GET").toUpperCase();
    const signal = init.signal ?? undefined;
    if (signal?.aborted) {
      reject(signal.reason);
      return;
    }
    const headers: Record<string, string> = {};
    new Headers(init.headers).forEach((value, name) => {
      headers[name] = value;
    });
    const outgoing = request(new URL(input), { method, headers, lookup, agent, signal }, (response) => {
      const responseHeaders = new Headers();
      for (let index = 0; index + 1 < response.rawHeaders.length; index += 2) {
        responseHeaders.append(response.rawHeaders[index], response.rawHeaders[index + 1]);
      }
      const status = response.statusCode ?? 502;
      const hasBody = method !== "HEAD" && !NULL_BODY_STATUSES.has(status);
      if (!hasBody) response.resume();
      resolve(new Response(
        hasBody ? (Readable.toWeb(response) as ReadableStream<Uint8Array>) : null,
        { status, statusText: response.statusMessage, headers: responseHeaders },
      ));
    });
    outgoing.on("error", (error) => {
      reject(signal?.aborted ? signal.reason : error);
    });
    writeBody(outgoing, init.body, reject);
  });
}

function writeBody(
  outgoing: ClientRequest,
  body: RequestInit["body"],
  reject: (error: unknown) => void,
): void {
  if (body === undefined || body === null) {
    outgoing.end();
    return;
  }
  if (typeof body === "string" || body instanceof Uint8Array) {
    outgoing.end(body);
    return;
  }
  if (body instanceof ArrayBuffer) {
    outgoing.end(Buffer.from(body));
    return;
  }
  if (body instanceof ReadableStream) {
    const source = Readable.fromWeb(body as import("node:stream/web").ReadableStream<Uint8Array>);
    source.on("error", (error) => {
      outgoing.destroy(error);
      reject(error);
    });
    source.pipe(outgoing);
    return;
  }
  outgoing.destroy();
  reject(new TypeError("Unsupported provider request body"));
}
