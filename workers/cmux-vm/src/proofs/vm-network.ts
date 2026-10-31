/** Trusted: creation network authority is minted only after scope and policy checks. */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Effect, Redacted } from "effect";
import type { InitialVmNetwork } from "../api/initial-network.ts";
import type { Principal } from "../domain/principal.ts";
import { badRequest, missingScope } from "../errors.ts";
import { httpsOrigin } from "../network-origin.ts";
import { TenantPolicy } from "../policy.ts";
import { keyHasScope } from "./key-has-scope.ts";

interface HttpsProxy {
  readonly hostname: string;
  readonly destination: { readonly host: string; readonly port: number };
  readonly headers: Redacted.Redacted<Readonly<Record<string, string>>>;
}

export interface VmNetworkAllowed<C> extends Proof<"VmNetworkAllowed", [C]> {}

interface NetworkEvidence {
  readonly config: { readonly publicEgress: boolean; readonly httpsProxies: ReadonlyArray<HttpsProxy> };
  /** Digest only: credentials never enter the idempotency ledger. */
  readonly fingerprint: string;
  readonly receipt: { readonly publicEgress: boolean; readonly httpsProxyHosts: ReadonlyArray<string> };
}

const Allowed = defineProof("VmNetworkAllowed");
const evidence = new WeakMap<object, NetworkEvidence>();

/** A copied proof has no policy evidence, just as with resource ownership. */
export const vmNetworkEvidenceOf = <C>(proof: VmNetworkAllowed<C>): NetworkEvidence => {
  const found = evidence.get(proof);
  if (found === undefined) throw new Error("VmNetworkAllowed proof was not minted by src/proofs");
  return found;
};

const INVALID_HEADER = /[^!#$%&'*+.^_`|~0-9a-z-]/u;
const BLOCKED_HEADERS = new Set([
  "host", "connection", "content-length", "transfer-encoding", "te", "trailer", "upgrade",
  "proxy-connection", "proxy-authorization", "proxy-authenticate", "keep-alive",
]);
const compare = (a: string, b: string) => a < b ? -1 : a > b ? 1 : 0;
const hostnameOf = (value: string): string | null => {
  const lower = value.toLowerCase();
  if (/[^a-z0-9.-]/u.test(lower)) return null;
  return lower.length <= 253 && lower.includes(".") && lower.split(".").every((label) =>
    label.length <= 63 && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/u.test(label)) ? lower : null;
};

export const headersOf = (value: Readonly<Record<string, string>>): Readonly<Record<string, string>> | null => {
  const entries = Object.entries(value);
  if (entries.length > 16) return null;
  const names = new Set<string>();
  const normalized: Array<[string, string]> = [];
  let bytes = 0;
  for (const [name, content] of entries) {
    const lower = name.toLowerCase();
    if (name.length === 0 || name.length > 128 || INVALID_HEADER.test(lower) || BLOCKED_HEADERS.has(lower) || names.has(lower)
      || content.length > 4096 || /[^\x20-\x7e]/u.test(content)) return null;
    names.add(lower);
    bytes += name.length + content.length;
    normalized.push([lower, content]);
  }
  if (bytes > 32 * 1024) return null;
  return Object.freeze(Object.fromEntries(normalized.sort(([a], [b]) => compare(a, b))));
};

/** Checks the exact caller before quota, persistence or a provider request. */
export const vmNetworkAllowed = <C>(caller: Named<C, Principal>, input: InitialVmNetwork) =>
  Effect.gen(function* () {
    const scope = keyHasScope(caller, "vm:network");
    if (scope === null) return yield* Effect.fail(missingScope("vm:network"));
    if (input.httpsProxies.length > 8) return yield* Effect.fail(badRequest("At most eight HTTPS proxies may be configured"));
    const policy = yield* TenantPolicy;
    const proxies: HttpsProxy[] = [];
    const hostnames = new Set<string>();
    for (const proxy of input.httpsProxies) {
      const hostname = hostnameOf(proxy.hostname);
      if (hostname === null || hostnames.has(hostname)) return yield* Effect.fail(badRequest("Proxy hostnames must be distinct DNS names"));
      const origin = httpsOrigin(proxy.destination);
      if (origin === null || !policy.httpsProxyOrigins.has(origin)) return yield* Effect.fail(badRequest("The HTTPS proxy destination is not enabled"));
      const headers = headersOf(Redacted.value(proxy.headers));
      if (headers === null) return yield* Effect.fail(badRequest("Proxy headers must have bounded names and printable values, without framing headers"));
      const destination = new URL(origin);
      hostnames.add(hostname);
      proxies.push(Object.freeze({ hostname, destination: Object.freeze({ host: destination.hostname, port: Number(destination.port || 443) }), headers: Redacted.make(headers) }));
    }
    proxies.sort((a, b) => compare(a.hostname, b.hostname));
    const config = Object.freeze({ publicEgress: input.publicEgress, httpsProxies: Object.freeze(proxies) });
    const canonical = [config.publicEgress, proxies.map((proxy) =>
      [proxy.hostname, proxy.destination.host, proxy.destination.port, Object.entries(Redacted.value(proxy.headers))])];
    const fingerprint = yield* Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(canonical)))).pipe(
      Effect.map((digest) => Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")),
    );
    const proof: VmNetworkAllowed<C> = Object.freeze({ ...Allowed.prove(caller) });
    evidence.set(proof, Object.freeze({ config, fingerprint,
      receipt: Object.freeze({ publicEgress: config.publicEgress, httpsProxyHosts: Object.freeze(proxies.map((proxy) => proxy.hostname)) }),
    }));
    return proof;
  });
